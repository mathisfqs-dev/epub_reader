import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../epub/epub.dart';
import 'audio_clip.dart';
import 'audio_output.dart';
import 'voice.dart';
import 'speech_pauses.dart';
import 'tts_engine.dart';

/// A sentence of a book, or the name of a chapter spoken before the
/// sentence `(chapter, block, 0)` ([isTitle]).
@immutable
class SentenceRef implements Comparable<SentenceRef> {
  const SentenceRef(this.chapter, this.block, this.sentence);

  /// A name from the table of contents, spoken before the first sentence
  /// of [block]. It sorts just before that sentence.
  const SentenceRef.title(this.chapter, this.block) : sentence = -1;

  final int chapter;
  final int block;
  final int sentence;

  bool get isTitle => sentence < 0;

  @override
  int compareTo(SentenceRef other) => chapter != other.chapter
      ? chapter - other.chapter
      : block != other.block
      ? block - other.block
      : sentence - other.sentence;

  @override
  bool operator ==(Object other) =>
      other is SentenceRef &&
      other.chapter == chapter &&
      other.block == block &&
      other.sentence == sentence;

  @override
  int get hashCode => Object.hash(chapter, block, sentence);

  @override
  String toString() => isTitle
      ? 'SentenceRef.title($chapter, $block)'
      : 'SentenceRef($chapter, $block, $sentence)';
}

enum ReadAloudState { stopped, loading, playing, paused }

/// Reads a book aloud sentence by sentence: synthesizes each sentence (and
/// the next ones ahead of time), plays it, moves on, across chapters.
///
/// Each clip ends with a silence (see [SpeechPauses]), and a chapter whose
/// text doesn't start with its name gets the name read first.
class ReadAloudController extends ChangeNotifier {
  ReadAloudController({
    required this.book,
    required this._synthesizer,
    required this.output,
    required this._voice,
    this._speed = 1.0,
    this.prefetch = 2,
    this.pauses = const SpeechPauses(),
  });

  /// Blocks that are read; captions, footnotes, images and separators are
  /// skipped.
  static const readTypes = {
    BlockType.heading,
    BlockType.paragraph,
    BlockType.quote,
    BlockType.verse,
  };

  final Book book;
  final AudioOutput output;
  final int prefetch;
  final SpeechPauses pauses;
  final Future<Synthesizer> Function() _synthesizer;

  Voice _voice;
  double _speed;
  SentenceRef? _current;
  var _state = ReadAloudState.stopped;
  String? _error;

  /// Incremented on every jump/stop: a running loop with an older value
  /// exits.
  var _generation = 0;
  var _paused = false;
  var _audioStarted = false;
  Completer<void>? _resume;
  final _clips = <SentenceRef, Future<AudioClip>>{};

  SentenceRef? get current => _current;
  ReadAloudState get state => _state;
  bool get isActive => _state != ReadAloudState.stopped;
  bool get isPlaying => _state == ReadAloudState.playing;
  String? get error => _error;
  Voice get voice => _voice;
  double get speed => _speed;

  set voice(Voice value) {
    if (value == _voice) return;
    _voice = value;
    _restartWithNewSettings();
  }

  set speed(double value) {
    if (value == _speed) return;
    _speed = value;
    _restartWithNewSettings();
  }

  void _restartWithNewSettings() {
    _clips.clear();
    final ref = _current;
    if (ref != null && isActive && !_paused) {
      _jump(ref);
    } else {
      notifyListeners();
    }
  }

  // ------------------------------------------------------------- commands

  /// Starts reading at [from], or at the next readable sentence after it.
  void startAt(SentenceRef from) {
    final ref = firstReadableFrom(from);
    if (ref == null) return;
    _error = null;
    _paused = false;
    _jump(ref);
  }

  /// Starts reading at the beginning of a block.
  void startAtBlock(int chapter, int block) =>
      startAt(SentenceRef(chapter, block, 0));

  void pause() {
    if (!isActive || _paused) return;
    _paused = true;
    if (_audioStarted) output.pause();
    _setState(ReadAloudState.paused);
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    final waiting = _resume;
    if (waiting != null) {
      _resume = null;
      waiting.complete();
    } else if (_audioStarted) {
      output.resume();
      _setState(ReadAloudState.playing);
    } else {
      _setState(ReadAloudState.loading);
    }
  }

  void togglePause() => _paused ? resume() : pause();

  void next() {
    final ref = _current;
    if (ref == null) return;
    final n = nextOf(ref);
    if (n == null) {
      stop();
    } else {
      _paused = false;
      _jump(n);
    }
  }

  void previous() {
    final ref = _current;
    if (ref == null) return;
    _paused = false;
    _jump(previousOf(ref) ?? ref);
  }

  void stop() {
    _generation++;
    _current = null;
    _paused = false;
    _resume = null;
    _clips.clear();
    if (_audioStarted) output.stop();
    _audioStarted = false;
    _setState(ReadAloudState.stopped);
  }

