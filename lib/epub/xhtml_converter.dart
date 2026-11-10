import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'model.dart';
import 'sentence_splitter.dart';

/// Result of converting one XHTML document.
class ConvertedDocument {
  ConvertedDocument(this.blocks, this.anchors);

  final List<Block> blocks;
  final Map<String, int> anchors;
}

/// Converts an EPUB content document (XHTML) into [Block]s.
///
/// Walks the DOM: block-level elements start a new block, inline elements
/// add styled runs. CSS is ignored apart from a few class names that
/// Project Gutenberg uses (`poem`, `caption`, `footnote`, `smcap`,
/// `pg-boilerplate`, `x-ebookmaker-pageno`…).
class XhtmlConverter {
  const XhtmlConverter({this.splitter = const SentenceSplitter()});

  final SentenceSplitter splitter;

  /// [documentPath] is the archive path of the document, used to resolve
  /// relative image and link URLs.
  ConvertedDocument convert(String xhtml, {required String documentPath}) {
    final document = XmlDocument.parse(
      _stripBom(xhtml),
      entityMapping: const XmlDefaultEntityMapping.html5(),
    );
    final builder = _BlockBuilder(splitter, documentPath);
    builder.walk(document.rootElement, const _Ctx());
    builder.flush();
    return builder.result();
  }

  static String _stripBom(String s) => s.startsWith('﻿') ? s.substring(1) : s;
}

/// Context inherited while walking the DOM.
class _Ctx {
  const _Ctx({
    this.type = BlockType.paragraph,
    this.level = 0,
    this.preserve = false,
    this.style = const Inline(''),
  });

  final BlockType type;
  final int level;

  /// Inside `<pre>`: keep whitespace and line breaks as written.
  final bool preserve;

  /// Current inline style (its text is unused).
  final Inline style;

  _Ctx copyWith({BlockType? type, int? level, bool? preserve, Inline? style}) =>
      _Ctx(
        type: type ?? this.type,
        level: level ?? this.level,
        preserve: preserve ?? this.preserve,
        style: style ?? this.style,
      );
}

/// One character of the block being built, with its style.
class _Char {
  _Char(this.c, this.style);
  final String c;
  final Inline style;
}

class _BlockBuilder {
  _BlockBuilder(this.splitter, this.documentPath)
    : _docDir = p.posix.dirname(documentPath);

  final SentenceSplitter splitter;
  final String documentPath;
  final String _docDir;

  final _blocks = <Block>[];
  final _anchors = <String, int>{};
  final _pendingAnchors = <String>[];

  // Block being built.
  final _chars = <_Char>[];
  _Ctx? _blockCtx;
  bool _lastWasSpace = true;
  bool _atLineStart = true;

  ConvertedDocument result() {
    for (final id in _pendingAnchors) {
      _anchors.putIfAbsent(id, () => _blocks.isEmpty ? 0 : _blocks.length - 1);
    }
    _pendingAnchors.clear();
    return ConvertedDocument(_blocks, _anchors);
  }

  // ---------------------------------------------------------------- walking

  static const _blockTags = {
    'address',
    'article',
    'aside',
    'blockquote',
    'body',
    'center',
    'dd',
    'div',
    'dl',
    'dt',
    'figcaption',
    'figure',
    'footer',
    'header',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'html',
    'li',
    'main',
    'ol',
    'p',
    'pre',
    'section',
    'table',
    'tbody',
    'tfoot',
    'thead',
    'tr',
    'ul',
  };

  static const _skipTags = {'head', 'script', 'style', 'title', 'template'};

  static const _skipClasses = {'pg-boilerplate', 'x-ebookmaker-pageno'};
  static const _skipIds = {'pg-header', 'pg-footer'};

  void walk(XmlNode node, _Ctx ctx) {
    if (node is XmlText || node is XmlCDATA) {
      _appendText(node.value ?? '', ctx);
    } else if (node is XmlElement) {
      _element(node, ctx);
    }
  }

