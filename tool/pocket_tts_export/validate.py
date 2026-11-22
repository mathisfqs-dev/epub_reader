#!/usr/bin/env python3
"""Check that sherpa-onnx runs a packed Pocket TTS model like the reference does.

For each sentence, at temperature 0 (no sampling noise, so runs are deterministic):

1. ``reference``: the original bundle, run with numpy + onnxruntime exactly as the
   bundle's manifest says (NaN-filled KV caches, ``first`` flags true, BOS prepended
   to the voice embedding by hand).
2. ``zero_init``: the same, but every state starts at zero/false, as sherpa-onnx does.
   This must match (1) exactly.
3. ``baseline``: (1) again with onnxruntime's graph optimisations off. The int8 graphs
   are numerically sensitive, and the Mimi decoder turns tiny latent differences into
   phase shifts, so waveforms never match sample by sample. This run measures how far
   two *correct* runs drift apart.
4. ``sherpa``: sherpa-onnx (same native code as the Dart package) on the packed dir.

Pass/fail (exact, structural): sherpa's token ids equal SentencePiece's on the bundle's
tokenizer.model, and zero-init equals the manifest fills bit for bit. (pack_sherpa.py
already checked the BOS-patched encoder bit for bit.)

Informational: sherpa's length and log-mel distance to the reference, next to the
baseline's. At temperature 0 the model is deterministic but chaotic: a tiny numeric
difference can push it into a silent attractor (seen: german "Guten Tag." + 6 s of
silence in sherpa, a full sentence in the reference; french_24l is silent at t=0 always).
So this comparison flags drift but can't gate.

Then sherpa runs again at ``--listen-temperature`` (default 0.7; upstream's default is
0.3). Those WAVs are for listening and for ``asr_check.py --max-wer``, the real gate.

Usage:
    .venv/bin/python validate.py downloads/kevin/onnx/german out/pocket-german-int8 \
        --voice out/pocket-german-int8/voices/estelle.wav --text "Guten Tag, wie geht es Ihnen heute?"
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import numpy as np
import onnxruntime as ort
import sentencepiece as spm
import soundfile as sf

from text_prep import prepare_text_prompt

SR = 24000
FRAME = 1920
LATENT_DIM = 32
COND_DIM = 1024


def prepare(text: str, pocket: dict) -> tuple[str, int]:
    """Prepared text + upstream's frames_after_eos rule."""
    prepared, guess = prepare_text_prompt(text, pocket["text"])
    rec = pocket.get("model_recommended_frames_after_eos")
    return prepared, rec if rec is not None else guess + 2


# ---------------------------------------------------------------- reference


