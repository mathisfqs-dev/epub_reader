# pocket_tts_export — Kyutai Pocket TTS → ONNX → sherpa-onnx

Standalone Python tooling, not part of the Flutter app. It produces Pocket TTS model
directories that the app's `sherpa_onnx` 2.0.1 (`OfflineTtsPocketModelConfig`) loads, for
the multilingual checkpoints (French, German, Spanish, …), not just the English one
sherpa publishes.

## The pipeline

```
upstream checkpoint ──export_onnx.py──▶ bundle ──pack_sherpa.py──▶ sherpa dir ──validate.py / asr_check.py──▶ ✓
(kyutai/pocket-tts)                    (KevinAHM layout)          (what the app loads)
                       KevinAHM/pocket-tts-onnx bundles ──┘   (already exported: skip step 1)
```

| script | what it does |
|---|---|
| `export_onnx.py` | PyTorch → ONNX for any upstream config (`french`, `german`, `dutch`, `english_2026-10`, …). Checks every graph against the untouched PyTorch code, both patched and through onnxruntime, over several streaming calls and at lengths it wasn't traced with. Writes int8 `lm_main` / `lm_flow` (MatMul only; Mimi stays fp32 like Kyutai's runtime). |
| `pack_sherpa.py` | bundle → sherpa layout: **bakes the BOS-before-voice into the encoder graph** (sherpa 2.0.1 doesn't know about it), converts the tokenizer to `vocab.json` + `token_scores.json`, prepares the voice WAVs (24 kHz, `end_on_pause`, < 10 s), writes `pocket.json` (file map, text rules, generation defaults). |
| `validate.py` | sherpa-onnx (same native code as the Dart package) vs a numpy reference run of the original bundle. Gates on exact checks (token ids, zero-init ≡ manifest fills); the temperature-0 waveform comparison is informational. Writes listening WAVs. |
| `asr_check.py` | Whisper large-v3-turbo (mlx, uses the `../tests_tts` venv) → word error rate; `--max-wer 0.2` makes it a gate. The real intelligibility check. |
| `check_predefined_voice.py` | Smoke test without the gated weights: starts our ONNX graphs from a Kyutai precomputed voice state. |
| `text_prep.py` | Upstream's `prepare_text_prompt` (sherpa doesn't do it; the app must port this). |
| `publish_hf.py` | Packages `out/pocket-<lang>-int8` into `.tar.bz2` archives with CC-BY-4.0 attribution (`LICENSE` + `README.md` model card) and uploads them to Hugging Face (`Duf-1/pocket-tts-sherpa-onnx`) for one-click in-app download. |

## Setup

```sh
cd pocket_tts_export
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python sherpa-onnx onnx onnxruntime onnxscript numpy sentencepiece \
    tokenizers huggingface_hub soundfile scipy safetensors pyyaml pocket-tts
```

**Voice cloning needs the gated weights.** Accept the terms at
<https://huggingface.co/kyutai/pocket-tts> (approved automatically), then `hf auth login`.
Without that, `pocket_tts` falls back to `kyutai/pocket-tts-without-voice-cloning`, whose
Mimi encoder and `speaker_proj` are **zeroed**. The export still works (`--allow-no-voice-cloning`)
but cloning from audio gives silence or an immediate EOS. sherpa only supports cloning
from audio.

## Recipes

```sh
V=downloads/voices/unmute-prod-website      # kyutai/tts-voices: developpeuse-3.wav = "estelle"

# French, 6 layers: our own export (needs the HF login)
.venv/bin/python export_onnx.py --language french --out downloads/ours/french
curl -sL https://raw.githubusercontent.com/kyutai-labs/pocket-tts/main/pocket_tts/config/french.yaml \
    -o downloads/upstream_config/french.yaml
.venv/bin/python pack_sherpa.py downloads/ours/french out/pocket-french-int8 \
    --upstream-config downloads/upstream_config/french.yaml --voice estelle=$V/developpeuse-3.wav
.venv/bin/python validate.py downloads/ours/french out/pocket-french-int8 \
    --voice out/pocket-french-int8/voices/estelle.wav --listen-temperature 0.3 \
    --text "Aujourd'hui, maman est morte. Ou peut-être hier, je ne sais pas."
../tests_tts/.venv/bin/python asr_check.py --lang fr --max-wer 0.2 --dir out/validate/pocket-french-int8

# Same for english / spanish / german (voices: alba, lola, juergen; see results below).
# Repacking a KevinAHM bundle instead (no login needed):
.venv/bin/python pack_sherpa.py downloads/kevin/onnx/german out/pocket-german-kevin-int8 \
    --upstream-config downloads/upstream_config/german.yaml --voice estelle=$V/developpeuse-3.wav
```