  void _element(XmlElement el, _Ctx ctx) {
    final tag = el.localName.toLowerCase();
    final classes = (_attr(el, 'class') ?? '')
        .split(RegExp(r'\s+'))
        .where((c) => c.isNotEmpty)
        .toSet();
    final id = _attr(el, 'id');

    if (_skipTags.contains(tag) ||
        classes.any(_skipClasses.contains) ||
        (id != null && _skipIds.contains(id))) {
      return;
    }
    if (id != null) _pendingAnchors.add(id);

    switch (tag) {
      case 'br':
        _lineBreak();
        return;
      case 'hr':
        flush();
        _addBlock(
          Block(
            type: BlockType.separator,
            inlines: const [],
            sentences: const [],
          ),
        );
        return;
      case 'img':
      case 'image':
        _image(el, ctx);
        return;
    }

    if (_blockTags.contains(tag) || classes.contains('caption')) {
      final inner = _enterBlock(ctx, tag, classes);
      flush();
      _children(el, inner);
      flush();
      return;
    }

    // Inline element.
    if (tag == 'td' || tag == 'th') _appendText(' ', ctx);
    _children(
      el,
      ctx.copyWith(style: _inlineStyle(ctx.style, el, tag, classes)),
    );
  }

  void _children(XmlElement el, _Ctx ctx) {
    for (final child in el.children) {
      walk(child, ctx);
    }
  }

  _Ctx _enterBlock(_Ctx parent, String tag, Set<String> classes) {
    BlockType? type;
    var level = 0;
    var preserve = parent.preserve;

    final heading = RegExp(r'^h([1-6])$').firstMatch(tag);
    if (heading != null) {
      type = BlockType.heading;
      level = int.parse(heading.group(1)!);
    } else if (tag == 'pre') {
      type = BlockType.verse;
      preserve = true;
    } else if (tag == 'blockquote') {
      type = BlockType.quote;
    }
    if (classes.contains('caption')) {
      type = BlockType.caption;
    } else if (classes.any(const {'footnote', 'footnotes', 'note'}.contains)) {
      type = BlockType.footnote;
    } else if (classes.any(
      const {'poem', 'poetry', 'stanza', 'verse', 'song'}.contains,
    )) {
      type = BlockType.verse;
    } else if (classes.any(
      const {'blockquot', 'blockquote', 'quote', 'letter'}.contains,
    )) {
      type ??= BlockType.quote;
    }

    // Captions, footnotes, poems and headings keep their type for nested
    // blocks (a <p> inside a caption is still a caption).
    const sticky = {
      BlockType.caption,
      BlockType.footnote,
      BlockType.verse,
      BlockType.heading,
    };
    // A caption always wins: Gutenberg puts illustration captions inside
    // chapter headings.
    if (type == null ||
        (type != BlockType.caption && sticky.contains(parent.type))) {
      return parent.copyWith(preserve: preserve);
    }
    return parent.copyWith(type: type, level: level, preserve: preserve);
  }

  Inline _inlineStyle(
    Inline style,
    XmlElement el,
    String tag,
    Set<String> classes,
  ) {
    var italic = style.italic;
    var bold = style.bold;
    var smallCaps = style.smallCaps;
    var superscript = style.superscript;
    var href = style.href;
    switch (tag) {
      case 'i' || 'em' || 'cite' || 'var' || 'dfn':
        italic = true;
      case 'b' || 'strong':
        bold = true;
      case 'sup':
        superscript = true;
      case 'a':
        final target = _attr(el, 'href');
        if (target != null && target.isNotEmpty) href = _resolveHref(target);
    }
    if (classes.any(const {'smcap', 'smallcaps', 'sc'}.contains)) {
      smallCaps = true;
    }
    if (classes.any(const {'i', 'italic', 'it'}.contains)) italic = true;
    return Inline(
      '',
      italic: italic,
      bold: bold,
      smallCaps: smallCaps,
      superscript: superscript,
      href: href,
    );
  }

  void _image(XmlElement el, _Ctx ctx) {
    final src = _attr(el, 'src') ?? _attr(el, 'href');
    final alt = (_attr(el, 'alt') ?? '').trim();
    // Illustrated drop cap (`<img alt="W" …/>HEN the ladies…`): keep the
    // letter as text.
    if (alt.isNotEmpty &&
        alt.length <= 3 &&
        RegExp(r'^\p{L}+$', unicode: true).hasMatch(alt)) {
      _appendText(alt, ctx);
      _lastWasSpace = false;
      return;
    }
    if (src == null || src.isEmpty) return;
    flush();
    _addBlock(
      Block(
        type: BlockType.image,
        inlines: const [],
        sentences: const [],
        imagePath: _resolvePath(src),
        imageAlt: alt.isEmpty ? null : alt,
      ),
    );
  }

