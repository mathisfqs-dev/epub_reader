import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../app/app_scope.dart';
import '../app/reader_settings.dart';
import '../epub/epub.dart';
import '../library/library_store.dart';
import '../theme/reader_theme.dart';
import '../dictionary/dictionaries.dart';
import '../translate/read_aloud_translation.dart';
import '../translate/translation_controller.dart';
import '../translate/translation_model.dart';
import '../translate/translation_panel.dart';
import '../tts/audio_output.dart';
import '../app/voice_models_view.dart';
import '../tts/voice.dart';
import '../tts/read_aloud_controller.dart';
import 'appearance_panel.dart';
import 'block_view.dart';
import 'read_aloud_bar.dart';
import 'selection_bubble.dart';
import 'toc_drawer.dart';

/// Loads a library book (in a background isolate) and shows [ReaderView].
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.entryId});

  final String entryId;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  Future<Book>? _book;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_book != null) return;
    final entry = AppScope.of(context).library.byId(widget.entryId);
    if (entry == null) {
      _book = Future.error(
        StateError('This book is no longer in the library.'),
      );
    } else {
      final path = entry.path;
      _book = Isolate.run(() => const EpubParser().parseFile(path));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final entry = scope.library.byId(widget.entryId);
    return FutureBuilder<Book>(
      future: _book,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _Message(
            title: entry?.title ?? 'Book',
            icon: Icons.error_outline,
            message: 'Could not open this book.\n${snapshot.error}',
          );
        }
        if (!snapshot.hasData) {
          return _Message(
            title: entry?.title ?? 'Book',
            child: const CircularProgressIndicator(),
          );
        }
        return ReaderView(
          book: snapshot.data!,
          settings: scope.settings,
          initialPosition: entry?.position ?? const ReadingPosition(),
          onPositionChanged: (p) =>
              scope.library.updatePosition(widget.entryId, p),
          voiceModel: scope.speech?.active,
          translation: scope.translation,
          dictionaries: scope.dictionaries,
        );
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, this.icon, this.message, this.child});

  final String title;
  final IconData? icon;
  final String? message;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) Icon(icon, size: 48),
              ?child,
              if (message != null) ...[
                const SizedBox(height: 16),
                Text(message!, textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The reader: one chapter (spine document) at a time, scrolling.
class ReaderView extends StatefulWidget {
  const ReaderView({
    super.key,
    required this.book,
    required this.settings,
    this.initialPosition = const ReadingPosition(),
    this.onPositionChanged,
    this.voiceModel,
    this.createReadAloud,
    this.translation,
    this.dictionaries,
  });

  final Book book;
  final ReaderSettings settings;
  final ReadingPosition initialPosition;
  final ValueChanged<ReadingPosition>? onPositionChanged;

  /// Enables read-aloud when not null.
  final VoiceModel? voiceModel;

  /// Builds the read-aloud controller (tests); by default it uses
  /// [voiceModel]'s engine and plays through audioplayers.
  final ReadAloudController Function(Book book)? createReadAloud;

  /// Enables "Translate" when not null.
  final TranslationModel? translation;

  /// Word lookups when a single word is translated.
  final Dictionaries? dictionaries;

  @override
  State<ReaderView> createState() => ReaderViewState();
}

class ReaderViewState extends State<ReaderView> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _images = <String, Uint8List?>{};

  late int _chapter;
  late int _initialBlock;
  late ItemScrollController _scroll;
  late ItemPositionsListener _positions;
  late ScrollOffsetController _scrollOffset;
  final _viewportKey = GlobalKey();
  late final ValueNotifier<ReadingPosition> _position;
  final _blockKeys = <int, GlobalKey<BlockViewState>>{};
  ReadAloudController? _readAloud;
  TranslationController? _translation;
  ReadAloudTranslation? _readAloudTranslation;
  SentenceRef? _followed;
  Offset? _lastRightClick;
  final _selectionKey = GlobalKey<SelectionAreaState>();
  final _bubble = ContextMenuController();
  String? _selectedText;
  late final String _language = languageCode(book.metadata.language);

  /// Sentences before each chapter, to show progress through the book.
  late final List<int> _sentencesBefore;

  Book get book => widget.book;
  Chapter get chapter => book.chapters[_chapter];
  int get chapterIndex => _chapter;
  ReadingPosition get position => _position.value;
  ReadAloudController? get readAloud => _readAloud;
  TranslationController? get translation => _translation;

  @override
  void initState() {
    super.initState();
    final start = widget.initialPosition;
    _chapter = start.chapter.clamp(0, book.chapters.length - 1);
    _initialBlock = start.block.clamp(0, chapter.blocks.length - 1);
    _position = ValueNotifier(
      ReadingPosition(chapter: _chapter, block: _initialBlock),
    );
    var total = 0;
    _sentencesBefore = [
      for (final c in book.chapters)
        (total += c.sentenceCount) - c.sentenceCount,
    ];
    _newList();
  }

  @override
  void dispose() {
    _positions.itemPositions.removeListener(_onScroll);
    _position.dispose();
    _bubble.remove();
    _readAloud?.removeListener(_followReading);
    _readAloudTranslation?.dispose();
    _readAloud?.dispose();
    _translation?.dispose();
    super.dispose();
  }

  void _newList() {
    _scroll = ItemScrollController();
    _positions = ItemPositionsListener.create();
    _scrollOffset = ScrollOffsetController();
    _positions.itemPositions.addListener(_onScroll);
  }

  void _onScroll() {
    if (_bubble.isShown) _bubble.remove(); // it would float off its text
    final visible = _positions.itemPositions.value.where(
      (p) => p.itemTrailingEdge > 0.02 && p.itemLeadingEdge < 0.98,
    );
    if (visible.isEmpty) return;
    final first = visible.map((p) => p.index).reduce(math.min);
    final block = first.clamp(0, chapter.blocks.length - 1);
    _setPosition(ReadingPosition(chapter: _chapter, block: block));
  }

  void _setPosition(ReadingPosition p) {
    if (_position.value == p) return;
    _position.value = p;
    widget.onPositionChanged?.call(p);
  }

  /// Jumps to a block of a chapter.
  void goTo(int chapterIndex, [int block = 0]) {
    final c = chapterIndex.clamp(0, book.chapters.length - 1);
    final b = block.clamp(0, book.chapters[c].blocks.length - 1);
    if (c == _chapter && _scroll.isAttached) {
      _scroll.jumpTo(index: b);
    } else {
      _positions.itemPositions.removeListener(_onScroll);
      setState(() {
        _chapter = c;
        _initialBlock = b;
        _blockKeys.clear();
        _newList();
      });
    }
    _setPosition(ReadingPosition(chapter: c, block: b));
  }

  // ------------------------------------------------------------ read aloud

  ReadAloudController _controller() {
    final existing = _readAloud;
    if (existing != null) return existing;
    final created =
        widget.createReadAloud?.call(book) ??
        _defaultController(widget.voiceModel!);
    created.addListener(_followReading);
    final model = widget.translation;
    setState(() {
      _readAloud = created;
      if (model != null) {
        _readAloudTranslation = ReadAloudTranslation(
          readAloud: created,
          settings: widget.settings,
          model: model,
          source: _language,
        );
      }
    });
    return created;
  }

  ReadAloudController _defaultController(VoiceModel model) =>
      ReadAloudController(
        book: book,
        synthesizer: model.engine,
        output: PlayerAudioOutput(),
        voice: widget.settings.voiceIn(model, _language),
        speed: model.supportsSpeed ? widget.settings.speechSpeed : 1.0,
      );

  /// Starts reading at [from], or at the top of the page. Offers to download
  /// the voice model first if needed.
  Future<void> startReading([SentenceRef? from]) async {
    final model = widget.voiceModel;
    if (model == null) return;
    if (!model.isReady) {
      if (!await showVoiceModelDialog(context, model) || !mounted) return;
    }
    _controller().startAt(
      from ?? SentenceRef(_chapter, _firstVisibleBlock() ?? 0, 0),
    );
  }

  int? _firstVisibleBlock() {
    final visible = _positions.itemPositions.value
        .where(
          (p) => p.itemTrailingEdge > 0.02 && p.index < chapter.blocks.length,
        )
        .map((p) => p.index);
    return visible.isEmpty ? null : visible.reduce(math.min);
  }

  /// The sentence under a point of the screen, if any.
  SentenceRef? _sentenceAt(Offset global) {
    for (final p in _positions.itemPositions.value) {
      final i = _blockKeys[p.index]?.currentState?.sentenceAt(global);
      if (i != null) return SentenceRef(_chapter, p.index, i);
    }
    return null;
  }

  /// Keeps the sentence being read on screen.
  void _followReading() {
    final ref = _readAloud?.current;
    if (ref == _followed) return;
    _followed = ref;
    if (ref == null || !mounted) return;
    final block = ref.block;
    if (ref.chapter != _chapter) {
      goTo(ref.chapter, block);
      _followAfterLayout(ref);
      return;
    }
    if (!_scroll.isAttached) return;
    final visible = _positions.itemPositions.value.any((p) => p.index == block);
    if (!visible) {
      // Far away: jump (scrollTo cross-fades two lists, which is distracting
      // while reading), then place the sentence itself.
      _scroll.jumpTo(index: block, alignment: 0.15);
      _followAfterLayout(ref);
      return;
    }
    _keepOnScreen(ref);
  }

  void _followAfterLayout(SentenceRef ref) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _readAloud?.current == ref) _keepOnScreen(ref);
    });
  }

  /// Scrolls when the sentence [ref] (not just its paragraph, which may be
  /// taller than the screen) leaves the comfortable band of the screen, so
  /// that it starts at 20 % of the height.
  void _keepOnScreen(SentenceRef ref) {
    if (ref.chapter != _chapter || !_scroll.isAttached) return;
    final viewport =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    final rect = ref.isTitle
        ? null
        : _blockKeys[ref.block]?.currentState?.sentenceRect(ref.sentence);
    if (viewport == null || !viewport.hasSize || rect == null) {
      // Title, or not laid out yet: place its block.
      final item = _positions.itemPositions.value
          .where((p) => p.index == ref.block)
          .firstOrNull;
      if (item == null ||
          item.itemLeadingEdge < 0 ||
          item.itemLeadingEdge > 0.8) {
        _scroll.jumpTo(index: ref.block, alignment: 0.15);
      }
      return;
    }
    final height = viewport.size.height;
    final top = rect.top - viewport.localToGlobal(Offset.zero).dy;
    final bottom = top + rect.height;
    if (top >= height * 0.08 && bottom <= height * 0.85) return;
    _scrollOffset.animateScroll(
      offset: top - height * 0.2,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
  }

  // ------------------------------------------------------------ selection

  /// Actions offered on selected text, starting at the global point [from].
  List<SelectionAction> _selectionActions(Offset from) => [
    if (widget.voiceModel != null)
      SelectionAction(
        icon: Icons.headphones_outlined,
        label: 'Read aloud from here',
        onPressed: () {
          _bubble.remove();
          _selectionKey.currentState?.selectableRegion.clearSelection();
          startReading(_sentenceAt(from));
        },
      ),
    if (widget.translation != null && !_autoTranslates)
      SelectionAction(
        icon: Icons.translate,
        label: 'Translate',
        onPressed: () {
          _bubble.remove();
          translate(_selectedText, at: from);
        },
      ),
  ];

  /// Selections are translated as soon as they are made.
  bool get _autoTranslates =>
      widget.settings.autoTranslateSelection && (_translation?.isOpen ?? false);

  void _onSelectionChanged(SelectedContent? content) {
    _selectedText = content?.plainText;
    if ((_selectedText ?? '').trim().isEmpty && _bubble.isShown) {
      _bubble.remove();
    }
  }

  /// Shows the [SelectionBubble] once a mouse selection is made.
  void _showSelectionBubble() {
    if (!mounted || (_selectedText ?? '').trim().isEmpty) return;
    final region = _selectionKey.currentState?.selectableRegion;
    final box = region?.context.findRenderObject() as RenderBox?;
    if (region == null || box == null || !box.attached) return;
    final points = [
      for (final p in region.selectionEndpoints) box.localToGlobal(p.point),
    ];
    if (points.isEmpty) return;
    // Where the selection starts in reading order (points are at the bottom
    // of their line).
    final start = points.reduce(
      (a, b) => (a.dy - b.dy).abs() < 1
          ? (a.dx <= b.dx ? a : b)
          : (a.dy < b.dy ? a : b),
    );
    final from = start - Offset(0, region.startGlyphHeight / 2);
    if (_autoTranslates &&
        _selectedText!.trim() != _translation!.request?.text) {
      translate(_selectedText, at: from);
    }
    final actions = _selectionActions(from);
    if (actions.isEmpty) return;
    final anchors = region.contextMenuAnchors;
    final viewport =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    final minTop = viewport == null || !viewport.hasSize
        ? 0.0
        : viewport.localToGlobal(Offset.zero).dy;
    _bubble.show(
      context: context,
      contextMenuBuilder: (_) =>
          SelectionBubble(anchors: anchors, actions: actions, minTop: minTop),
    );
  }

  Widget _contextMenu(BuildContext context, SelectableRegionState state) {
    final anchors = state.contextMenuAnchors;
    final items = [...state.contextMenuButtonItems];
    if (widget.voiceModel != null) {
      final at = _lastRightClick ?? anchors.primaryAnchor;
      items.add(
        ContextMenuButtonItem(
          label: 'Read aloud from here',
          onPressed: () {
            state.hideToolbar();
            startReading(_sentenceAt(at));
          },
        ),
      );
    }
    if (widget.translation != null) {
      final at = _lastRightClick ?? anchors.primaryAnchor;
      if ((_selectedText ?? '').trim().isNotEmpty) {
        items.add(
          ContextMenuButtonItem(
            label: 'Translate',
            onPressed: () {
              state.hideToolbar();
              translate(_selectedText, at: at);
            },
          ),
        );
      }
      if (_sentenceAt(at) != null) {
        items.add(
          ContextMenuButtonItem(
            label: 'Translate sentence',
            onPressed: () {
              state.hideToolbar();
              translate(null, at: at);
            },
          ),
        );
      }
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: anchors,
      buttonItems: items,
    );
  }

  // ------------------------------------------------------------ translation

  /// Translates [text], or the sentence at the global point [at] when [text]
  /// is empty, in the side panel. The paragraph at [at] is sent as context.
  void translate(String? text, {Offset? at}) {
    final model = widget.translation;
    if (model == null) return;
    final ref = at == null ? null : _sentenceAt(at);
    final block = ref == null ? null : chapter.blocks[ref.block];
    final passage = (text ?? '').trim().isNotEmpty
        ? text!
        : block?.sentenceText(ref!.sentence);
    if (passage == null || passage.trim().isEmpty) return;
    final controller =
        _translation ??
        TranslationController(
          model: model,
          settings: widget.settings,
          source: _language,
          dictionaries: widget.dictionaries,
        );
    if (_translation == null) setState(() => _translation = controller);
    controller.translate(
      passage,
      context: block?.text,
      sentence: ref == null || ref.isTitle
          ? null
          : block?.sentenceText(ref.sentence),
    );
  }

  void _openLink(String href) {
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(href)) return; // external
    final hash = href.indexOf('#');
    final path = hash < 0 ? href : href.substring(0, hash);
    final fragment = hash < 0 ? null : href.substring(hash + 1);
    final index = book.chapters.indexWhere((c) => c.path == path);
    if (index < 0) return;
    goTo(
      index,
      fragment == null ? 0 : book.chapters[index].anchors[fragment] ?? 0,
    );
  }

  /// Title of the TOC entry the reader is in (a file can hold several
  /// chapters), else the file's title.
  String _sectionTitle(ReadingPosition p) {
    final i = TocDrawer.currentEntry(book, p);
    if (i >= 0 && book.toc[i].chapterIndex == p.chapter) {
      return book.toc[i].title;
    }
    return book.chapters[p.chapter].title ?? 'Section ${p.chapter + 1}';
  }

  double _progress(ReadingPosition p) {
    final total = book.sentenceCount;
    if (total == 0) return 0;
    final blocks = book.chapters[p.chapter].blocks;
    var before = _sentencesBefore[p.chapter];
    for (var i = 0; i < p.block && i < blocks.length; i++) {
      before += blocks[i].sentences.length;
    }
    return before / total;
  }

  @override
  Widget build(BuildContext context) {
    final reader = ReaderTheme.of(context);
    final theme = Theme.of(context);
    final hasPrevious = _chapter > 0;
    final hasNext = _chapter < book.chapters.length - 1;

    return Scaffold(
      key: _scaffoldKey,
      drawer: TocDrawer(
        book: book,
        position: _position.value,
        onSelect: (entry) {
          Navigator.of(context).pop();
          goTo(entry.chapterIndex, entry.blockIndex);
        },
      ),
      appBar: AppBar(
        leading: const BackButton(),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              book.metadata.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
            ValueListenableBuilder(
              valueListenable: _position,
              builder: (context, p, _) => Text(
                _sectionTitle(p),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: reader.secondaryText,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Contents',
            icon: const Icon(Icons.toc),
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          IconButton(
            tooltip: 'Previous chapter',
            icon: const Icon(Icons.chevron_left),
            onPressed: hasPrevious ? () => goTo(_chapter - 1) : null,
          ),
          IconButton(
            tooltip: 'Next chapter',
            icon: const Icon(Icons.chevron_right),
            onPressed: hasNext ? () => goTo(_chapter + 1) : null,
          ),
          if (widget.voiceModel != null)
            ListenableBuilder(
              listenable: _readAloud ?? const _Never(),
              builder: (context, _) {
                final active = _readAloud?.isActive ?? false;
                return IconButton(
                  tooltip: active ? 'Stop reading aloud' : 'Read aloud',
                  isSelected: active,
                  icon: const Icon(Icons.headphones_outlined),
                  selectedIcon: const Icon(Icons.headphones),
                  onPressed: active ? _readAloud!.stop : startReading,
                );
              },
            ),
          AppearanceButton(settings: widget.settings),
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: ValueListenableBuilder(
            valueListenable: _position,
            builder: (context, p, _) => LinearProgressIndicator(
              value: _progress(p),
              minHeight: 2,
              backgroundColor: reader.divider,
            ),
          ),
        ),
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: widget.settings,
              builder: (context, _) => LayoutBuilder(
                builder: (context, constraints) =>
                    _chapterList(reader, constraints),
              ),
            ),
          ),
          if (_translation != null)
            ListenableBuilder(
              listenable: _translation!,
              builder: (context, _) => _translation!.isOpen
                  ? Row(
                      children: [
                        VerticalDivider(width: 1, color: reader.divider),
                        SizedBox(
                          width: TranslationPanel.width,
                          child: TranslationPanel(
                            controller: _translation!,
                            fontFamily: widget.settings.font.family,
                            fontSize: widget.settings.fontSize * 0.9,
                          ),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
        ],
      ),
      bottomNavigationBar: _readAloud == null
          ? null
          : ListenableBuilder(
              listenable: _readAloud!,
              builder: (context, _) => _readAloud!.isActive
                  ? ReadAloudBar(
                      controller: _readAloud!,
                      settings: widget.settings,
                      language: _language,
                      model: widget.voiceModel!,
                      translation: _readAloudTranslation,
                    )
                  : const SizedBox.shrink(),
            ),
    );
  }

  Widget _block(int i, BlockStyle style, BoxConstraints constraints) {
    Widget build(int? highlight) => BlockView(
      key: _blockKeys.putIfAbsent(i, GlobalKey<BlockViewState>.new),
      block: chapter.blocks[i],
      style: style,
      loadImage: (path) => _images.putIfAbsent(path, () => book.resource(path)),
      onLink: _openLink,
      maxImageHeight: constraints.maxHeight * 0.75,
      highlightSentence: highlight,
    );
    final controller = _readAloud;
    if (controller == null) return build(null);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final ref = controller.current;
        return build(
          ref != null &&
                  !ref.isTitle &&
                  ref.chapter == _chapter &&
                  ref.block == i
              ? ref.sentence
              : null,
        );
      },
    );
  }

  Widget _chapterList(ReaderTheme reader, BoxConstraints constraints) {
    final s = widget.settings;
    final style = BlockStyle(
      theme: reader,
      fontSize: s.fontSize,
      lineHeight: s.lineHeight,
      fontFamily: s.font.family,
      justify: s.justify,
    );
    // About 70 characters per line.
    final columnWidth = s.fontSize * 36;
    final blocks = chapter.blocks;

    return Listener(
      onPointerDown: (e) {
        if (e.buttons & kSecondaryMouseButton != 0) {
          _lastRightClick = e.position;
        } else if (_bubble.isShown) {
          _bubble.remove();
        }
      },
      onPointerUp: (e) {
        if (e.kind != PointerDeviceKind.mouse || _lastRightClick != null) {
          _lastRightClick = null;
          return;
        }
        // After the selection has handled the release (double-click selects
        // the word on release).
        Future<void>.delayed(Duration.zero, _showSelectionBubble);
      },
      child: SelectionArea(
        key: _selectionKey,
        onSelectionChanged: _onSelectionChanged,
        contextMenuBuilder: _contextMenu,
        child: KeyedSubtree(
          key: _viewportKey,
          child: ScrollablePositionedList.builder(
            key: ValueKey(_chapter),
            itemScrollController: _scroll,
            scrollOffsetController: _scrollOffset,
            itemPositionsListener: _positions,
            initialScrollIndex: _initialBlock,
            padding: const EdgeInsets.symmetric(vertical: 32),
            itemCount: blocks.length + 1,
            itemBuilder: (context, i) {
              final Widget child = i < blocks.length
                  ? _block(i, style, constraints)
                  : _ChapterFooter(
                      previous: _chapter > 0 ? () => goTo(_chapter - 1) : null,
                      next: _chapter < book.chapters.length - 1
                          ? () => goTo(_chapter + 1)
                          : null,
                      nextTitle: _chapter < book.chapters.length - 1
                          ? book.chapters[_chapter + 1].title
                          : null,
                    );
              // Fixed-width centered column: blocks always fill it, so short
              // lines stay left-aligned.
              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: math.min(constraints.maxWidth, columnWidth + 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: child,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A listenable that never notifies.
class _Never implements Listenable {
  const _Never();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

class _ChapterFooter extends StatelessWidget {
  const _ChapterFooter({this.previous, this.next, this.nextTitle});

  final VoidCallback? previous;
  final VoidCallback? next;
  final String? nextTitle;

  @override
  Widget build(BuildContext context) {
    final reader = ReaderTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 40, bottom: 24),
      child: Column(
        children: [
          Divider(color: reader.divider),
          const SizedBox(height: 20),
          if (next == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                'The end',
                style: TextStyle(
                  color: reader.secondaryText,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              if (previous != null)
                OutlinedButton.icon(
                  onPressed: previous,
                  icon: const Icon(Icons.chevron_left),
                  label: const Text('Previous chapter'),
                ),
              if (next != null)
                FilledButton.icon(
                  onPressed: next,
                  icon: const Icon(Icons.chevron_right),
                  iconAlignment: IconAlignment.end,
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Text(
                      nextTitle == null ? 'Next chapter' : 'Next: $nextTitle',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
