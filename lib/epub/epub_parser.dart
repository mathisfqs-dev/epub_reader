import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'model.dart';
import 'xhtml_converter.dart';

/// Parses an EPUB 2 or EPUB 3 file into a [Book].
///
/// Steps: `META-INF/container.xml` → OPF package (metadata, manifest,
/// spine) → table of contents (EPUB 3 nav document, else EPUB 2 NCX) →
/// each spine document converted to blocks by [XhtmlConverter].
class EpubParser {
  const EpubParser({this.converter = const XhtmlConverter()});

  final XhtmlConverter converter;

  Future<Book> parseFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return parseBytes(bytes, sourcePath: path);
  }

  Book parseBytes(Uint8List bytes, {String? sourcePath}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw EpubFormatException('Not a zip file: $e');
    }
    return _Parse(archive, converter, sourcePath).run();
  }
}

class _ManifestItem {
  _ManifestItem(this.id, this.path, this.mediaType, this.properties);

  final String id;

  /// Archive path.
  final String path;
  final String mediaType;
  final Set<String> properties;
}

class _Parse {
  _Parse(this.archive, this.converter, this.sourcePath);

  final Archive archive;
  final XhtmlConverter converter;
  final String? sourcePath;
  final warnings = <String>[];

  late final Map<String, ArchiveFile> _filesLowercase = {
    for (final f in archive.files) f.name.toLowerCase(): f,
  };

  Book run() {
    final opfPath = _rootfilePath();
    final opf = _xml(opfPath);
    final opfDir = p.posix.dirname(opfPath);
    final package = opf.rootElement;

    final metadataEl = _child(package, 'metadata');
    final manifestEl = _child(package, 'manifest');
    final spineEl = _child(package, 'spine');
    if (manifestEl == null || spineEl == null) {
      throw EpubFormatException('OPF has no manifest or spine');
    }

    final manifest = <String, _ManifestItem>{};
    for (final item in _children(manifestEl, 'item')) {
      final id = _attr(item, 'id');
      final href = _attr(item, 'href');
      if (id == null || href == null) continue;
      manifest[id] = _ManifestItem(
        id,
        _resolve(opfDir, href),
        _attr(item, 'media-type') ?? '',
        (_attr(item, 'properties') ?? '').split(' ').toSet(),
      );
    }

    final metadata = _metadata(metadataEl, manifest);
    final toc = _toc(spineEl, manifest);
    final chapters = _chapters(spineEl, manifest, metadata.coverImagePath);
    _resolveToc(toc, chapters, spineEl, manifest);

    for (final chapter in chapters) {
      chapter.title ??= _firstHeading(chapter);
    }

    return Book(
      metadata: metadata,
      toc: toc,
      chapters: chapters,
      archive: archive,
      sourcePath: sourcePath,
      warnings: warnings,
    );
  }

  // ---------------------------------------------------------------- OPF

  String _rootfilePath() {
    final container = _xml('META-INF/container.xml');
    for (final rootfile in container.descendantElements) {
      if (rootfile.localName != 'rootfile') continue;
      final path = _attr(rootfile, 'full-path');
      if (path != null) return path;
    }
    throw EpubFormatException('container.xml has no rootfile');
  }

  BookMetadata _metadata(XmlElement? el, Map<String, _ManifestItem> manifest) {
    String? first(String name) {
      if (el == null) return null;
      for (final child in el.childElements) {
        if (child.localName == name && child.innerText.trim().isNotEmpty) {
          return _clean(child.innerText);
        }
      }
      return null;
    }

    final authors = <String>[
      if (el != null)
        for (final child in el.childElements)
          if (child.localName == 'creator' && child.innerText.trim().isNotEmpty)
            _clean(child.innerText),
    ];

    // Cover: EPUB 3 `properties="cover-image"`, else EPUB 2
    // `<meta name="cover" content="manifest-id"/>`.
    String? cover;
    for (final item in manifest.values) {
      if (item.properties.contains('cover-image')) cover = item.path;
    }
    if (cover == null && el != null) {
      for (final meta in el.childElements) {
        if (meta.localName == 'meta' && _attr(meta, 'name') == 'cover') {
          cover = manifest[_attr(meta, 'content')]?.path;
        }
      }
    }

    return BookMetadata(
      title:
          first('title') ??
          p.basenameWithoutExtension(sourcePath ?? 'Untitled'),
      authors: authors,
      language: first('language'),
      identifier: first('identifier'),
      coverImagePath: cover,
    );
  }