class Reference:
    def __init__(self, bundle: Path, precision: str, optimize: bool = True):
        self.meta = json.loads((bundle / "bundle.json").read_text())
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = 2
        if not optimize:
            opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL

        def sess(stem: str, allow_int8: bool = True) -> ort.InferenceSession:
            f = bundle / f"{stem}_int8.onnx"
            if not (precision == "int8" and allow_int8 and f.exists()):
                f = bundle / f"{stem}.onnx"
            return ort.InferenceSession(str(f), sess_options=opts)

        self.encoder = sess("mimi_encoder", allow_int8=False)
        self.text_cond = sess("text_conditioner", allow_int8=False)
        self.main = sess("flow_lm_main")
        self.flow = sess("flow_lm_flow")
        self.decoder = sess("mimi_decoder")
        self.bos = None
        if self.meta.get("insert_bos_before_voice"):
            self.bos = np.load(bundle / self.meta["bos_before_voice_file"]).astype(np.float32)
        self.sp = spm.SentencePieceProcessor(model_file=str(bundle / self.meta["tokenizer_file"]))

    @staticmethod
    def _fill(entry: dict, zero_init: bool) -> np.ndarray:
        dtype = {"float32": np.float32, "int64": np.int64, "bool": np.bool_}[entry["dtype"]]
        fill = "zeros" if zero_init else entry["fill"]
        if fill == "nan":
            return np.full(entry["shape"], np.nan, dtype=dtype)
        if fill == "ones":
            return np.ones(entry["shape"], dtype=dtype)
        return np.zeros(entry["shape"], dtype=dtype)

    def _state(self, manifest: str, zero_init: bool) -> dict:
        return {e["input_name"]: self._fill(e, zero_init) for e in self.meta[manifest]}

    def _run_main(self, state: dict, seq: np.ndarray, emb: np.ndarray):
        out = self.main.run(None, {"sequence": seq, "text_embeddings": emb, **state})
        for e in self.meta["flow_lm_state_manifest"]:
            state[e["input_name"]] = out[2 + e["index"]]
        return out[0], out[1]

    def voice_state(self, voice: np.ndarray, zero_init: bool = False) -> dict:
        """FlowLM state after the voice prompt (encoder output, BOS first when the model wants it)."""
        emb = self.encoder.run(None, {"audio": voice.reshape(1, 1, -1)})[0]
        if self.bos is not None:
            emb = np.concatenate([self.bos.reshape(1, 1, -1), emb], axis=1)
        state = self._state("flow_lm_state_manifest", zero_init)
        self._run_main(state, np.zeros((1, 0, LATENT_DIM), np.float32), emb)
        return state

    def generate(self, text: str, voice: np.ndarray | None, frames_after_eos: int, num_steps: int,
                 zero_init: bool = False, temperature: float = 0.0, seed: int = 0,
                 max_frames: int = 500, state: dict | None = None) -> np.ndarray:
        """``voice`` is a 24 kHz reference clip; or pass ``state`` from voice_state() (or a
        precomputed voice) to skip the voice prompt."""
        rng = np.random.default_rng(seed)
        state = dict(state) if state is not None else self.voice_state(voice, zero_init)
        ids = np.array(self.sp.Encode(text), dtype=np.int64).reshape(1, -1)
        text_emb = self.text_cond.run(None, {"token_ids": ids})[0]

        empty_seq = np.zeros((1, 0, LATENT_DIM), np.float32)
        empty_text = np.zeros((1, 0, COND_DIM), np.float32)
        self._run_main(state, empty_seq, text_emb)

        cur = np.full((1, 1, LATENT_DIM), np.nan, np.float32)
        latents, eos_step, dt = [], None, 1.0 / num_steps
        for step in range(max_frames):
            cond, eos = self._run_main(state, cur, empty_text)
            if eos_step is None and eos[0][0] > -4.0:
                eos_step = step
            if eos_step is not None and step >= eos_step + frames_after_eos:
                break
            if temperature > 0:
                x = rng.normal(0.0, np.sqrt(temperature), (1, LATENT_DIM)).astype(np.float32)
            else:
                x = np.zeros((1, LATENT_DIM), np.float32)
            for j in range(num_steps):
                s = np.array([[j / num_steps]], np.float32)
                t = s + np.float32(dt)
                x = x + self.flow.run(None, {"c": cond, "s": s, "t": t, "x": x})[0] * dt
            cur = x.reshape(1, 1, LATENT_DIM)
            latents.append(cur)
        latents = np.concatenate(latents, axis=1)

        dstate = self._state("mimi_state_manifest", zero_init)
        audio = []
        for i in range(0, latents.shape[1], 15):  # sherpa's default chunk_size
            out = self.decoder.run(None, {"latent": latents[:, i:i + 15], **dstate})
            audio.append(out[0].reshape(-1))
            for e in self.meta["mimi_state_manifest"]:
                dstate[e["input_name"]] = out[1 + e["index"]]
        return np.concatenate(audio)


# ---------------------------------------------------------------- sherpa

