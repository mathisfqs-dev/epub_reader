import 'dart:typed_data';

import 'audio_clip.dart';

/// Silences added to the synthesized speech, on top of the short pauses
/// Kokoro makes by itself at punctuation.
///
/// Durations are for speed 1.0; they shrink as the voice speeds up.
class SpeechPauses {
  const SpeechPauses({
    this.clause = const Duration(milliseconds: 250),
    this.sentence = const Duration(milliseconds: 350),
    this.ellipsis = const Duration(milliseconds: 500),
    this.block = const Duration(milliseconds: 650),
    this.heading = const Duration(milliseconds: 900),
    this.chapterTitle = const Duration(milliseconds: 1000),
  });

  /// Inside a sentence, after `;`.
  final Duration clause;

  /// After `.`, `!` or `?` inside a paragraph.
  final Duration sentence;

  /// After `…` or `...`.
  final Duration ellipsis;

  /// After the last sentence of a paragraph, list item, quote or verse.
  final Duration block;

  /// After a heading.
  final Duration heading;

  /// After the chapter name read from the table of contents.
  final Duration chapterTitle;

  /// Closing quotes and brackets that may follow the final punctuation.
  static final _closers = RegExp(r'''["'”’»)\]›\s]+$''');

  /// Pause after a sentence ending with [text].
  Duration afterSentence(String text) {
    final end = text.replaceFirst(_closers, '');
    if (end.endsWith('…') || end.endsWith('...')) return ellipsis;
    return sentence;
  }

  /// Splits a sentence after each `;`, so a longer pause can be put there.
  /// Each part keeps its `;` (Kokoro's intonation depends on it); parts
  /// without anything pronounceable are merged into the previous one.
  static List<String> clauses(String text) {
    final parts = <String>[];
    var start = 0;
    void add(int end) {
      final part = text.substring(start, end).trim();
      start = end;
      if (part.isEmpty) return;
      if (parts.isNotEmpty &&
          !(_pronounceable.hasMatch(part) &&
              _pronounceable.hasMatch(parts.last))) {
        parts.last = '${parts.last} $part';
      } else {
        parts.add(part);
      }
    }

    for (var i = 0; i < text.length; i++) {
      if (text[i] == ';') add(i + 1);
    }
    add(text.length);
    return parts;
  }

  static final _pronounceable = RegExp(r'[\p{L}\p{N}]', unicode: true);
}

/// Joins [parts] with [gap] of silence between them and [trailing] silence
/// at the end. Empty parts are dropped; the result is empty if all are.
/// The silence the model left around each part is trimmed first, so the
/// gaps are exactly [gap] and [trailing].
AudioClip joinWithSilence(
  List<AudioClip> parts, {
  required Duration gap,
  required Duration trailing,
}) {
  final audible = [
    for (final p in parts)
      if (!p.isEmpty) p.trimSilence(),
  ];
  if (audible.isEmpty) return AudioClip(Float32List(0), 24000);
  final rate = audible.first.sampleRate;
  int samples(Duration d) => d.inMicroseconds * rate ~/ 1000000;
  final gapLength = samples(gap);
  final length =
      audible.fold(0, (n, p) => n + p.samples.length) +
      gapLength * (audible.length - 1) +
      samples(trailing);
  final out = Float32List(length); // zeros: silence
  var offset = 0;
  for (final (i, p) in audible.indexed) {
    if (i > 0) offset += gapLength;
    out.setAll(offset, p.samples);
    offset += p.samples.length;
  }
  return AudioClip(out, rate);
}