  // ---------------------------------------------------------------- text

  static bool _isCollapsible(String c) =>
      c == ' ' || c == '\n' || c == '\t' || c == '\r' || c == '\f';

  void _appendText(String text, _Ctx ctx) {
    if (text.isEmpty) return;
    if (ctx.preserve) {
      _blockCtx ??= ctx;
      for (final rune in text.runes) {
        final c = String.fromCharCode(rune);
        if (c == '\r') continue;
        _chars.add(_Char(c, ctx.style));
      }
      _lastWasSpace = false;
      return;
    }

    var i = 0;
    // Verse indentation: spaces after a <br/> are meaningful.
    if (_atLineStart && ctx.type == BlockType.verse) {
      var indent = 0;
      while (i < text.length && _isCollapsible(text[i])) {
        indent = text[i] == '\n' ? 0 : indent + 1;
        i++;
      }
      if (i == text.length) return; // only whitespace, wait for real text
      _blockCtx ??= ctx;
      if (indent > 0) {
        for (var k = 0; k < indent.clamp(0, 12); k++) {
          _chars.add(_Char(' ', ctx.style));
        }
      }
      _lastWasSpace = true;
    }

    for (final rune in text.substring(i).runes) {
      final c = String.fromCharCode(rune);
      if (_isCollapsible(c)) {
        if (!_lastWasSpace) {
          _chars.add(_Char(' ', ctx.style));
          _lastWasSpace = true;
        }
      } else {
        _blockCtx ??= ctx;
        _chars.add(_Char(c, ctx.style));
        _lastWasSpace = false;
        _atLineStart = false;
      }
    }
  }

  void _lineBreak() {
    if (_blockCtx == null) return; // nothing in the block yet
    final style = _chars.isEmpty ? const Inline('') : _chars.last.style;
    _chars.add(_Char('\n', style));
    _lastWasSpace = true;
    _atLineStart = true;
  }

  // ---------------------------------------------------------------- blocks

  void flush() {
    final ctx = _blockCtx;
    final chars = ctx == null
        ? const <_Char>[]
        : ctx.preserve
        ? _normalizePreserved(_chars)
        : ctx.type == BlockType.verse
        ? _dedentVerse(_normalize(_chars))
        : _normalize(_chars);
    _chars.clear();
    _blockCtx = null;
    _lastWasSpace = true;
    _atLineStart = true;
    if (ctx == null || chars.isEmpty) return;

    final inlines = _regroup(chars);
    final text = inlines.map((i) => i.text).join();
    final sentences = ctx.type == BlockType.heading
        ? [SentenceSpan(0, text.length)]
        : splitter.split(text);
    _addBlock(
      Block(
        type: ctx.type,
        level: ctx.level,
        inlines: inlines,
        sentences: sentences,
      ),
    );
  }

  void _addBlock(Block block) {
    for (final id in _pendingAnchors) {
      _anchors.putIfAbsent(id, () => _blocks.length);
    }
    _pendingAnchors.clear();
    _blocks.add(block);
  }

  /// Trims the block and removes spaces around line breaks.
  List<_Char> _normalize(List<_Char> chars) {
    final out = <_Char>[];
    for (final ch in chars) {
      if (ch.c == '\n') {
        while (out.isNotEmpty && out.last.c == ' ') {
          out.removeLast();
        }
        // At most one blank line (stanza break).
        if (out.length >= 2 &&
            out[out.length - 1].c == '\n' &&
            out[out.length - 2].c == '\n') {
          continue;
        }
      } else if (ch.c == ' ' && out.isNotEmpty && out.last.c == '\n') {
        continue;
      }
      out.add(ch);
    }
    return _trim(out);
  }

