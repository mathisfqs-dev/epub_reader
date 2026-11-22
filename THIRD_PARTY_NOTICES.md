# Third-Party Notices

This repository contains source code licensed under the [MIT License](LICENSE). At runtime, the application can download and run open-weights models, voice packs, dictionary extracts, and inference binaries governed by the following licenses:

---

## 1. Kyutai Pocket TTS & Voices

- **Upstream Model & Weights:** [`kyutai/pocket-tts`](https://huggingface.co/kyutai/pocket-tts) by **Kyutai** (Manu Orsini, Simon Rouard, Gabriel De Marmiesse, Václav Volhejn, Neil Zeghidour, Alexandre Défossez).
- **Upstream Code Repository:** [`kyutai-labs/pocket-tts`](https://github.com/kyutai-labs/pocket-tts) (MIT License).
- **Weights License:** [Creative Commons Attribution 4.0 International (CC-BY-4.0)](https://creativecommons.org/licenses/by/4.0/).
- **ONNX Derivative Distribution:** [`Duf-1/pocket-tts-sherpa-onnx`](https://huggingface.co/Duf-1/pocket-tts-sherpa-onnx)
  - *Modifications from upstream:* Exported PyTorch checkpoints (`english_2026-10`, `french`, `german`, `spanish`) to ONNX (opset 17) with fixed sliding-window KV caches and zero-initialized states; dynamically quantized `flow_lm_main` and `flow_lm_flow` (`MatMul`/`Gemm`) to INT8; prepended the learned `bos_before_voice` tensor to `encoder.onnx` via `Concat` for `sherpa-onnx` compatibility; converted the SentencePiece tokenizer to `vocab.json` and `token_scores.json`.
- **Reference Voice Prompts (`voices/*.wav`):** Sourced from [`kyutai/tts-voices`](https://huggingface.co/kyutai/tts-voices) and [`kyutai/pocket-tts`](https://huggingface.co/kyutai/pocket-tts):
  - `estelle` (`unmute-prod-website/developpeuse-3.wav`) — **CC0 1.0** (Kyutai recording)
  - `fabien` (`unmute-prod-website/fabieng-enhanced-v2.wav`) — **CC0 1.0** (Kyutai recording)
  - `alba` (`alba-mackenna/casual.wav`) — **CC-BY-4.0** (Voice-acted by Alba MacKenna)
  - `lola` (`common_voice_es_19762977-enhanced-v2.mp3`) — **CC0 1.0** (Mozilla Common Voice)
  - `juergen` (`de-DE-juergen.mp3`) — **CC-BY-4.0** (Kyutai Pocket TTS)
- **Kyutai Prohibited Use Notice:**
  > Use of the model must comply with all applicable laws and regulations and must not result in, involve, or facilitate any illegal, harmful, deceptive, fraudulent, or unauthorized activity. Prohibited uses include, without limitation, voice impersonation or cloning without explicit and lawful consent; misinformation, disinformation, or deception (including fake news, fraudulent calls, or presenting generated content as genuine recordings of real people or events); and the generation of unlawful, harmful, libelous, abusive, harassing, discriminatory, hateful, or privacy-invasive content.

---

## 2. Kokoro TTS, sherpa-onnx & piper-phonemize

- **sherpa-onnx:** [`k2-fsa/sherpa-onnx`](https://github.com/k2-fsa/sherpa-onnx) — [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).
- **Kokoro-82M (`kokoro-multi-lang-v1_0`):** [`hexgrad/Kokoro-82M`](https://huggingface.co/hexgrad/Kokoro-82M) — [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).
- **piper-phonemize & eSpeak-NG:** GPLv3 / Apache-2.0 (see upstream [`rhasspy/piper-phonemize`](https://github.com/rhasspy/piper-phonemize)).

---

## 3. llama.cpp & Gemma 3

- **llama.cpp (`llama-server`):** [`ggml-org/llama.cpp`](https://github.com/ggml-org/llama.cpp) — [MIT License](https://github.com/ggml-org/llama.cpp/blob/master/LICENSE).
- **Gemma 3 4B (`ggml-org/gemma-3-4b-it-GGUF`):** Downloaded on demand by the user from Hugging Face; subject to the [Gemma Terms of Use](https://ai.google.dev/gemma/terms).

---

## 4. Offline Dictionaries (Wiktionary / Kaikki.org)

- **Wiktionary Extracts:** Downloaded on demand from [`kaikki.org`](https://kaikki.org/) (extracted from English and French Wiktionary dumps using [`wiktextract`](https://github.com/tatuylonen/wiktextract)).
- **License:** [CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/) and GFDL.

---

## 5. Test Fixture EPUB Books

The 5 test books in `test/fixtures/books/` (*Pride and Prejudice*, *Leaves of Grass*, *Alice's Adventures in Wonderland*, and *Candide*) are public-domain ebooks from [Project Gutenberg](https://www.gutenberg.org/).