(`downloads/kevin` = `snapshot_download("KevinAHM/pocket-tts-onnx", allow_patterns=["onnx/german/*", …])`.)

## Results so far (M1 Pro, sherpa-onnx 2.0.1, 2 threads)

Voices: `juergen` for german, `estelle` for french_24l, `estelle` + `fabien` for french, `alba` for english, `lola` for spanish. Text: first lines of *L'Étranger* / *Die Verwandlung*.

| model | source | size | exact checks | Whisper WER (sherpa output) | sherpa RTF |
|---|---|---|---|---|---|
| **german (6 L, int8)** | **ours** (gated) | 184 MB | ✅ | 0 % / 10 % / 0 % at t=0.3, voice juergen (*Die Verwandlung*; the 10 % is "Samser" + the "ungeheuren" spelling) | 0.28–0.30 (long), 0.55 (short) |
| french_24l (24 L, int8) | KevinAHM, repacked | 396 MB | ✅ | 8 % / 19 % at t=0.7 | 0.65–0.85 |
| **french (6 L, int8)** | **ours** (`export_onnx.py`, gated weights) | 185 MB | ✅ tokens, zero-init, BOS encoder; graphs ≡ PyTorch (~1e-6 through ORT) | 0 % / 9.5 % / 27 % at t=0.3, voices estelle and fabien alike. The 27 % is mostly Whisper writing digits ("80 km", "2 heures") and silent plurals; the one real slip is "Maringo" | 0.31–0.33 (long sentences), ~0.5 (short) |
| **english (6 L, int8)** = upstream default 2026-10 | **ours** (gated) | 184 MB | ✅ | 0 % / 0 % at t=0.3, voice alba (*Alice*) | 0.36 |
| **spanish (6 L, int8)** | **ours** (gated) | 184 MB | ✅ | 0 % / 0 % at t=0.3, voice lola (*Don Quijote*) | 0.31–0.35 |

## Things that weren't obvious

- **sherpa-onnx 2.0.1 already runs Pocket TTS**, but its published model is the English
  2026-01 one. Multilingual checkpoints (2026-04+) add a learned **BOS before the voice
  embedding**. sherpa feeds the encoder output straight to `lm_main`, so a `Concat` in the
  encoder graph fixes it with no C++ change.
- **sherpa zero-fills all states.** For these graphs that's equivalent to the NaN/true
  fills of the manifest (checked bit for bit). The Mimi `first` flags only matter with
  `replicate` padding, and the configs use `constant`.
- **Waveforms never match sample by sample** between two correct int8 runs: the Mimi
  decoder turns tiny latent differences into phase shifts. Worse, at temperature 0 the
  model is chaotic: a tiny numeric difference (onnxruntime 1.28 in sherpa vs 1.31 in Python)
  can push it into a silent attractor ("Guten Tag." + 6 s of silence in sherpa, the full
  sentence in the reference). french_24l is always silent at t=0. So gate on ASR at a
  real temperature: upstream's default is **0.3** (sherpa's is 0.7). It's in `pocket.json`.
- **Tokenizers:** KevinAHM's `tokenizer.model` and the no-voice-cloning repo's
  `tokenizer.json` have the same pieces in a different id order. Each matches its own
  checkpoint, and mixing them gives gibberish. `export_onnx.py` checks that the `.model` it
  ships gives the same ids as the checkpoint's own tokenizer.
- sherpa post-processing to be aware of in the app: `silence_scale` defaults to **0.2**
  (shortens pauses), it splits/merges sentences itself (`min/max_char_in_sentence`), it
  doesn't skip EOS during the first 6 frames like upstream, and it caps the reference at 10 s.
- KV caches in our export are fixed **sliding windows** (FlowLM 1000 positions = voice +
  text + frames of one sentence; Mimi 250 = its context), so decoding length is unbounded
  and nothing uses `.item()` or scatter.

## Licences

Pocket TTS code: MIT. Weights: CC-BY-4.0 (gated repo: accept Kyutai's terms). KevinAHM's
ONNX exports: CC-BY-4.0. Voices in `kyutai/tts-voices`: per-voice licences, see that repo.
