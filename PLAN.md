# EPUB Reader — Prototype 1 plan

Flutter 3.47 / Dart 3.13, **macOS only** for now (Apple Silicon, M1 Pro 16 GB).

## Goal

A desktop reader for Project Gutenberg EPUBs that:

1. keeps a library of linked local `.epub` files,
2. renders a book in a scrollable, themed reader (light / dark / sepia),
3. translates a selected sentence or paragraph from the right-click menu, using a **local LLM (Gemma 3 4B) run by llama-server**,
4. reads the book aloud with **Kokoro** voices, highlighting the current sentence.

### Out of scope for prototype 1

- Coloring by part of speech (see the [annex](#annex--part-of-speech-tagging-later))
- Pagination (scrolling only), word-by-word highlighting during read-aloud
- Running llama.cpp in-process through FFI (we start `llama-server` as a child process instead)
- iOS, web, Windows, Linux
- Sandbox-safe file links (security-scoped bookmarks)

---

## Architecture

```
lib/
  main.dart
  app/            app shell, routing (library ↔ reader), app-wide state
  library/        add a book, list of books, persistence (JSON in Application Support)
  epub/           EPUB parser → book model (no Flutter imports, unit-testable)
  reader/         reader screen, block widgets, selection & right-click menu, TOC drawer
  theme/          reader themes (ThemeExtension), font / size / line-height settings
  translate/      Translator interface, llama-server process + OpenAI-compatible client, translation panel
  tts/            Kokoro engine (background isolate), playback queue, controls bar
```

State: `ChangeNotifier` / `ValueNotifier` with `ListenableBuilder`. No state-management package for now.

### Book model (the core decision)

We **don't** use a WebView. Each chapter's XHTML is converted into our own model, so every sentence can be found and styled. Read-aloud highlighting, translation context and (later) part-of-speech coloring all depend on this.

```
Book
 ├─ metadata: title, author, language, cover image
 ├─ toc: [TocEntry(title, chapterIndex, anchor?)]
 └─ chapters (spine order): [Chapter]
      └─ blocks: [Block]  — heading(level) | paragraph | quote | poetry line | image | separator
           ├─ inlines: [Inline(text, bold?, italic?, smallCaps?, link?)]
           └─ sentences: [SentenceSpan(start, end)]   ← character offsets inside the block's plain text
```

Sentence IDs (`chapter / block / sentence`) are the shared reference used by read-aloud, highlighting, "read from here" and the saved reading position.

---

## Packages

| Need | Package | Notes |
|---|---|---|
| Unzip EPUB | `archive` | Pure Dart |
| Parse OPF / NCX / XHTML | `xml` | Use the HTML5 entity mapping (`&nbsp;`, `&mdash;`…) |
| Pick a file | `file_selector` | Official package, works on macOS |
| App folders | `path_provider` | Application Support for the library JSON + model files |
| Settings | `shared_preferences` | Theme, font size, target language, voice |
| HTTP to llama-server | `dart:io` `HttpClient` | Streams responses (server-sent events); no package needed |
| Text-to-speech | `sherpa_onnx` | Official Flutter package, supports Kokoro |
| Audio playback | `audioplayers` (start) | Simplest option: a WAV file per sentence. Move to `flutter_soloud` if the gaps between sentences are audible |

**macOS entitlements:** for the prototype, **turn the app sandbox off** in both `DebugProfile.entitlements` and `Release.entitlements`. Then storing absolute paths just works, and so do local HTTP calls to Ollama. If the sandbox comes back later, it needs `network.client` plus security-scoped bookmarks.

---

## Milestones

### M0 — Setup (½ day)
- Add the packages above and turn the sandbox off.
- Replace the counter app with an empty shell: library screen → reader screen.
- ✅ Test books downloaded to `test/fixtures/books/`:

  | File | Purpose | Notes |
  |---|---|---|
  | `pride_and_prejudice_epub3.epub` | Novel + **images** | EPUB 3, 164 illustrations, 24 MB |
  | `pride_and_prejudice_epub2.epub` | Same novel, **EPUB2-style** version | Only the cover image; compare its output with the EPUB3 parse |
  | `leaves_of_grass_epub3.epub` | **Poetry** | EPUB 3 |
  | `alice_wonderland_images_epub3.epub` | Short novel | EPUB 3, cover image only |
  | `candide_fr_epub3.epub` | **French** | EPUB 3, `dc:language = fr` |

  All of them include both a `toc.ncx` and an EPUB3 nav document. The nav is **`toc.xhtml`, found through the manifest item with `properties="nav"`**. Don't hardcode `nav.xhtml`.

### M1 — EPUB parser (1–2 days) — *moderate, not hard*
An EPUB is a zip, and Gutenberg files are clean and predictable. The steps:
1. Unzip, read `META-INF/container.xml` → path to the `.opf` file.
2. Parse the OPF: `metadata` (title, creator, language, cover), `manifest` (id → href, media-type), `spine` (reading order).
3. Table of contents: the EPUB3 nav document (the manifest item with `properties="nav"`, `<nav epub:type="toc">`), falling back to EPUB2 `toc.ncx` (the spine's `toc` attribute).
4. Resolve relative hrefs against the OPF folder. Decode URL-encoded names.
5. XHTML → blocks: walk the DOM.
   - `p`, `h1–h6`, `blockquote`, `div.poem`/`div.stanza`/`.line`, `img`, `hr` → block types.
   - `em/i`, `strong/b`, `span.smcap`, `a` → inline styles.
   - Collapse whitespace; `br` becomes a line break. Ignore CSS except a few known Gutenberg classes.
6. Optional: strip the Gutenberg licence header and footer (`*** START OF …` / `*** END OF …`). They're in their own sections in recent files.
7. Split sentences with rules: `.?!…` plus closing quotes or brackets, with an abbreviation list (`Mr. Mrs. Dr. St. vs. i.e. e.g.` + French `M. Mme`). Good enough for read-aloud.
- **Tests:** unit tests against the sample books (spine count, TOC titles, first paragraph text, sentence counts on tricky lines).
- *Why not use `epubx`?* It's only a couple of hundred lines to write ourselves. That gives full control over the block model, and we'd need to convert `epubx`'s output anyway.

### M2 — Library (½ day)
- An "Add book" button → file picker (`.epub`) → parse metadata and cover → save `{id, path, title, author, coverPath, lastPosition}` to `library.json`.
- Grid of covers. Tap one to open it; right-click → remove from the library (the file itself is never deleted).
- If a linked file is missing, show a "file not found — relink?" state.

### M3 — Reader (1–2 days)
- One chapter at a time, shown with `ListView.builder` over blocks so long chapters stay smooth. Previous and next chapter buttons sit at the end of each chapter.
- A TOC drawer (button in the app bar).
- On-screen controls in the top bar: TOC, previous/next chapter, theme, font size −/+. Keyboard shortcuts are optional extras.
- Save the reading position (chapter + block index) on scroll, debounced, and restore it when the book is reopened.
- Images from the zip shown with `Image.memory`, capped to the column width.
- A centered text column with a max width (~70 characters).

### M4 — Themes (½ day)
- A `ReaderTheme` `ThemeExtension` with: background, text, secondary text, link, selection, highlight color for the sentence being read.
- Presets: **Light**, **Dark**, **Sepia**. Settings: font family (serif / sans), size, line height.
- Leave room for later token-level colors (verb/noun…): `Inline` → token spans when part-of-speech data exists.

### M5 — Translation (1 day) — *easy*
> ✅ Done with **llama-server** instead of Ollama; see Checkpoint 5. The original Ollama plan is kept below for reference.

- **Setup (outside the app):** `brew install ollama`, `ollama serve` (or the Ollama.app), `ollama pull gemma3:4b`. Alternatives: `qwen3:4b` (turn "thinking" off with `"think": false`), `gemma3:12b` for better quality (~8 GB RAM).
- The `Translator` interface takes text, the surrounding paragraph, and the source and target languages, and streams the translated text back. The first implementation is `OllamaTranslator`, which calls `POST http://localhost:11434/api/chat` with `stream: true`. The reply is JSON, one object per line.
  - Later: switch to the OpenAI-compatible `/v1/chat/completions` so a bundled `llama-server` can replace Ollama without code changes.
- Prompt: system = "You are a literary translator. Translate the passage into {target}. Keep tone and register. Output only the translation." User = context paragraph (marked as context only) + the passage.
- UI:
  - `SelectionArea` with `onSelectionChanged` → keep the current selected text.
  - `contextMenuBuilder` → add **"Translate"** (and **"Read from here"**, M6) to the default Copy / Select all.
  - Results appear in a right side panel, streaming in, with the original text, a copy button and a target-language dropdown (default: French ↔ English).
- Check Ollama on startup (`GET /api/tags`). If it isn't running, show a clear "Ollama not running / model not pulled" message in the panel.
- Context paragraph: find the selected text inside the current chapter's blocks. If there's no match, send no context.

### M6 — Read-aloud with Kokoro (2–3 days) — *the trickiest milestone*
> ✅ Done; see Checkpoint 3 for what was actually built. Differences from this plan: the engine returns samples rather than WAV paths, and "Read from here" uses the click position instead of a text match. There is no hover ▶ on paragraphs; right-click covers it.

- **Model:** a Kokoro model from the sherpa-onnx releases (`kokoro-multi-lang-v1_x` or `kokoro-en-v0_19`, int8 build if one is available). Download it on first use to `Application Support/models/kokoro/`, with a progress bar. Don't put it inside the app.
- **Voices:** a dropdown of Kokoro voices (start with `af_heart`, `af_bella`, `bf_emma`, `am_michael`, `bm_george`) and a speed slider (0.8–1.3×).
- **Engine:**
  - A long-lived background **isolate** owns the `OfflineTts` instance, because generating audio is a synchronous native call and would freeze the UI.
  - Messages: `generate(sentenceId, text, voice, speed)` → `{sentenceId, wavPath}`.
- **Pipeline:**
  - Queue the sentences from the current one onward and always keep **1–2 sentences generated ahead** of playback.
  - When a sentence finishes playing, play the next WAV and update `currentSentence`. Delete old WAVs.
- **UI:**
  - A bottom player bar: ⏮ previous sentence, ⏯ play/pause, ⏭ next sentence, voice, speed.
  - The current sentence is highlighted, and the view scrolls to keep it visible.
- **Starting points:**
  - The player bar's play button starts at the first sentence visible on screen.
  - The right-click menu's **"Read from here"** starts at the sentence containing the selection (found by text match, as in M5).
  - A small ▶ on each paragraph when hovered (fallback).
- Moving to the next chapter keeps reading.

---

## Checkpoints

We stop after each one, you review, and we decide what's next.

1. **Checkpoint 1: M0 + M1.** Project setup + EPUB parser.
   - Proof: unit tests pass on all 5 test books.
   - Plus a small debug command that prints a book's structure (metadata, TOC, chapters, first blocks, sentence count), so you can check the parse by eye.
   - No reader UI yet.
   - ✅ **Done (2026-11-08).** 70 tests pass (`flutter test`), `dart analyze` is clean, and `flutter build macos` works.
     - Code: `lib/epub/` (`model.dart`, `epub_parser.dart`, `xhtml_converter.dart`, `sentence_splitter.dart`).
     - Inspect any book: `dart run tool/dump_book.dart <file.epub> [--chapter N] [--blocks N] [--sentences]`.
     - Things to know:
       - A `Chapter` is one XHTML file of the EPUB, not a logical chapter. Pride and Prejudice has 16 files for its 61 chapters; Leaves of Grass has one file per poem. The reader should navigate through the TOC (entry → chapter + block).
       - Some TOC titles in the Gutenberg Pride and Prejudice include the illustration caption ("I hope Mr. Bingley will like it. CHAPTER II."). That's in the source file. Same for the `CHAPTERXXVII.` heading typo.
       - Licence header and footer, page numbers and the cover page are dropped. Drop-cap images become text ("WHEN").
2. **Checkpoint 2: M2 → M4.** Library + reader + themes.
   - Proof: add the 5 books, open them, navigate the TOC, reading position restored, switch Light / Dark / Sepia.
   - This is the first usable app, with no AI features yet.
   - ✅ **Done (2026-11-08).** 89 tests pass and `dart analyze` is clean.
     - Code: `lib/library/` (store + screen), `lib/reader/` (reader, blocks, TOC drawer, appearance panel), `lib/theme/reader_theme.dart`, `lib/app/` (settings, `AppScope`).
     - Visual check without a window: `flutter test tool/screenshots_test.dart --dart-define=OUT=<dir>` renders 6 PNG screenshots with real fonts.
     - Drive the running app from tooling: `flutter run -d macos -t test_driver/app.dart` (adds the Flutter Driver extension).
     - Library saved in `~/Library/Application Support/com.example.epubReader/` (`library.json` + `covers/`).
     - Reading position = file + first visible block, saved while scrolling. The app bar shows the current TOC entry.
     - Selection + copy already work (`SelectionArea`). M5 adds "Translate" to the right-click menu.
3. **Then we decide on M5 / M6.**
   - M5 needs Ollama installed and running, plus `gemma3:4b` downloaded (~3 GB).
   - M6 needs the Kokoro model downloaded (~300 MB).
   - We can do either one first. → We did **M6 first**.
4. **Checkpoint 3: M6 — read-aloud.**
   - ✅ **Done (2026-11-08).** 109 tests pass, `dart analyze` is clean, `flutter build macos` works, and a smoke run inside the real app synthesizes speech.
     - Code: `lib/tts/` (`kokoro_model.dart`, `tts_engine.dart`, `read_aloud_controller.dart`, `audio_output.dart`, `kokoro_voices.dart`, `audio_clip.dart`) and `lib/reader/read_aloud_bar.dart`.
     - **How to use it:**
       - The 🎧 button in the reader's app bar starts reading at the top of the page.
       - On first use, a dialog offers to download the model (350 MB, `kokoro-multi-lang-v1_0`) into `~/Library/Application Support/com.example.epubReader/models/`. It is already installed on this Mac.
       - Right-click a sentence → **"Read aloud from here"**. This uses the exact click position, not a text match.
       - Bottom bar: previous sentence / play-pause / next sentence, voice menu (the book's language first; ♀/♂ icons), speed menu (0.8–1.5×), and ✕ to stop.
       - The current sentence is highlighted and kept on screen. Reading continues into the next chapter.
       - The voice is remembered per language (English default `af_heart`, French default `ff_siwis`), and the speed is remembered too.
     - **How it works:**
       - sherpa-onnx 2.x no longer phonemizes text for Kokoro. Text goes through `piper_phonemize` (eSpeak-NG) to phonemes, then Kokoro synthesizes from those phonemes.
       - Synthesis runs in a long-lived background isolate and is about 4× faster than real time on the M1 Pro. The model loads in about 1.3 s.
       - The next 2 sentences are synthesized ahead of time.
       - Headings, paragraphs, quotes and verse are read. Captions, footnotes and images are skipped. `[1]` markers are removed.
     - **Answers to the risks below:**
       - French works (risk 1). eSpeak voice names are `en-us`, `en-gb-x-rp`, `fr`, `es`, `it` and `pt-br`. `fr-fr` and `en-GB` return nothing.
       - There is about a 0.3 s gap between sentences, one WAV per sentence through audioplayers (risk 2). It sounds like a natural pause. `flutter_soloud` remains the option for gapless playback.
     - **Build note:** the project uses **CocoaPods, not Swift Package Manager** (`flutter: config: enable-swift-package-manager: false` in pubspec). The sherpa-onnx and piper XCFrameworks both export a `module.modulemap`, which Xcode refuses under Swift Package Manager.
     - Smoke test in the real app: `flutter run -d macos -t test_driver/tts_smoke.dart`.
     - The real-model test (`test/tts/tts_engine_test.dart`) is skipped when the model isn't installed.
     - **To judge by ear:** voice quality, especially French (`ff_siwis`) and the British voices.
5. **M6.1 — pauses and chapter names.** ✅ **Done (2026-11-08).** 118 tests pass.
   - Code: `lib/tts/speech_pauses.dart`, plus changes in `read_aloud_controller.dart`, `reader_screen.dart` and `read_aloud_bar.dart`.
   - Every clip now ends with added silence (on top of Kokoro's own ~65 ms and the ~0.3 s player gap):
     - 350 ms after `.` `!` `?`
     - 600 ms after `…`
     - 650 ms at the end of a paragraph or list item
     - 900 ms after a heading
     - 1 s after a chapter name
   - Sentences are split after `;`, each part is synthesized on its own, and the parts are joined with 250 ms of silence.
   - Pauses shrink with speed (÷ speed). The values are in `SpeechPauses`, which a settings slider could change later.
   - **Chapter names:** a TOC entry's name is read before the first sentence it points to, unless the text there already has it (the heading just before, the headings from there on, or a short first paragraph). This catches headings drawn as images, or missing altogether. Entries whose anchor was dropped (the Gutenberg license footer) are ignored. In the five test books every name is already a heading, so nothing extra is read there.
   - While the name is spoken, the bar shows "Chapter: …" and no sentence is highlighted.
   - Model comparison (parameters, Qwen3-TTS, German): see `docs/tts-models.md`.
6. **Checkpoint 5: M5 — translation.** ✅ **Done (2026-11-09).** 166 tests pass, `dart analyze` is clean.
   - Code: `lib/translate/` (`translator.dart`, `llama_server.dart`, `translation_model.dart`, `translation_controller.dart`, `translation_panel.dart`, `languages.dart`).
   - **How to use it:**
     - Select text → **Translate** in the bubble above the selection. Or right-click → **Translate** (the selection) / **Translate sentence** (the sentence under the pointer, no selection needed).
     - The translation streams into a panel on the right: original text, translation, target language menu (Français, English, Español, Deutsch, Italiano, Português), Copy, Translate again, ✕.
     - Default target: English for French books, French for every other language. The choice is remembered per book language (`translate.target.<lang>`).
     - If the model is missing, the panel offers to download it (2.5 GB, resumable).
   - **How it works:**
     - Model: `gemma-3-4b-it-Q4_K_M.gguf` from `ggml-org/gemma-3-4b-it-GGUF` (not gated), in `Application Support/…/models/llm/`.
     - The app starts `llama-server` on the first translation: `127.0.0.1`, a free port, a random `--api-key`, 8192-token context, 1 slot, no web UI. It waits for `/health` = 200, then talks to `/v1/chat/completions` with `stream: true`.
     - The server stops after 10 minutes without a translation, and when the app quits. A pid file (`models/llm/llama-server.pid`) lets the next start kill a server left behind by a crash. Its output goes to `models/llm/llama-server.log`.
     - Closing the panel or starting another translation closes the HTTP connection, which stops the generation.
     - Binary lookup order: `$LLAMA_SERVER`, `X.app/Contents/Resources/llama/llama-server`, `Application Support/…/bin/llama-server`, Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`). **For now it uses Homebrew's** (`brew install llama.cpp`, build 11429).
     - Context: the paragraph around the selection is sent (for passages ≤ 1500 characters), inside `<context>` tags, with the passage in `<passage>` tags, plus a final "Translate only this passage…" line. Without that last line Gemma translated the context too in 4 of 18 tries; with it, 0 of 18.
   - **Measured on the M1 Pro:** model load 1.3–10 s (65 s on the very first cold read of the file), ~42 tokens/s, a sentence in about 1 s, first words after ~0.3 s.
   - Real-model test: `test/translate/llama_server_test.dart` (tag `model`, skipped without llama-server or the model). In the real app: `flutter run -d macos -t test_driver/translate_smoke.dart`.
   - **To judge:** translation quality. Sentences are good; isolated words can be wrong ("peeped" → "gloussailla"). `gemma-3-12b-it` (Q4, ~7 GB) would be the next step up if needed.
   - **Next:** really bundle llama-server in the `.app` (official release build, a "Copy llama" build phase, signing), so Homebrew isn't needed.

## Rough total

About **7–10 days** of focused work for prototype 1. M1 + M3 is the biggest chunk. M6 has the most unknowns.

## Risks / open questions

1. **Kokoro French in sherpa-onnx.** Kokoro has one French voice (`ff_siwis`), but sherpa-onnx's Kokoro packages officially support English and Chinese. Check whether French works through its espeak-ng support. If it doesn't, use Piper (in the same `sherpa_onnx` package) for French books.
2. **Gaps between sentences** with one WAV file per sentence → move to `flutter_soloud`, which can stream buffers.
3. **Finding the selection's position:** `SelectionArea` gives the selected *text*, not where it is. A text match is fine for a prototype. Newer Flutter selection APIs (`SelectionListener`) could give exact offsets later.
4. **Odd Gutenberg markup** (tables, footnotes, very old EPUB2 files) → render unknown elements as plain paragraphs and log them.
5. **Memory:** Kokoro (~0.3 GB) + Gemma 3 4B in llama-server (~3 GB) fit easily in 16 GB.

## After prototype 1

- Bundle `llama-server` inside the app bundle (today it comes from Homebrew; the lookup already checks `Contents/Resources/llama/`).
- Word-by-word highlighting during read-aloud.
- Pagination mode.
- Sandbox + security-scoped bookmarks.
- Part-of-speech coloring (below).
- German read-aloud: first measure Qwen3-TTS (0.6B / 1.7B) with `mlx-audio` on the M1 Pro, with a chapter generated ~30 s ahead. Otherwise Kokoro-German (`df_eva`, `dm_bernd`) through the same engine. See `docs/tts-models.md` §3–4.

---

## Annex — part-of-speech tagging (later)

`NLTagger` (Apple's built-in language framework) is ideal on macOS and iOS: free, offline, fast, and handles English and French. Platform-agnostic, open alternatives:

| Option | How it would run | Size | Quality | Notes |
|---|---|---|---|---|
| **XLM-RoBERTa fine-tuned on Universal Dependencies POS** (e.g. `wietsedv/xlm-roberta-base-ft-udpos28-*`) | Export to ONNX → onnxruntime (Dart package or Rust `ort`) | ~300 MB (int8 ~100 MB) | Excellent, ~97–98%, many languages including FR | Best quality; heavy, but one model for every language |
| **Small BERT POS models** (e.g. English `bert-…-finetuned-pos`) | ONNX | ~100–400 MB | Very good | Usually one language per model |
| **Averaged perceptron tagger** trained on UD treebanks (the classic NLTK/TextBlob algorithm) | Rewrite in Dart (~300 lines) + a weights file | 2–10 MB per language | ~95–97% | Tiny, fast, no native dependency; needs training (once, offline, in Python) |
| **UDPipe 1** | C++ library via FFI | ~10–50 MB per language | Good | Many languages; models are **non-commercial** (CC BY-NC-SA) |
| **spaCy / Stanza** | Python only | — | Very good | Fine for preprocessing books offline with a script, not for running inside the app |

Plan: put a `PosTagger` interface behind an `NLTagger` version on Apple platforms (via a small native bridge) plus an ONNX or perceptron version everywhere else. Tag each chapter once, cache the result per book, and colors become a simple lookup in the renderer.
