import 'package:flutter/material.dart';

import '../epub/epub.dart';
import '../library/library_store.dart';
import '../theme/reader_theme.dart';

/// Table of contents. Highlights the entry for the current reading position.
class TocDrawer extends StatefulWidget {
  const TocDrawer({
    super.key,
    required this.book,
    required this.position,
    required this.onSelect,
  });

  final Book book;
  final ReadingPosition position;
  final ValueChanged<TocEntry> onSelect;

  /// Index of the last TOC entry at or before [p].
  static int currentEntry(Book book, ReadingPosition p) {
    var current = -1;
    for (var i = 0; i < book.toc.length; i++) {
      final e = book.toc[i];
      if (e.chapterIndex < 0) continue;
      final before =
          e.chapterIndex < p.chapter ||
          (e.chapterIndex == p.chapter && e.blockIndex <= p.block);
      if (before) current = i;
    }
    return current;
  }

  @override
  State<TocDrawer> createState() => _TocDrawerState();
}

class _TocDrawerState extends State<TocDrawer> {
  static const _rowHeight = 44.0;
  late final List<TocEntry> _entries;
  late final int _current;
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    final book = widget.book;
    _entries = book.toc.isNotEmpty
        ? book.toc
        : [
            // No TOC in the book: list its chapters instead.
            for (var i = 0; i < book.chapters.length; i++)
              TocEntry(
                title: book.chapters[i].title ?? 'Section ${i + 1}',
                depth: 0,
                path: book.chapters[i].path,
              )..chapterIndex = i,
          ];
    _current = book.toc.isNotEmpty
        ? TocDrawer.currentEntry(book, widget.position)
        : widget.position.chapter;
    // Open scrolled near the current entry.
    _scroll = ScrollController(
      initialScrollOffset:
          (_current - 4).clamp(0, _entries.length) * _rowHeight,
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reader = ReaderTheme.of(context);

    return Drawer(
      width: 340,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Contents', style: theme.textTheme.titleMedium),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemExtent: _rowHeight,
                itemCount: _entries.length,
                itemBuilder: (context, i) {
                  final e = _entries[i];
                  final selected = i == _current;
                  return ListTile(
                    dense: true,
                    selected: selected,
                    selectedTileColor: reader.accent.withValues(alpha: 0.12),
                    contentPadding: EdgeInsets.only(
                      left: 20.0 + e.depth * 16,
                      right: 16,
                    ),
                    title: Text(
                      e.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? reader.accent : reader.text,
                        fontWeight: selected ? FontWeight.w600 : null,
                      ),
                    ),
                    onTap: e.chapterIndex < 0 ? null : () => widget.onSelect(e),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