  /// `<pre>`: drop blank first/last lines and the common indentation.
  List<_Char> _normalizePreserved(List<_Char> chars) {
    final lines = <List<_Char>>[[]];
    for (final ch in chars) {
      if (ch.c == '\n') {
        lines.add([]);
      } else {
        if (ch.c == '\t') {
          lines.last.addAll(List.generate(4, (_) => _Char(' ', ch.style)));
        } else {
          lines.last.add(ch);
        }
      }
    }
    bool blank(List<_Char> l) => l.every((c) => c.c.trim().isEmpty);
    while (lines.isNotEmpty && blank(lines.first)) {
      lines.removeAt(0);
    }
    while (lines.isNotEmpty && blank(lines.last)) {
      lines.removeLast();
    }
    if (lines.isEmpty) return const [];

    int indentOf(List<_Char> l) => l.takeWhile((c) => c.c == ' ').length;
    final common = lines
        .where((l) => !blank(l))
        .map(indentOf)
        .reduce((a, b) => a < b ? a : b);

    final out = <_Char>[];
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) {
        final prev = lines[i - 1];
        out.add(_Char('\n', prev.isEmpty ? const Inline('') : prev.last.style));
      }
      var line = blank(lines[i]) ? <_Char>[] : lines[i].sublist(common);
      while (line.isNotEmpty && line.last.c == ' ') {
        line = line.sublist(0, line.length - 1);
      }
      // Leading spaces would be collapsed by nothing, but make them
      // non-breaking so the renderer keeps the indentation.
      var k = 0;
      while (k < line.length && line[k].c == ' ') {
        line[k] = _Char(' ', line[k].style);
        k++;
      }
      out.addAll(line);
    }
    return out;
  }

  /// Poems: remove the indentation shared by every line, so only the
  /// relative indentation remains (source files are often pretty-printed).
  List<_Char> _dedentVerse(List<_Char> chars) {
    final lines = <List<_Char>>[[]];
    for (final ch in chars) {
      if (ch.c == '\n') {
        lines.add([]);
      } else {
        lines.last.add(ch);
      }
    }
    final indents = lines
        .where((l) => l.isNotEmpty)
        .map((l) => l.takeWhile((c) => c.c == '\u00A0').length);
    final common = indents.isEmpty
        ? 0
        : indents.reduce((a, b) => a < b ? a : b);
    if (common == 0) return chars;
    final out = <_Char>[];
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) out.add(_Char('\n', const Inline('')));
      out.addAll(lines[i].isEmpty ? const [] : lines[i].sublist(common));
    }
    return out;
  }

  List<_Char> _trim(List<_Char> chars) {
    var start = 0;
    var end = chars.length;
    bool space(String c) => c == ' ' || c == '\n';
    while (start < end && space(chars[start].c)) {
      start++;
    }
    while (end > start && space(chars[end - 1].c)) {
      end--;
    }
    return chars.sublist(start, end);
  }

  List<Inline> _regroup(List<_Char> chars) {
    final inlines = <Inline>[];
    final buffer = StringBuffer();
    Inline? style;
    for (final ch in chars) {
      if (style == null) {
        style = ch.style;
      } else if (!style.sameStyle(ch.style)) {
        inlines.add(style.withText(buffer.toString()));
        buffer.clear();
        style = ch.style;
      }
      buffer.write(ch.c);
    }
    if (style != null && buffer.isNotEmpty) {
      inlines.add(style.withText(buffer.toString()));
    }
    return inlines;
  }

  // ---------------------------------------------------------------- utils

  String _resolvePath(String href) {
    final withoutFragment = href.split('#').first;
    return p.posix.normalize(
      p.posix.join(_docDir, Uri.decodeFull(withoutFragment)),
    );
  }

  String _resolveHref(String href) {
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(href)) return href;
    final hash = href.indexOf('#');
    final path = hash == 0
        ? documentPath
        : _resolvePath(hash < 0 ? href : href.substring(0, hash));
    return hash < 0 ? path : '$path${href.substring(hash)}';
  }
}

/// Attribute by local name, ignoring namespace prefixes (`xlink:href`).
String? _attr(XmlElement el, String localName) {
  for (final a in el.attributes) {
    if (a.name.local == localName) return a.value;
  }
  return null;
}
