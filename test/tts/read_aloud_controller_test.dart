import 'dart:async';

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epub_reader/epub/epub.dart';
import 'package:epub_reader/tts/audio_clip.dart';
import 'package:epub_reader/tts/kokoro_voices.dart';
import 'package:epub_reader/tts/read_aloud_controller.dart';
import 'package:epub_reader/tts/speech_pauses.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late Book alice;
  late Book pride;

  setUpAll(() async {
    alice = await const EpubParser().parseFile(
      'test/fixtures/books/alice_wonderland_images_epub3.epub',
    );
    pride = await const EpubParser().parseFile(
      'test/fixtures/books/pride_and_prejudice_epub3.epub',
    );
  });

  final heart = voiceNamed('af_heart')!;
  final emma = voiceNamed('bf_emma')!;

  (ReadAloudController, FakeSynthesizer, FakeOutput) make(Book book) {
    final synth = FakeSynthesizer();
    final output = FakeOutput();
    final c = ReadAloudController(
      book: book,
      synthesizer: () async => synth,
      output: output,
      voice: heart,
    );
    addTearDown(c.dispose);
    return (c, synth, output);
  }

  /// First chapter index whose blocks include a readable paragraph with
  /// at least [sentences] sentences.
  (int, int) paragraphWith(Book book, int sentences) {
    for (final (c, chapter) in book.chapters.indexed) {
      for (final (b, block) in chapter.blocks.indexed) {
        if (block.type == BlockType.paragraph &&
            block.sentences.length >= sentences) {
          return (c, b);
        }
      }
    }
    throw StateError('none');
  }

  group('speakableText', () {
    test('removes footnote markers, line breaks and NBSPs', () {
      expect(
        ReadAloudController.speakableText('Hello[12]\nworld, dear _sir_.'),
        'Hello world, dear sir .',
      );
    });

    test('is empty without letters or digits', () {
      expect(ReadAloudController.speakableText('* * *'), '');
      expect(ReadAloudController.speakableText('  —  '), '');
    });

    test('keeps accents', () {
      expect(ReadAloudController.speakableText('Où est-il ?'), 'Où est-il ?');
    });
  });

  group('navigation', () {
    test('skips images, captions and separators', () {
      final (c, _, _) = make(alice);
      for (final (ci, chapter) in alice.chapters.indexed) {
        for (final (bi, block) in chapter.blocks.indexed) {
          if (block.type == BlockType.image ||
              block.type == BlockType.caption) {
            final next = c.firstReadableFrom(SentenceRef(ci, bi, 0))!;
            final type = alice.chapters[next.chapter].blocks[next.block].type;
            expect(ReadAloudController.readTypes, contains(type));
          }
        }
      }
    });

    test('walks through every sentence, across chapters, both ways', () {
      final (c, _, _) = make(pride);
      var ref = c.firstReadableFrom(const SentenceRef(0, 0, 0))!;
      final seen = [ref];
      while (true) {
        final n = c.nextOf(ref);
        if (n == null) break;
        expect(n.compareTo(ref), greaterThan(0));
        seen.add(ref = n);
      }
      final readable = [
        for (final ch in pride.chapters)
          for (final b in ch.blocks)
            if (ReadAloudController.readTypes.contains(b.type)) ...b.sentences,
      ];
      expect(seen, hasLength(readable.length));
      expect(seen.map((r) => r.chapter).toSet().length, greaterThan(1));
      // previousOf is the inverse of nextOf.
      for (var i = seen.length - 1; i > seen.length - 400; i--) {
        expect(c.previousOf(seen[i]), seen[i - 1]);
      }
      expect(c.previousOf(seen.first), isNull);
    });
  });

  group('playback', () {
    test('reads sentence after sentence and prefetches two ahead', () async {
      final (c, synth, output) = make(pride);
      final (ch, b) = paragraphWith(pride, 4);
      final block = pride.chapters[ch].blocks[b];
      c.startAt(SentenceRef(ch, b, 0));
      expect(c.state, ReadAloudState.loading);
      await pumpEventQueue();
      expect(c.state, ReadAloudState.playing);
      expect(c.current, SentenceRef(ch, b, 0));
      // Sentences are synthesized in parts, split at semicolons.
      List<String> parts(int sentences) => [
        for (var i = 0; i < sentences; i++)
          ...SpeechPauses.clauses(
            ReadAloudController.speakableText(block.sentenceText(i)),
          ),
      ];
      expect(synth.requests.map((r) => r.$1), parts(3));

      output.finish();
      await pumpEventQueue();
      expect(c.current, SentenceRef(ch, b, 1));
      expect(output.played, hasLength(2));
      // One more sentence prefetched, none synthesized twice.
      expect(synth.requests.map((r) => r.$1), parts(4));
    });

    test('pause, resume, next, previous, stop', () async {
      final (c, _, output) = make(pride);
      final (ch, b) = paragraphWith(pride, 4);
      c.startAt(SentenceRef(ch, b, 0));
      await pumpEventQueue();

      c.togglePause();
      expect(c.state, ReadAloudState.paused);
      c.togglePause();
      expect(c.state, ReadAloudState.playing);
      expect(output.calls, ['play', 'pause', 'resume']);

      c.next();
      await pumpEventQueue();
      expect(c.current, SentenceRef(ch, b, 1));
      expect(c.state, ReadAloudState.playing);

      c.previous();
      await pumpEventQueue();
      expect(c.current, SentenceRef(ch, b, 0));
      expect(output.played, hasLength(3));

      c.stop();
      expect(c.state, ReadAloudState.stopped);
      expect(c.current, isNull);
      expect(c.isActive, isFalse);
      await pumpEventQueue();
      expect(output.played, hasLength(3));
    });

    test('pausing while loading waits before playing', () async {
      final (c, _, output) = make(pride);
      final (ch, b) = paragraphWith(pride, 2);
      c.startAt(SentenceRef(ch, b, 0));
      c.pause();
      await pumpEventQueue();
      expect(c.state, ReadAloudState.paused);
      expect(output.played, isEmpty);
      c.resume();
      await pumpEventQueue();
      expect(c.state, ReadAloudState.playing);
      expect(output.played, hasLength(1));
    });

    test('a new voice restarts the sentence with that voice', () async {
      final (c, synth, output) = make(pride);
      final (ch, b) = paragraphWith(pride, 2);
      c.startAt(SentenceRef(ch, b, 0));
      await pumpEventQueue();
      c.voice = emma;
      c.speed = 1.2;
      await pumpEventQueue();
      expect(c.current, SentenceRef(ch, b, 0));
      expect(synth.requests.last.$2, emma);
      expect(synth.requests.last.$3, 1.2);
      expect(output.played.length, greaterThanOrEqualTo(2));
    });

    test('stops with an error when synthesis fails', () async {
      final (c, synth, _) = make(pride);
      synth.failWith = StateError('boom');
      final (ch, b) = paragraphWith(pride, 1);
      c.startAt(SentenceRef(ch, b, 0));
      await pumpEventQueue();
      expect(c.state, ReadAloudState.stopped);
      expect(c.error, contains('boom'));
    });

    test('stops with an error when playback fails', () async {
      final (c, _, output) = make(pride);
      output.failWith = TimeoutException('not prepared');
      final (ch, b) = paragraphWith(pride, 1);
      c.startAt(SentenceRef(ch, b, 0));
      await pumpEventQueue();
      expect(c.state, ReadAloudState.stopped);
      expect(c.error, contains('Playback failed'));
    });

    test('skipping quickly keeps reading the last sentence', () async {
      final (c, _, output) = make(pride);
      final (ch, b) = paragraphWith(pride, 4);
      c.startAt(SentenceRef(ch, b, 0));
      await pumpEventQueue();
      c
        ..next()
        ..next()
        ..next();
      await pumpEventQueue();
      expect(c.current, SentenceRef(ch, b, 3));
      expect(c.state, ReadAloudState.playing);
      expect(c.error, isNull);
    });

    test('stops after the last sentence', () async {
      final (c, _, output) = make(pride);
      var last = c.firstReadableFrom(const SentenceRef(0, 0, 0))!;
      while (c.nextOf(last) != null) {
        last = c.nextOf(last)!;
      }
      c.startAt(last);
      await pumpEventQueue();
      output.finish();
      await pumpEventQueue();
      expect(c.state, ReadAloudState.stopped);
    });
  });

  group('pauses', () {
    const pauses = SpeechPauses();

    test('sentences are split after semicolons', () {
      expect(SpeechPauses.clauses('Il pleut ; il vente; bref.'), [
        'Il pleut ;',
        'il vente;',
        'bref.',
      ]);
      expect(SpeechPauses.clauses('No semicolon.'), ['No semicolon.']);
      // Parts without words stay with their neighbour.
      expect(SpeechPauses.clauses('Done; ;'), ['Done; ;']);
      expect(SpeechPauses.clauses('; then'), ['; then']);
    });

    test('pause depends on the final punctuation', () {
      expect(pauses.afterSentence('Yes.'), pauses.sentence);
      expect(pauses.afterSentence('Really?”'), pauses.sentence);
      expect(pauses.afterSentence('Well…'), pauses.ellipsis);
      expect(pauses.afterSentence('Well...) '), pauses.ellipsis);
    });

    test('joinWithSilence puts silence between parts and at the end', () {
      final a = AudioClip(Float32List.fromList(List.filled(10, 0.5)), 1000);
      final b = AudioClip(Float32List.fromList(List.filled(5, -0.5)), 1000);
      final empty = AudioClip(Float32List(0), 1000);
      final clip = joinWithSilence(
        [a, empty, b],
        gap: const Duration(milliseconds: 2),
        trailing: const Duration(milliseconds: 3),
      );
      expect(clip.sampleRate, 1000);
      expect(clip.samples, [
        ...List.filled(10, 0.5),
        0,
        0,
        ...List.filled(5, -0.5),
        0,
        0,
        0,
      ]);
      expect(
        joinWithSilence(
          [empty],
          gap: Duration.zero,
          trailing: const Duration(seconds: 1),
        ).isEmpty,
        isTrue,
      );
    });

    test('clips end with a sentence, block or heading pause', () async {
      final (c, _, output) = make(pride);
      final (ch, b) = paragraphWith(pride, 2);
      final block = pride.chapters[ch].blocks[b];
      int samples(Duration d) => d.inMicroseconds * 24000 ~/ 1000000;
      int expected(int sentence, Duration pause) {
        final text = ReadAloudController.speakableText(
          block.sentenceText(sentence),
        );
        final parts = SpeechPauses.clauses(text);
        return parts.fold(0, (n, p) => n + p.length) +
            (parts.length - 1) * samples(pauses.clause) +
            samples(pause);
      }

      c.startAt(SentenceRef(ch, b, block.sentences.length - 2));
      await pumpEventQueue();
      final first = c.textOf(c.current!);
      expect(
        output.played.last.samples.length,
        expected(block.sentences.length - 2, pauses.afterSentence(first)),
      );
      output.finish();
      await pumpEventQueue();
      final last = ReadAloudController.speakableText(
        block.sentenceText(block.sentences.length - 1),
      );
      final blockPause = pauses.afterSentence(last) > pauses.block
          ? pauses.afterSentence(last)
          : pauses.block;
      expect(
        output.played.last.samples.length,
        expected(block.sentences.length - 1, blockPause),
      );

      final heading = alice.chapters[1].blocks.indexWhere(
        (b) => b.type == BlockType.heading,
      );
      final (a, _, _) = make(alice);
      expect(
        a.pauseAfter(SentenceRef(1, heading, 0), 'CHAPTER I.'),
        pauses.heading,
      );
    });

    test('pauses shrink when the voice is faster', () async {
      final (c, _, output) = make(pride);
      final (ch, b) = paragraphWith(pride, 2);
      c.speed = 2.0;
      c.startAt(SentenceRef(ch, b, 0));
      await pumpEventQueue();
      final text = ReadAloudController.speakableText(c.textOf(c.current!));
      final parts = SpeechPauses.clauses(text);
      final silence =
          output.played.last.samples.length -
          parts.fold(0, (n, p) => n + p.length);
      final atNormalSpeed =
          (parts.length - 1) *
              (pauses.clause.inMicroseconds * 24000 ~/ 1000000) +
          pauses.afterSentence(text).inMicroseconds * 24000 ~/ 1000000;
      expect(silence, closeTo(atNormalSpeed / 2, parts.length + 1));
    });
  });

  group('chapter names', () {
    /// Alice, with an extra TOC entry pointing at the first paragraph of
    /// chapter 1, whose name is not written there.
    Book withEntry(String title, {int block = 1, String? fragment}) {
      final entry =
          TocEntry(
              title: title,
              depth: 0,
              path: alice.chapters[1].path,
              fragment: fragment,
            )
            ..chapterIndex = 1
            ..blockIndex = block;
      return Book(
        metadata: alice.metadata,
        toc: [...alice.toc, entry],
        chapters: alice.chapters,
        archive: Archive(),
      );
    }

    test('a name that is part of the heading before is not read', () {
      final (c, _, _) = make(withEntry('The Rabbit-Hole'));
      expect(c.titleAt(const SentenceRef(1, 1, 0)), isNull);
    });

    test('names already written as headings are not read again', () {
      final (c, _, _) = make(alice);
      var ref = c.firstReadableFrom(const SentenceRef(0, 0, 0));
      while (ref != null) {
        expect(ref.isTitle, isFalse, reason: '$ref');
        ref = c.nextOf(ref);
      }
    });

    test('a name missing from the text is read before it', () async {
      final book = withEntry('A Long Fall');
      final (c, synth, output) = make(book);
      final title = const SentenceRef.title(1, 1);
      final lastOfHeading = SentenceRef(
        1,
        0,
        book.chapters[1].blocks[0].sentences.length - 1,
      );
      expect(c.titleAt(const SentenceRef(1, 1, 0)), 'A Long Fall.');
      expect(c.textOf(title), 'A Long Fall.');
      expect(c.nextOf(lastOfHeading), title);
      expect(c.nextOf(title), const SentenceRef(1, 1, 0));
      expect(c.previousOf(const SentenceRef(1, 1, 0)), title);
      expect(c.previousOf(title), lastOfHeading);
      expect(title.compareTo(const SentenceRef(1, 1, 0)), lessThan(0));
      expect(title.compareTo(lastOfHeading), greaterThan(0));

      // Starting at the block starts at its name, then reads on.
      c.startAt(const SentenceRef(1, 1, 0));
      await pumpEventQueue();
      expect(c.current, title);
      expect(synth.requests.first.$1, 'A Long Fall.');
      expect(
        output.played.last.samples.length,
        'A Long Fall.'.length +
            const SpeechPauses().chapterTitle.inMicroseconds * 24000 ~/ 1000000,
      );
      output.finish();
      await pumpEventQueue();
      expect(c.current, const SentenceRef(1, 1, 0));
    });

    test('entries whose anchor is missing are ignored', () {
      final book = withEntry('Footer', fragment: 'no-such-anchor');
      final (c, _, _) = make(book);
      expect(c.titleAt(const SentenceRef(1, 1, 0)), isNull);
    });
  });

  test('AudioClip.toWav writes a valid 16-bit header', () {
    final clip = AudioClip(Float32List.fromList([0, 1, -1, 0.5]), 24000);
    final wav = clip.toWav();
    final data = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(data.getUint32(24, Endian.little), 24000);
    expect(data.getUint32(40, Endian.little), 8);
    expect(data.getInt16(46, Endian.little), 32767);
    expect(data.getInt16(48, Endian.little), -32767);
    expect(clip.duration, const Duration(microseconds: 166));
  });

  test('voices', () {
    expect(languageOf('en-US'), 'en');
    expect(languageOf('fr'), 'fr');
    expect(languageOf('de'), 'en');
    expect(defaultVoiceFor('fr').name, 'ff_siwis');
    expect(defaultVoiceFor('en').name, 'af_heart');
    expect(voicesFor('fr').first.name, 'ff_siwis');
    expect(
      kokoroVoices.map((v) => v.id).toSet(),
      hasLength(kokoroVoices.length),
    );
  });
}