  // ---------------------------------------------------------------- chapters

  List<Chapter> _chapters(
    XmlElement spine,
    Map<String, _ManifestItem> manifest,
    String? coverPath,
  ) {
    final chapters = <Chapter>[];
    for (final item in _spineItems(spine, manifest)) {
      final String source;
      try {
        source = _text(item.path);
      } on EpubFormatException catch (e) {
        warnings.add(e.message);
        continue;
      }
      final ConvertedDocument doc;
      try {
        doc = converter.convert(source, documentPath: item.path);
      } on XmlException catch (e) {
        warnings.add('${item.path}: invalid XHTML ($e)');
        continue;
      }
      if (doc.blocks.isEmpty) continue;
      // The cover wrapper page only shows the cover image.
      final onlyCover = doc.blocks.every(
        (b) => b.type == BlockType.image && b.imagePath == coverPath,
      );
      if (onlyCover) continue;
      chapters.add(
        Chapter(path: item.path, blocks: doc.blocks, anchors: doc.anchors),
      );
    }
    if (chapters.isEmpty) {
      throw EpubFormatException('No readable content documents');
    }
    return chapters;
  }

  List<_ManifestItem> _spineItems(
    XmlElement spine,
    Map<String, _ManifestItem> manifest,
  ) {
    final items = <_ManifestItem>[];
    for (final ref in _children(spine, 'itemref')) {
      final item = manifest[_attr(ref, 'idref')];
      if (item == null) {
        warnings.add('Spine references unknown item ${_attr(ref, 'idref')}');
        continue;
      }
      if (!item.mediaType.contains('html')) continue;
      items.add(item);
    }
    return items;
  }

  String? _firstHeading(Chapter chapter) {
    for (final block in chapter.blocks) {
      if (block.type == BlockType.heading) {
        return block.text.replaceAll('\n', ' ');
      }
    }
    return null;
  }

  // ---------------------------------------------------------------- TOC

  List<TocEntry> _toc(XmlElement spine, Map<String, _ManifestItem> manifest) {
    final nav = manifest.values.where((i) => i.properties.contains('nav'));
    if (nav.isNotEmpty) {
      try {
        final entries = _navToc(nav.first.path);
        if (entries.isNotEmpty) return entries;
      } catch (e) {
        warnings.add('Nav document unreadable: $e');
      }
    }
    final ncxItem =
        manifest[_attr(spine, 'toc')] ??
        manifest.values
            .where((i) => i.mediaType == 'application/x-dtbncx+xml')
            .firstOrNull;
    if (ncxItem != null) {
      try {
        return _ncxToc(ncxItem.path);
      } catch (e) {
        warnings.add('NCX unreadable: $e');
      }
    }
    warnings.add('No table of contents');
    return [];
  }

  /// EPUB 3: `<nav epub:type="toc"><ol><li><a href>…</a><ol>…</ol></li>`.
  List<TocEntry> _navToc(String path) {
    final doc = _xml(path, html: true);
    final dir = p.posix.dirname(path);
    final navs = doc.descendantElements.where((e) => e.localName == 'nav');
    final tocNav = navs.where((n) => (_attr(n, 'type') ?? '').contains('toc'));
    final nav = tocNav.firstOrNull ?? navs.firstOrNull;
    if (nav == null) return [];

    final entries = <TocEntry>[];
    void walkList(XmlElement list, int depth) {
      for (final li in _children(list, 'li')) {
        final link = li.childElements
            .where((e) => e.localName == 'a' || e.localName == 'span')
            .firstOrNull;
        final href = link == null ? null : _attr(link, 'href');
        if (link != null && href != null) {
          entries.add(_entry(_clean(link.innerText), depth, dir, href));
        }
        for (final sub in li.childElements.where((e) => e.localName == 'ol')) {
          walkList(sub, depth + 1);
        }
      }
    }

    for (final ol in nav.childElements.where((e) => e.localName == 'ol')) {
      walkList(ol, 0);
    }
    return entries;
  }