SHERPA_CHILD = r"""
import sys, json, time, numpy as np, soundfile as sf, sherpa_onnx
d, voice, text, out, extra, steps, silence = sys.argv[1:8]
f = {k: f"{d}/{v}" for k, v in json.load(open(d + "/pocket.json"))["files"].items()}
cfg = sherpa_onnx.OfflineTtsConfig(model=sherpa_onnx.OfflineTtsModelConfig(
    pocket=sherpa_onnx.OfflineTtsPocketModelConfig(**f),
    debug=True, num_threads=2, provider="cpu"))
assert cfg.validate()
tts = sherpa_onnx.OfflineTts(cfg)
ref, sr = sf.read(voice, dtype="float32")
g = sherpa_onnx.GenerationConfig()
g.reference_audio = ref; g.reference_sample_rate = sr; g.num_steps = int(steps)
g.silence_scale = float(silence)  # sherpa's default 0.2 shortens pauses
g.extra = {k: str(v) for k, v in json.loads(extra).items()}
t0 = time.time(); a = tts.generate(text, g); dt = time.time() - t0
sf.write(out, np.array(a.samples, dtype=np.float32), a.sample_rate, subtype="FLOAT")
print(json.dumps({"seconds": dt, "audio_seconds": len(a.samples) / a.sample_rate}))
"""


def run_sherpa(packed: Path, voice: Path, text: str, out_wav: Path, frames_after_eos: int,
               num_steps: int, temperature: float, silence_scale: float = 1.0) -> tuple[dict, list[int] | None]:
    # One sentence per call: disable sherpa's own splitting/merging.
    extra = json.dumps({"temperature": temperature, "frames_after_eos": frames_after_eos, "seed": 0,
                        "min_char_in_sentence": 100000, "max_char_in_sentence": 100000})
    proc = subprocess.run(
        [sys.executable, "-I", "-c", SHERPA_CHILD, str(packed), str(voice), text, str(out_wav), extra,
         str(num_steps), str(silence_scale)],
        capture_output=True, text=True, env={**os.environ, "PYTHONIOENCODING": "utf-8"})
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr[-4000:])
        raise SystemExit("sherpa run failed")
    m = re.search(r"token_ids \(len=\d+\): ([\d ]+)", proc.stderr + proc.stdout)
    ids = [int(x) for x in m.group(1).split()] if m else None
    return json.loads(proc.stdout.strip().splitlines()[-1]), ids


# ---------------------------------------------------------------- compare