  void _jump(SentenceRef ref) {
    final generation = ++_generation;
    _resume = null;
    if (_audioStarted) output.stop();
    _audioStarted = false;
    _current = ref;
    _state = _paused ? ReadAloudState.paused : ReadAloudState.loading;
    notifyListeners();
    _run(generation);
  }

  Future<void> _run(int generation) async {
    while (generation == _generation) {
      final ref = _current!;
      final AudioClip clip;
      try {
        clip = await _clip(ref);
      } catch (e) {
        if (generation == _generation) {
          stop();
          _error = '$e';
          notifyListeners();
        }
        return;
      }
      if (generation != _generation) return;
      _prefetchAfter(ref);
      if (_paused) {
        final waiting = _resume = Completer<void>();
        await waiting.future;
        if (generation != _generation) return;
      }
      _audioStarted = true;
      _setState(ReadAloudState.playing);
      try {
        await output.play(clip);
      } catch (e) {
        if (generation == _generation) {
          stop();
          _error = 'Playback failed: $e';
          notifyListeners();
        }
        return;
      }
      if (generation != _generation) return;
      _audioStarted = false;
      final n = nextOf(ref);
      if (n == null) {
        stop();
        return;
      }
      _clips.remove(ref);
      _current = n;
      if (!_clips.containsKey(n)) _state = ReadAloudState.loading;
      notifyListeners();
    }
  }

  Future<AudioClip> _clip(SentenceRef ref) => _clips.putIfAbsent(ref, () {
    final text = speakableText(textOf(ref));
    if (text.isEmpty) return Future.value(AudioClip(Float32List(0), 24000));
    final voice = _voice;
    final speed = _speed;
    final pause = pauseAfter(ref, text);
    return _synthesizer().then((s) async {
      final parts = await Future.wait([
        for (final part in SpeechPauses.clauses(text))
          s.synthesize(part, voice, speed),
      ]);
      return joinWithSilence(
        parts,
        gap: pauses.clause * (1 / speed),
        trailing: pause * (1 / speed),
      );
    })..ignore();
  });

  /// Silence after [ref], whose spoken text is [text], at speed 1.0.
  Duration pauseAfter(SentenceRef ref, String text) {
    if (ref.isTitle) return pauses.chapterTitle;
    final block = book.chapters[ref.chapter].blocks[ref.block];
    final end = pauses.afterSentence(text);
    if (ref.sentence < block.sentences.length - 1) return end;
    if (block.type == BlockType.heading) return pauses.heading;
    return end > pauses.block ? end : pauses.block;
  }

  void _prefetchAfter(SentenceRef ref) {
    // Forget clips behind us.
    _clips.removeWhere((k, _) => k.compareTo(ref) < 0);
    var n = ref;
    for (var i = 0; i < prefetch; i++) {
      final next = nextOf(n);
      if (next == null) return;
      _clip(next);
      n = next;
    }
  }

  void _setState(ReadAloudState state) {
    _state = state;
    notifyListeners();
  }

  // ------------------------------------------------------------ navigation

  String textOf(SentenceRef ref) {
    if (ref.isTitle) {
      final title = titleAt(ref) ?? '';
      // A final full stop makes the voice end the title like a sentence.
      return title.isEmpty || RegExp(r'[.!?…:;]$').hasMatch(title)
          ? title
          : '$title.';
    }
    return book.chapters[ref.chapter].blocks[ref.block].sentenceText(
      ref.sentence,
    );
  }

  /// Name from the table of contents read before the sentence [ref] (or
  /// before the title ref [ref]), if any.
  String? titleAt(SentenceRef ref) =>
      _titles[SentenceRef(ref.chapter, ref.block, 0)];

  /// Table of contents names to read, by the first sentence they come
  /// before.
  late final Map<SentenceRef, String> _titles = _findTitles();

  /// A TOC entry's name is read where it points, unless the text there
  /// already starts with it (as a heading, or a short paragraph). This
  /// catches chapter headings drawn as images, or missing.
  Map<SentenceRef, String> _findTitles() {
    final titles = <SentenceRef, List<String>>{};
    for (final entry in book.toc) {
      if (entry.chapterIndex < 0 ||
          entry.chapterIndex >= book.chapters.length) {
        continue;
      }
      // An anchor that was dropped (e.g. a skipped boilerplate footer)
      // resolves to the top of the document: don't read its name there.
      final fragment = entry.fragment;
      if (fragment != null &&
          !book.chapters[entry.chapterIndex].anchors.containsKey(fragment)) {
        continue;
      }
      final at = _readableFrom(
        SentenceRef(entry.chapterIndex, entry.blockIndex, 0),
      );
      if (at == null || at.sentence != 0) continue;
      final title = entry.title.trim();
      if (_letters(title).length < 2 || _isWritten(title, at)) continue;
      final list = titles.putIfAbsent(at, () => []);
      if (!list.contains(title)) list.add(title);
    }
    return {
      for (final MapEntry(:key, :value) in titles.entries)
        key: value.map(_withFullStop).join(' '),
    };
  }

