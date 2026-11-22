# EPUB Reader

Context : I wanted to build an app where i could read EPUB taking them from Gutenberg project, or other sources for public domain books, and learn new languages or just be able to listen to it in languaages I know - French or English. You can lookup words with spanish and german dictionnary, and translate by selecting the text. 

Technically speaking :
An offline desktop EPUB reader (macOS, Windows, and Linux) built with Flutter, featuring sentence-synced read-aloud (**Kokoro** and **Kyutai Pocket TTS**), local context-aware literary translation (**Gemma 3 4B** via `llama-server`), and offline Wiktionary word lookups.

Everything runs **100% locally on your computer**—no cloud APIs, no accounts, and no telemetry.

---

## Features

- **Clean Scrollable Reader:** Custom XHTML-to-block parser (no WebView) with Light, Dark, and Sepia themes, configurable serif/sans fonts, font size, line height, table of contents drawer, and automatic reading-position persistence.
- **Read-Aloud (TTS) with Sentence Highlighting:**
  - **Kyutai Pocket TTS (INT8 ONNX):** Expressive voices in English (`alba`), French (`estelle`, `fabien`), German (`juergen`), and Spanish (`lola`), downloaded per language (~185 MB each) from [`Duf-1/pocket-tts-sherpa-onnx`](https://huggingface.co/Duf-1/pocket-tts-sherpa-onnx).
  - **Kokoro (`kokoro-multi-lang-v1_0`):** Multi-voice TTS across English, French, Spanish, Italian, Portuguese, and Hindi with playback speed control (0.8×–1.5×), downloaded on demand (~350 MB).
  - Smart pauses after punctuation, headings, semicolons, and chapter titles.
- **Local Literary Translation (Gemma 3 4B):**
  - Select any word, sentence, or passage (or right-click a sentence) to stream a context-aware translation in the side panel (passes the surrounding paragraph as context so idioms and pronouns resolve accurately).
  - Can also auto-translate each sentence during read-aloud (always or when paused).
  - Uses an existing `llama-server` (`brew install llama.cpp`, `/usr/bin/llama-server`, WinGet/Scoop, or `$LLAMA_SERVER`) if found on your machine, or automatically downloads the official prebuilt `llama-server` binary for your OS/CPU (macOS arm64/x64, Linux x64/arm64, Windows x64/arm64) alongside the `gemma-3-4b-it-Q4_K_M.gguf` model (~2.5 GB).
- **Offline Word Lookup (Wiktionary):**
  - Selecting a single German or Spanish word displays its base form (lemma), morphological analysis, and French/English definitions built locally from [Kaikki.org](https://kaikki.org/) Wiktionary extracts.

---

## Requirements

- **macOS**, **Windows 10/11**, or **Linux** (64-bit x64 or ARM64; 16 GB RAM recommended when running TTS + LLM translation together)
- **Flutter** 3.47+ / **Dart** 3.13+
- Platform desktop toolchain:
  - **macOS:** Xcode & CocoaPods (`brew install cocoapods`)
  - **Windows:** Visual Studio 2022 with "Desktop development with C++"
  - **Linux:** `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`, `liblzma-dev`

---

## Quickstart

```bash
git clone <your-repo-url>
cd epub_reader
flutter pub get

# Run on your current desktop OS (macos, windows, or linux):
flutter run -d macos
# or: flutter run -d windows
# or: flutter run -d linux
```

### Building a Release App

```bash
# macOS
flutter build macos --release

# Windows
flutter build windows --release

# Linux
flutter build linux --release
```

> **Note:** This project uses **CocoaPods** (`enable-swift-package-manager: false` in `pubspec.yaml`) because both `sherpa_onnx` and `piper_phonemize` ship an XCFramework exporting `Headers/module.modulemap`.

---

## Where Models & Data Are Stored

All models are downloaded **on first use inside the app** (with progress bars and resume/cancel support) and stored outside the repo in:

```text
~/Library/Application Support/com.example.epubReader/
├── library.json              # Linked EPUB books & saved reading positions
├── covers/                   # Extracted book cover thumbnails
├── bin/
│   └── llama-server          # Auto-downloaded if not already in /opt/homebrew/bin
└── models/
    ├── kokoro-multi-lang-v1_0/
    ├── pocket/
    │   ├── en/               # Pocket TTS English (from Duf-1/pocket-tts-sherpa-onnx)
    │   ├── fr/               # Pocket TTS French
    │   ├── de/               # Pocket TTS German
    │   └── es/               # Pocket TTS Spanish
    ├── llm/
    │   └── gemma-3-4b-it-Q4_K_M.gguf
    └── dictionaries/
        ├── de/               # Offline German Wiktionary index
        └── es/               # Offline Spanish Wiktionary index
```

### Exporting Custom Pocket TTS Checkpoints / Voices

The companion Python pipeline in [`tool/pocket_tts_export/`](tool/pocket_tts_export/README.md) converts upstream [`kyutai/pocket-tts`](https://huggingface.co/kyutai/pocket-tts) PyTorch checkpoints and custom reference voice WAVs into `sherpa-onnx` INT8 directories. You can load any custom pack straight into the app via **Voice: Pocket TTS → Install from a folder…**.

---

## Running Tests

```bash
# Unit & widget tests (EPUB parser, reader UI, TTS models, translation controller, dictionaries)
flutter test

# Real-model integration tests (requires models installed in Application Support)
flutter test --tags model
```

---

## License & Third-Party Notices

This project's source code is licensed under the [MIT License](LICENSE).

Third-party components and on-demand models are governed by their respective licenses (see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for full details):
- **Kyutai Pocket TTS weights:** [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/) by [Kyutai](https://huggingface.co/kyutai/pocket-tts) (subject to Kyutai's Prohibited Use terms regarding non-consensual voice cloning).
- **Kyutai TTS Voices:** `estelle`, `fabien`, `lola` (**CC0**); `alba`, `juergen` (**CC-BY-4.0**), from [`kyutai/tts-voices`](https://huggingface.co/kyutai/tts-voices).
- **Kokoro-82M & sherpa-onnx:** Apache-2.0.
- **llama.cpp (`llama-server`):** MIT License.
- **Gemma 3 4B (`ggml-org/gemma-3-4b-it-GGUF`):** Gemma Terms of Use.
- **Wiktionary extracts (`kaikki.org`):** CC-BY-SA-4.0 / GFDL.