def _mel_filterbank(n_fft: int = 1024, n_mels: int = 80) -> np.ndarray:
    hz = lambda m: 700 * (10 ** (m / 2595) - 1)
    mel = lambda f: 2595 * np.log10(1 + f / 700)
    pts = hz(np.linspace(mel(0), mel(SR / 2), n_mels + 2))
    bins = np.floor((n_fft + 1) * pts / SR).astype(int)
    fb = np.zeros((n_mels, n_fft // 2 + 1))
    for i in range(n_mels):
        a, b, c = bins[i], bins[i + 1], bins[i + 2]
        fb[i, a:b] = (np.arange(a, b) - a) / max(b - a, 1)
        fb[i, b:c] = (c - np.arange(b, c)) / max(c - b, 1)
    return fb


_FB = _mel_filterbank()


def log_mel(x: np.ndarray, n_fft: int = 1024, hop: int = 240) -> np.ndarray:
    x = np.pad(x, (n_fft // 2, n_fft // 2))
    frames = np.lib.stride_tricks.sliding_window_view(x, n_fft)[::hop] * np.hanning(n_fft)
    power = np.abs(np.fft.rfft(frames, axis=1)) ** 2
    return 10 * np.log10(power @ _FB.T + 1e-8)


def mel_distance(a: np.ndarray, b: np.ndarray) -> float:
    """Mean absolute log-mel difference in dB, over the common length, floored at -60 dB."""
    n = min(len(a), len(b))
    ma, mb = (np.maximum(log_mel(v[:n]), -60) for v in (a, b))
    return float(np.abs(ma - mb).mean())


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bundle", type=Path, help="original KevinAHM-style bundle")
    ap.add_argument("packed", type=Path, help="output of pack_sherpa.py")
    ap.add_argument("--voice", type=Path, required=True, help="24 kHz mono WAV (use one from <packed>/voices)")
    ap.add_argument("--text", action="append", required=True)
    ap.add_argument("--frames-after-eos", type=int, help="default: upstream's rule (see pocket.json)")
    ap.add_argument("--num-steps", type=int, default=1, help="LSD steps")
    ap.add_argument("--listen-temperature", type=float, default=0.7)
    ap.add_argument("--out", type=Path, default=Path("out/validate"))
    args = ap.parse_args()

    pocket = json.loads((args.packed / "pocket.json").read_text())
    ref = Reference(args.bundle, pocket["precision"])
    base = Reference(args.bundle, pocket["precision"], optimize=False)
    voice, sr = sf.read(str(args.voice), dtype="float32")
    assert sr == SR and voice.ndim == 1, "voice must be 24 kHz mono"

    out_dir = args.out / args.packed.name
    out_dir.mkdir(parents=True, exist_ok=True)
    report, ok = [], True
    for k, raw in enumerate(args.text):
        text, fae = prepare(raw, pocket)
        if args.frames_after_eos is not None:
            fae = args.frames_after_eos
        gen = dict(frames_after_eos=fae, num_steps=args.num_steps)
        print(f"\n[{k}] {text!r}  (frames_after_eos {fae})")

        gold = ref.generate(text, voice, **gen)
        zero = ref.generate(text, voice, zero_init=True, **gen)
        other = base.generate(text, voice, **gen)
        sh_wav = out_dir / f"{k}_sherpa_t0.wav"
        _, sh_ids = run_sherpa(args.packed, args.voice, text, sh_wav, fae, args.num_steps, 0.0)
        sh, _ = sf.read(str(sh_wav), dtype="float32")
        sf.write(str(out_dir / f"{k}_reference_t0.wav"), gold, SR, subtype="FLOAT")

        tok_ok = sh_ids == ref.sp.Encode(text)
        zero_ok = len(zero) == len(gold) and np.array_equal(zero, gold)
        d_base, d_sh = mel_distance(gold, other), mel_distance(gold, sh)
        len_ok = abs(len(sh) - len(gold)) <= 2 * FRAME
        mel_ok = d_sh <= 1.5 * d_base + 0.5
        silent = float(np.sqrt(np.mean(gold ** 2))) < 1e-3
        print(f"  tokens   sherpa == sentencepiece: {tok_ok}")
        print(f"  zero-init states == manifest fills: {zero_ok}")
        print(f"  length   reference {len(gold) / SR:.2f} s, sherpa {len(sh) / SR:.2f} s")
        print(f"  log-mel  sherpa {d_sh:.2f} dB vs baseline {d_base:.2f} dB (ORT optimisations off)")
        if silent:
            print("  note: temperature-0 output is silent for this model; rely on the listening run + ASR")

        listen = out_dir / f"{k}_sherpa_t{args.listen_temperature}.wav"
        lt, _ = run_sherpa(args.packed, args.voice, text, listen, fae, args.num_steps,
                           args.listen_temperature)
        rtf = lt["seconds"] / max(lt["audio_seconds"], 1e-9)
        print(f"  listen   {lt['audio_seconds']:.2f} s of audio in {lt['seconds']:.2f} s (RTF {rtf:.2f}) -> {listen}")
        (out_dir / f"{k}_text.txt").write_text(text, encoding="utf-8")

        if not (len_ok and mel_ok):
            print("  info: temperature-0 run drifted from the reference (see docstring); check ASR")
        passed = tok_ok and zero_ok
        ok &= passed
        report.append({"text": text, "passed": passed, "tokens_match": tok_ok, "zero_init_exact": zero_ok,
                       "t0_close_to_reference": bool(len_ok and mel_ok),
                       "ref_seconds": len(gold) / SR, "sherpa_seconds": len(sh) / SR,
                       "mel_db_sherpa": round(d_sh, 3), "mel_db_baseline": round(d_base, 3),
                       "silent_at_t0": silent, "listen_wav": str(listen), "listen_rtf": round(rtf, 3)})

    (out_dir / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(f"\n{'PASS' if ok else 'FAIL'}  (wavs + report.json in {out_dir})")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