  static String _withFullStop(String s) =>
      RegExp(r'[.!?…:;]$').hasMatch(s) ? s : '$s.';

  /// Whether [title] is already in the text around [at]: the heading just
  /// before it, or the headings and first paragraph from it on.
  bool _isWritten(String title, SentenceRef at) {
    final name = _letters(title);
    bool matches(Block b) {
      final text = _letters(b.text);
      return text.length >= 3 &&
          (name.contains(text) ||
              (text.contains(name) &&
                  (b.type == BlockType.heading ||
                      text.length <= name.length * 2)));
    }

    final blocks = book.chapters[at.chapter].blocks;
    final before = _previousSentence(at);
    if (before != null &&
        before.chapter == at.chapter &&
        blocks[before.block].type == BlockType.heading &&
        matches(blocks[before.block])) {
      return true;
    }
    for (var b = at.block; b < blocks.length; b++) {
      if (!_readable(blocks[b])) continue;
      if (matches(blocks[b])) return true;
      if (blocks[b].type != BlockType.heading) return false;
    }
    return false;
  }

  /// Lowercase letters and digits only, to compare titles and headings.
  static String _letters(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  bool _readable(Block b) =>
      readTypes.contains(b.type) && b.sentences.isNotEmpty;

  /// [from] if it is a readable sentence (or a title that is read), else
  /// the next one. Starting at a block with a title starts at the title.
  SentenceRef? firstReadableFrom(SentenceRef from) {
    final ref = _readableFrom(from);
    if (ref == null || ref.isTitle || ref.sentence != 0) return ref;
    return titleAt(ref) != null
        ? SentenceRef.title(ref.chapter, ref.block)
        : ref;
  }

  /// [from] if it is a readable sentence, else the next one, ignoring
  /// titles.
  SentenceRef? _readableFrom(SentenceRef from) {
    final chapters = book.chapters;
    if (from.chapter >= chapters.length) return null;
    final blocks = chapters[from.chapter].blocks;
    if (from.isTitle && titleAt(from) != null) return from;
    if (from.block < blocks.length &&
        _readable(blocks[from.block]) &&
        from.sentence < blocks[from.block].sentences.length) {
      return SentenceRef(from.chapter, from.block, math.max(from.sentence, 0));
    }
    return _nextBlockStart(from.chapter, from.block);
  }

  SentenceRef? nextOf(SentenceRef ref) {
    if (ref.isTitle) return SentenceRef(ref.chapter, ref.block, 0);
    final block = book.chapters[ref.chapter].blocks[ref.block];
    if (ref.sentence + 1 < block.sentences.length) {
      return SentenceRef(ref.chapter, ref.block, ref.sentence + 1);
    }
    final next = _nextBlockStart(ref.chapter, ref.block);
    if (next != null && titleAt(next) != null) {
      return SentenceRef.title(next.chapter, next.block);
    }
    return next;
  }

  SentenceRef? previousOf(SentenceRef ref) {
    if (!ref.isTitle && ref.sentence == 0 && titleAt(ref) != null) {
      return SentenceRef.title(ref.chapter, ref.block);
    }
    return _previousSentence(ref);
  }

  /// The readable sentence before [ref], ignoring chapter names.
  SentenceRef? _previousSentence(SentenceRef ref) {
    if (ref.sentence > 0) {
      return SentenceRef(ref.chapter, ref.block, ref.sentence - 1);
    }
    var c = ref.chapter;
    var b = ref.block - 1;
    while (c >= 0) {
      final blocks = book.chapters[c].blocks;
      for (; b >= 0; b--) {
        if (_readable(blocks[b])) {
          return SentenceRef(c, b, blocks[b].sentences.length - 1);
        }
      }
      c--;
      if (c >= 0) b = book.chapters[c].blocks.length - 1;
    }
    return null;
  }

  /// First sentence of the first readable block after ([chapter], [block]).
  SentenceRef? _nextBlockStart(int chapter, int block) {
    var c = chapter;
    var b = block + 1;
    while (c < book.chapters.length) {
      final blocks = book.chapters[c].blocks;
      for (; b < blocks.length; b++) {
        if (_readable(blocks[b])) return SentenceRef(c, b, 0);
      }
      c++;
      b = 0;
    }
    return null;
  }

  /// Text as it should be spoken: no footnote markers, no line breaks, no
  /// non-breaking spaces. Empty if nothing is pronounceable.
  static String speakableText(String text) {
    final cleaned = text
        .replaceAll(RegExp(r'\[\d+\]|\[[a-z]\]'), ' ')
        .replaceAll('_', ' ')
        .replaceAll(RegExp(r'[\s   ]+'), ' ')
        .trim();
    return RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(cleaned)
        ? cleaned
        : '';
  }

  @override
  void dispose() {
    stop();
    output.dispose();
    super.dispose();
  }
}
