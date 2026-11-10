# Text-to-speech models: what the numbers mean, Qwen3-TTS, German

*Written 2026-11-08, for the epub_reader read-aloud feature (M6).*

## 1. What "82M parameters" means

A **parameter** is one number (a *weight*) inside the neural network, learned during training. It is not a node. A node (neuron) has many weights, one per input connection. Kokoro has 82 million of these numbers.

Three things follow from the parameter count.

### a) Size on disk and in memory

The file size is the parameter count times the bytes used per number:

| Precision | Bytes per weight | Kokoro (82M) | Qwen3-TTS 1.7B (~2B in total) |
|---|---|---|---|
| float32 | 4 | ~330 MB (our `model.onnx`) | ~8 GB |
| bf16 / fp16 | 2 | ~165 MB | ~4 GB |
| int8 | 1 | ~85 MB | ~2 GB |
| 4-bit | 0.5 | — | ~1 GB |

### b) Speed: the parameter count *times the number of passes*

Every pass through the network costs roughly **2 operations per parameter**, and it has to **read all the weights from memory**. The big difference is how many passes a model needs.

- **Kokoro is non-autoregressive.** It takes the phonemes of a whole sentence and makes the whole waveform in **one pass**. It's based on StyleTTS2, with an iSTFTNet decoder that turns the network's output into sound. That's why it runs about 4× faster than real time on the M1 Pro, **on the CPU**.
- **LLM-style TTS models are autoregressive.** Qwen3-TTS, Chatterbox and Orpheus produce audio *tokens* one after another, like a chatbot produces words. Every token is a pass through the whole network.
  - Qwen3-TTS makes 12.5 tokens per second of audio.
  - So a 10 s sentence takes about 125 passes through 1.7B weights. Each pass reads ~3.4 GB in bf16.
  - The M1 Pro's memory bandwidth (~200 GB/s) caps that at about 60 passes/s in theory.
  - Real implementations get much less, about real time, and they need the **GPU** (MLX, Apple's ML library) to get there.

So: **more parameters × more passes = slower**. Kokoro does one pass with few weights. Qwen3-TTS does many passes with 20× more weights.

### c) What the extra parameters buy

A bigger network has more *capacity*:
- more languages in one model
- more natural intonation, emotion and laughter
- voice cloning from a 3-second sample
- voices described in plain text ("a calm old man")
- reading raw text directly, so no eSpeak phonemizer is needed (and none of its mispronunciations)

But size isn't quality by itself; training data and architecture matter as much. When it came out, Kokoro beat several models 5–10× its size in blind listening tests.

## 2. Could we use Qwen3-TTS-12Hz-1.7B-CustomVoice?

Model: [Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice)

**What it is**
- A language model that writes speech tokens (12.5 per second, 16 codebooks), followed by a light decoder that turns the tokens into sound.
- About 1.7B parameters (~2B with the codec). Apache 2.0 licence.
- Languages: Chinese, English, Japanese, Korean, **German, French**, Russian, Portuguese, **Spanish**, Italian.
- *CustomVoice* has **9 preset speakers**: Vivian, Serena, Uncle_Fu, Dylan, Eric, Ryan, Aiden, Ono_Anna and Sohee. Their native languages are Chinese, English, Japanese and Korean, but each can speak every supported language.
- You can give style instructions in plain text, e.g. "speak slowly, sad tone".
- Related models:
  - `0.6B-CustomVoice`: smaller and faster.
  - `1.7B-Base`: clones a voice from a 3 s sample.
  - `VoiceDesign`: describe the voice you want in text.

**Measured accuracy.** Word error rate (lower is better), measured by transcribing the generated audio back to text. These are the README's CustomVoice figures for the 1.7B model:

| | German | French | Spanish |
|---|---|---|---|
| WER | 1.06 % | 3.78 % | 1.33 % |

**How it fits our app**

| What we need | Qwen3-TTS | Kokoro today |
|---|---|---|
| German | ✅ | ❌ (needs a fine-tune, see §3) |
| French / Spanish / English | ✅ (preset voices aren't native French speakers, so there may be an accent: listen first) | ✅ |
| Runs from Dart / Flutter | ❌ No ONNX build and no sherpa-onnx support. Official code is Python + PyTorch, examples use NVIDIA CUDA. Apple Silicon only through community **MLX** ports (`mlx-audio`, a Swift MLX port). | ✅ `sherpa_onnx`, in our own process |
| Speed on the M1 Pro | ⚠️ Reported ~0.7–0.8 RTF (seconds of work per second of audio; chip not stated, not verified by us). Only just faster than real time. Our 2-sentence prefetch would barely keep up, and changing voice or speed would mean a noticeable wait. | ✅ ~4× faster than real time, on the CPU |
| Memory | ⚠️ 4–6 GB reported (under 2 GB quantized), on top of Gemma 3 4B for translation (~3 GB). It fits in 16 GB, but both fight over the GPU while translating. | ✅ ~0.3 GB |
| Speed control (0.8–1.5×) | ⚠️ Through text instructions ("speak faster"), not an exact number | ✅ exact |
| Reliability | ⚠️ Autoregressive models sometimes skip or repeat words. Reading sentence by sentence limits the damage. | ✅ reads exactly the phonemes |
| Sentence highlighting | ✅ We sync per sentence, which works with any engine | ✅ |
| Licence | ✅ Apache 2.0 | ✅ Apache 2.0 |

**Verdict: possible, but not now, and not as the default.** If waiting ~30 s before a chapter is OK, speed matters much less: see §4.
- To use it, we'd run a helper process next to the app, as we do with Ollama: Python + `mlx-audio`, or the Swift MLX port.
- The app would send each sentence to it over HTTP. That's a new `Synthesizer` implementation; the reader and the controller don't change.
- It would be a good **optional "high quality / German" engine** for a Mac with headroom. The **0.6B** version is the better fit for speed.
- It isn't worth the extra setup just to get German, because §3 is much lighter.

## 3. German (and Spanish)

**Spanish** is already in the app: `ef_dora`, `em_alex` and `em_santa`.

**German:** Kokoro v1.0 has no German voice, but there are community fine-tunes.

**[Thomcle/kokoro_german](https://github.com/Thomcle/kokoro_german)** is the fork you saw. What it contains:
- **Only inference code**: a copy of `hexgrad/kokoro` with German (`lang_code='d'`) added. Two commits, January 2026.
- **Phonemes:** misaki's `EspeakG2P(language='de')`, i.e. **eSpeak `de`**. That's the same phonemizer path our app already uses.
- **Weights:** downloaded from `Tundragoon/Kokoro-German` on Hugging Face. **That repo is gone**: it returns 401 (Unauthorized) and is reported deleted.
- **Surviving copies:**
  - [r1di/kokoro-fastapi-german](https://github.com/r1di/kokoro-fastapi-german) runs "Kokoro-German v1.1" with **`df_eva` (female)** and **`dm_bernd` (male)**. The page doesn't say whether the weights themselves are stored there.
  - [cstr/kokoro-voices-GGUF](https://huggingface.co/cstr/kokoro-voices-GGUF) re-hosts the German voices. It rates **`df_victoria`** above `df_eva`.
- **Licence:** Apache 2.0 is claimed. Because the original repo was deleted, where the copies came from is less clear.

| Option | What it is | How it would fit | Cost |
|---|---|---|---|
| **Kokoro-German (Tundragoon / Thomcle)** | Kokoro-82M fine-tuned for German. Voices `df_eva`, `dm_bernd` (+ `df_victoria`) | Same architecture, so it runs through **our sherpa-onnx engine** once exported to ONNX (sherpa-onnx has Kokoro export scripts). eSpeak `de` phonemes, already shipped. Check that its phoneme vocabulary matches the original Kokoro's. | 1–2 days. A second ~330 MB model, loaded for German. Risks: getting the weights from a mirror, and the ONNX export. |
| [dida-80b HUI German base](https://huggingface.co/cstr/kokoro-de-hui-base-GGUF) | Kokoro re-trained on 51 German speakers, ~51 h of audio | Same path, with more voices | Only a "stage-1 base" model, so quality is unknown. Only a GGUF conversion was found, which sherpa-onnx can't load. |
| Qwen3-TTS (§2) | Big autoregressive model | Helper process, chapter generated ahead of time (§4) | Best quality candidate; heaviest |
| ~~Thorsten-Voice/Kokoro~~, Piper German voices | Thorsten voice | — | Ruled out: you don't like the Thorsten voice. The other Piper voices sound more robotic than Kokoro. |

**Plan for German:**
1. Try Qwen3-TTS outside the app first (§4, step 1). If it's fast enough, it covers German, French and Spanish with one model.
2. In parallel, or if Qwen is too slow, listen to `df_eva`, `dm_bernd` and `df_victoria`.
3. If one sounds good, export Kokoro-German to ONNX and add a `KokoroModel` per language.

## 4. If waiting ~30 s before a chapter is OK

Taking a 30 s head start changes the speed question. A model no longer needs to be "4× real time"; it only needs to **keep up**.

- **The rule:** say the model needs `RTF` seconds of work per second of audio. To read a chapter of `T` seconds of audio without stalling, the head start must be at least `T × (RTF − 1)`.
  - **RTF ≤ 1** (faster than real time): any small head start is enough. 30 s is plenty, even for a long chapter.
  - **RTF 1.1, 20-minute chapter:** needs 2 minutes of head start, so 30 s is not enough.
  - So 30 s works **if the model is at least as fast as real time on this Mac**. Reported figures for Qwen3-TTS on MLX (~0.7–0.8) are just under that line.
- **What changes in the app:**
  - Generate the chapter in the background, sentence by sentence, as far ahead as possible instead of 2 sentences.
  - Cache it on disk: 16-bit WAV at 24 kHz is ~2.9 MB per minute, so ~60 MB for a 20-minute chapter (Opus would be ~10× smaller).
  - Changing the voice or speed means a new wait. For speed, time-stretching the cached audio would avoid that.
- **Effect on §2's verdict:** the "speed" row stops being a blocker *if measured RTF ≤ 1*. What's left:
  - a helper process (Python + `mlx-audio`, or the Swift MLX port)
  - checking the accent of the preset voices in French and German
  - sharing the GPU with Gemma when translating
- **Next steps:**
  1. Measure Qwen3-TTS **0.6B and 1.7B** with `mlx-audio` on the M1 Pro: time one paragraph in French and one in German, and listen. That's about an hour of setup and needs no app code.
  2. If RTF ≤ 1 and it sounds better than Kokoro, add a `Synthesizer` that talks to the helper over HTTP, plus the chapter-ahead cache.

## Sources

- [Qwen3-TTS-12Hz-1.7B-CustomVoice model card](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice)
- [QwenLM/Qwen3-TTS on GitHub](https://github.com/QwenLM/Qwen3-TTS): WER tables, tokenizer details
- [mlx-audio](https://github.com/Blaizzy/mlx-audio), [qwen3-tts-mlx](https://github.com/suckerfish/qwen3-tts-mlx), [Swift Qwen3-TTS on MLX](https://atomgradient.github.io/swift-qwen3-tts): Apple Silicon ports and reported RTF
- [Running Qwen TTS locally, three machines compared](https://tinycomputers.io/posts/the-real-cost-of-running-qwen-tts-locally-three-machines-compared.html)
- [Thomcle/kokoro_german](https://github.com/Thomcle/kokoro_german), [r1di/kokoro-fastapi-german](https://github.com/r1di/kokoro-fastapi-german), [cstr/kokoro-voices-GGUF](https://huggingface.co/cstr/kokoro-voices-GGUF)
- [Thorsten-Voice/Kokoro](https://huggingface.co/Thorsten-Voice/Kokoro), [cstr/kokoro-de-hui-base-GGUF](https://huggingface.co/cstr/kokoro-de-hui-base-GGUF)
- [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/README.md)
