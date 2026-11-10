import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../app/voice_models_view.dart';
import '../epub/epub.dart';
import '../reader/reader_screen.dart';
import '../theme/reader_theme.dart';
import 'library_store.dart';

const _epubTypes = [
  XTypeGroup(
    label: 'EPUB',
    extensions: ['epub'],
    uniformTypeIdentifiers: ['org.idpf.epub-container'],
  ),
];

/// Grid of linked books.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  bool _busy = false;

  LibraryStore get _library => AppScope.of(context).library;

  Future<void> _addBook() async {
    final file = await openFile(acceptedTypeGroups: _epubTypes);
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await _library.addBook(file.path);
      if (result == AddResult.alreadyInLibrary) {
        _toast('This book is already in your library.');
      }
    } on EpubFormatException catch (e) {
      _toast('Could not read this EPUB: ${e.message}');
    } catch (e) {
      _toast('Could not add the book: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _relink(LibraryEntry entry) async {
    final file = await openFile(acceptedTypeGroups: _epubTypes);
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await _library.relink(entry.id, file.path);
      _toast('Relinked “${entry.title}”.');
    } on EpubFormatException catch (e) {
      _toast('Could not read this EPUB: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _remove(LibraryEntry entry) {
    final removed = _library.remove(entry.id);
    if (removed == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Removed “${entry.title}” from the library.'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => _library.restore(removed),
          ),
        ),
      );
  }

  Future<void> _open(LibraryEntry entry) async {
    if (!entry.fileExists) {
      await _showMissing(entry);
      return;
    }
    _library.markOpened(entry.id);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ReaderScreen(entryId: entry.id)),
    );
  }

  Future<void> _showMissing(LibraryEntry entry) async {
    final relink = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('File not found'),
        content: Text(
          '“${entry.title}” was linked from\n${entry.path}\n\n'
          'The file has been moved, renamed or deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Find the file…'),
          ),
        ],
      ),
    );
    if (relink ?? false) await _relink(entry);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final library = _library;
    final speech = AppScope.of(context).speech;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          if (speech != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SpeechModelButton(models: speech),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _busy ? null : _addBook,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              label: const Text('Add book'),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: library,
        builder: (context, _) {
          final entries = library.entries;
          if (entries.isEmpty) {
            return _EmptyLibrary(onAdd: _busy ? null : _addBook);
          }
          return GridView.builder(
            padding: const EdgeInsets.all(24),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 190,
              mainAxisSpacing: 28,
              crossAxisSpacing: 24,
              childAspectRatio: 0.5,
            ),
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final entry = entries[i];
              return _BookCard(
                key: ValueKey(entry.id),
                entry: entry,
                onOpen: () => _open(entry),
                onRelink: () => _relink(entry),
                onRemove: () => _remove(entry),
              );
            },
          );
        },
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onAdd});

  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.menu_book_outlined,
            size: 64,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text('No books yet', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Link an .epub file from your disk, e.g. from Project Gutenberg.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Add book'),
          ),
        ],
      ),
    );
  }
}

enum _CardAction { open, relink, remove }

class _BookCard extends StatelessWidget {
  const _BookCard({
    super.key,
    required this.entry,
    required this.onOpen,
    required this.onRelink,
    required this.onRemove,
  });

  final LibraryEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onRelink;
  final VoidCallback onRemove;

  void _run(_CardAction? action) {
    switch (action) {
      case _CardAction.open:
        onOpen();
      case _CardAction.relink:
        onRelink();
      case _CardAction.remove:
        onRemove();
      case null:
        break;
    }
  }

  List<PopupMenuEntry<_CardAction>> _menuItems() => const [
    PopupMenuItem(value: _CardAction.open, child: Text('Open')),
    PopupMenuItem(value: _CardAction.relink, child: Text('Relink file…')),
    PopupMenuDivider(),
    PopupMenuItem(
      value: _CardAction.remove,
      child: Text('Remove from library'),
    ),
  ];

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<_CardAction>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: _menuItems(),
    );
    _run(action);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reader = ReaderTheme.of(context);
    final missing = !entry.fileExists;
    final progress = entry.chapterCount <= 1
        ? null
        : (entry.position.chapter + 1) / entry.chapterCount;

    return GestureDetector(
      onSecondaryTapUp: (d) => _showContextMenu(context, d.globalPosition),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Material(
              color: reader.surface,
              elevation: 2,
              borderRadius: BorderRadius.circular(6),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onOpen,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Opacity(
                      opacity: missing ? 0.35 : 1,
                      child: _Cover(entry: entry),
                    ),
                    if (missing)
                      Center(
                        child: Chip(
                          avatar: const Icon(Icons.link_off, size: 16),
                          label: const Text('File not found'),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // Fixed heights below the cover so every cover has the same size.
          SizedBox(
            height: 9,
            child: progress != null && entry.lastOpenedAt != null
                ? Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(2),
                      backgroundColor: reader.divider,
                    ),
                  )
                : null,
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 62,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: InkWell(
                    onTap: onOpen,
                    borderRadius: BorderRadius.circular(4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        if (entry.authors.isNotEmpty)
                          Text(
                            entry.authorLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: reader.secondaryText,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                PopupMenuButton<_CardAction>(
                  tooltip: 'Book options',
                  icon: const Icon(Icons.more_vert, size: 20),
                  padding: EdgeInsets.zero,
                  itemBuilder: (_) => _menuItems(),
                  onSelected: _run,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.entry});

  final LibraryEntry entry;

  @override
  Widget build(BuildContext context) {
    final cover = entry.coverFile;
    if (cover != null && File(cover).existsSync()) {
      return Image.file(
        File(cover),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) => _placeholder(context),
      );
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    final reader = ReaderTheme.of(context);
    return Container(
      color: reader.accent.withValues(alpha: 0.15),
      padding: const EdgeInsets.all(14),
      alignment: Alignment.center,
      child: Text(
        entry.title,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'Georgia',
          fontSize: 17,
          color: reader.text,
          height: 1.3,
        ),
      ),
    );
  }
}