  /// EPUB 2: `navMap > navPoint` elements, each with a `navLabel > text`,
  /// a `content src` and nested `navPoint`s.
  List<TocEntry> _ncxToc(String path) {
    final doc = _xml(path);
    final dir = p.posix.dirname(path);
    final navMap = doc.descendantElements
        .where((e) => e.localName == 'navMap')
        .firstOrNull;
    if (navMap == null) return [];

    final entries = <TocEntry>[];
    void walk(XmlElement parent, int depth) {
      for (final point in _children(parent, 'navPoint')) {
        final label = point.descendantElements
            .where((e) => e.localName == 'text')
            .firstOrNull;
        final content = _child(point, 'content');
        final src = content == null ? null : _attr(content, 'src');
        if (label != null && src != null) {
          entries.add(_entry(_clean(label.innerText), depth, dir, src));
        }
        walk(point, depth + 1);
      }
    }

    walk(navMap, 0);
    return entries;
  }

  TocEntry _entry(String title, int depth, String dir, String href) {
    final hash = href.indexOf('#');
    final file = hash < 0 ? href : href.substring(0, hash);
    final fragment = hash < 0 ? null : href.substring(hash + 1);
    return TocEntry(
      title: _cleanTocTitle(title),
      depth: depth,
      path: _resolve(dir, file),
      fragment: (fragment == null || fragment.isEmpty) ? null : fragment,
    );
  }

  static final _sectionWord = RegExp(
    r'\b(CHAPTER|Chapter|CHAPITRE|Chapitre|BOOK|Book|LIVRE|Livre|PART|Part|PARTIE|Partie|VOLUME|Volume)\b',
  );

  /// Illustrated Gutenberg editions put the illustration caption before the
  /// chapter title in the TOC ("I hope Mr. Bingley will like it. CHAPTER
  /// II."): keep only the part from "CHAPTER" on.
  static String _cleanTocTitle(String title) {
    final m = _sectionWord.firstMatch(title);
    if (m == null || m.start == 0) return title;
    final prefix = title.substring(0, m.start).trimRight();
    if (!RegExp(r'[.!?”"’]$').hasMatch(prefix)) return title;
    return title.substring(m.start);
  }

  /// Points each TOC entry at a chapter and block. Entries targeting a
  /// dropped document (cover page, empty licence footer…) point at the next
  /// kept chapter.
  void _resolveToc(
    List<TocEntry> toc,
    List<Chapter> chapters,
    XmlElement spine,
    Map<String, _ManifestItem> manifest,
  ) {
    final chapterByPath = <String, int>{};
    var next = chapters.length - 1;
    final spinePaths = _spineItems(spine, manifest).map((i) => i.path).toList();
    final keptIndex = {
      for (var i = 0; i < chapters.length; i++) chapters[i].path: i,
    };
    for (final path in spinePaths.reversed) {
      next = keptIndex[path] ?? next;
      chapterByPath[path] = next;
    }

    for (final entry in toc) {
      final index = chapterByPath[entry.path];
      if (index == null) {
        warnings.add(
          'TOC entry "${entry.title}" targets missing ${entry.path}',
        );
        continue;
      }
      entry.chapterIndex = index;
      final chapter = chapters[index];
      final exact = chapter.path == entry.path;
      entry.blockIndex = exact && entry.fragment != null
          ? chapter.anchors[entry.fragment] ?? 0
          : 0;
      if (exact) chapter.title ??= entry.title;
    }
  }

  // ---------------------------------------------------------------- files

  ArchiveFile _file(String path) {
    final file = archive.findFile(path) ?? _filesLowercase[path.toLowerCase()];
    if (file == null || !file.isFile) {
      throw EpubFormatException('Missing file in EPUB: $path');
    }
    return file;
  }

  String _text(String path) =>
      utf8.decode(_file(path).content, allowMalformed: true);

  XmlDocument _xml(String path, {bool html = false}) {
    var source = _text(path);
    if (source.startsWith('﻿')) source = source.substring(1);
    try {
      return XmlDocument.parse(
        source,
        entityMapping: html ? const XmlDefaultEntityMapping.html5() : null,
      );
    } on XmlException catch (e) {
      throw EpubFormatException('Invalid XML in $path: $e');
    }
  }

  static String _resolve(String dir, String href) =>
      p.posix.normalize(p.posix.join(dir, Uri.decodeFull(href)));

  static String _clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

XmlElement? _child(XmlElement el, String localName) =>
    el.childElements.where((e) => e.localName == localName).firstOrNull;

Iterable<XmlElement> _children(XmlElement el, String localName) =>
    el.childElements.where((e) => e.localName == localName);

/// Attribute by local name, ignoring namespace prefixes.
String? _attr(XmlElement el, String localName) {
  for (final a in el.attributes) {
    if (a.name.local == localName) return a.value;
  }
  return null;
}
