#!/usr/bin/env python3
"""Turn a Pocket TTS ONNX bundle into a directory sherpa-onnx can load.

Input: a KevinAHM-style bundle directory (``bundle.json``, ``tokenizer.model``,
``bos_before_voice.npy``, ``flow_lm_main[_int8].onnx``, ``flow_lm_flow[_int8].onnx``,
``mimi_encoder.onnx``, ``mimi_decoder[_int8].onnx``, ``text_conditioner.onnx``).
It can come from https://huggingface.co/KevinAHM/pocket-tts-onnx or from our own
export of an upstream checkpoint.

Output: the files of sherpa-onnx's ``OfflineTtsPocketModelConfig`` (``pocket.json``
"files" says which is which; ``.int8`` when a quantized graph was used):

    lm_main[.int8].onnx  lm_flow[.int8].onnx  encoder.onnx  decoder[.int8].onnx
    text_conditioner.onnx  vocab.json  token_scores.json  pocket.json  voices/*.wav

What it changes:
- Multilingual checkpoints (2026-04 and later) need a learned BOS embedding in
  front of the voice embedding (``insert_bos_before_voice``). sherpa-onnx 2.0.1
  doesn't know about it, but it passes the encoder output straight to lm_main as
  the voice embedding. So we bake the BOS into the encoder graph with one Concat.
  No sherpa change needed.
- The SentencePiece tokenizer is converted to sherpa's vocab.json + token_scores.json.
- ``pocket.json`` keeps the text-preparation rules (from the upstream YAML) that the
  app has to apply before calling sherpa, which doesn't apply them itself
  (see text_prep.py).

Usage:
    .venv/bin/python pack_sherpa.py downloads/kevin/onnx/german out/pocket-german-int8 \
        --upstream-config downloads/upstream_config/german.yaml \
        --voice estelle=downloads/voices/unmute-prod-website/developpeuse-3.wav
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import sentencepiece as spm
import soundfile as sf
import yaml
from onnx import helper, numpy_helper
from scipy.signal import resample_poly

SAMPLE_RATE = 24000


def pick(bundle: Path, stem: str, precision: str) -> Path:
    """Pick ``<stem>_int8.onnx`` if asked for and present, else ``<stem>.onnx``."""
    if precision == "int8" and (bundle / f"{stem}_int8.onnx").exists():
        return bundle / f"{stem}_int8.onnx"
    if (bundle / f"{stem}.onnx").exists():
        return bundle / f"{stem}.onnx"
    raise FileNotFoundError(f"no {stem}[_int8].onnx in {bundle}")


def prepend_bos_to_encoder(src: Path, dst: Path, bos: np.ndarray) -> None:
    """Rewrite the Mimi encoder so its output is concat([bos, latents], axis=1)."""
    model = onnx.load(str(src))
    graph = model.graph
    assert len(graph.output) == 1, "expected a single encoder output"
    out_name = graph.output[0].name
    inner = out_name + "_without_bos"

    for node in graph.node:
        node.output[:] = [inner if o == out_name else o for o in node.output]
        node.input[:] = [inner if i == out_name else i for i in node.input]

    bos = bos.astype(np.float32).reshape(1, 1, -1)
    graph.initializer.append(numpy_helper.from_array(bos, "bos_before_voice"))
    graph.node.append(
        helper.make_node(
            "Concat", ["bos_before_voice", inner], [out_name], axis=1, name="prepend_bos"
        )
    )
    # The frame count is now "frames + 1": make it a plain symbolic dim.
    dim = graph.output[0].type.tensor_type.shape.dim[1]
    dim.Clear()
    dim.dim_param = "num_frames_plus_bos"

    onnx.checker.check_model(model)
    onnx.save(model, str(dst))


def check_encoder(src: Path, dst: Path, bos: np.ndarray) -> None:
    """The patched encoder must equal concat(bos, original output)."""
    audio = np.random.default_rng(0).standard_normal((1, 1, SAMPLE_RATE * 2)).astype(np.float32) * 0.1
    a = ort.InferenceSession(str(src)).run(None, {"audio": audio})[0]
    b = ort.InferenceSession(str(dst)).run(None, {"audio": audio})[0]
    expected = np.concatenate([bos.reshape(1, 1, -1), a], axis=1)
    assert b.shape == expected.shape, (b.shape, expected.shape)
    assert np.array_equal(b, expected), "patched encoder output differs"
    print(f"  encoder: BOS prepended, output {a.shape} -> {b.shape}, exact match")


def convert_tokenizer(model_file: Path, out_dir: Path) -> None:
    """Same conversion as sherpa-onnx/scripts/pocket-tts/convert_tokenizer.py."""
    sp = spm.SentencePieceProcessor(model_file=str(model_file))
    token2id, token2score = {}, {}
    for i in range(sp.get_piece_size()):
        piece = sp.id_to_piece(i)
        token2id[piece] = i
        token2score[piece] = sp.get_score(i)
    (out_dir / "vocab.json").write_text(json.dumps(token2id, indent=2, ensure_ascii=False), encoding="utf-8")
    (out_dir / "token_scores.json").write_text(json.dumps(token2score, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"  tokenizer: {sp.get_piece_size()} pieces")


def end_on_pause(wav: np.ndarray, sr: int, pause_sec: float = 0.08, fade_sec: float = 0.02,
                 floor_db: float = 35.0) -> np.ndarray:
    """Port of pocket_tts.data.audio_utils.end_on_pause (MIT): end the prompt on exactly
    `pause_sec` of silence. A prompt ending on speech makes the model continue it."""
    frame = max(1, int(0.02 * sr))
    n = len(wav) // frame
    if n == 0:
        return wav
    rms = np.sqrt(np.mean(wav[: n * frame].reshape(n, frame) ** 2, axis=1))
    db = 20 * np.log10(rms + 1e-12)
    end = (int(np.nonzero(db > db.max() - floor_db)[0][-1]) + 1) * frame
    wav = wav[:end].copy()
    fade = min(int(fade_sec * sr), end)
    wav[end - fade:] *= np.linspace(1, 0, fade, dtype=wav.dtype)
    return np.concatenate([wav, np.zeros(int(pause_sec * sr), wav.dtype)])


def write_voice(src: Path, dst: Path) -> None:
    """Mono 24 kHz float WAV, cut so that after end_on_pause it stays under 10 s
    (sherpa's default max_reference_audio_len would otherwise cut it mid-word)."""
    audio, sr = sf.read(str(src), dtype="float32", always_2d=True)
    audio = audio.mean(axis=1)
    if sr != SAMPLE_RATE:
        g = np.gcd(sr, SAMPLE_RATE)
        audio = resample_poly(audio, SAMPLE_RATE // g, sr // g).astype(np.float32)
    audio = end_on_pause(audio[: int(SAMPLE_RATE * 9.9)], SAMPLE_RATE)
    sf.write(str(dst), audio, SAMPLE_RATE, subtype="FLOAT")
    print(f"  voice: {dst.name} ({len(audio) / SAMPLE_RATE:.2f} s, ends on a pause)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bundle", type=Path, help="KevinAHM-style bundle directory")
    ap.add_argument("out", type=Path, help="output directory (sherpa layout)")
    ap.add_argument("--precision", choices=["int8", "fp32"], default="int8",
                    help="for lm_main, lm_flow and the decoder; encoder and text conditioner stay fp32")
    ap.add_argument("--upstream-config", type=Path,
                    help="upstream pocket_tts/config/<language>.yaml, for the text-preparation rules")
    ap.add_argument("--voice", action="append", default=[], metavar="NAME=PATH",
                    help="reference voice to ship with the model (repeatable)")
    args = ap.parse_args()

    bundle: Path = args.bundle
    meta = json.loads((bundle / "bundle.json").read_text())
    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)
    print(f"{meta['bundle_name']} -> {out}")

    for old in out.glob("*.onnx"):  # don't leave a stale int8/fp32 twin behind
        old.unlink()
    files = {}
    for key, stem in (("lm_main", "flow_lm_main"), ("lm_flow", "flow_lm_flow"), ("decoder", "mimi_decoder")):
        src = pick(bundle, stem, args.precision)
        name = f"{key}.int8.onnx" if src.stem.endswith("_int8") else f"{key}.onnx"
        shutil.copyfile(src, out / name)
        files[key] = name
    # The text conditioner is an embedding lookup: int8 saves nothing (same size).
    shutil.copyfile(bundle / "text_conditioner.onnx", out / "text_conditioner.onnx")
    files.update(encoder="encoder.onnx", text_conditioner="text_conditioner.onnx",
                 vocab_json="vocab.json", token_scores_json="token_scores.json")
    print("  graphs: " + ", ".join(f"{k}={v}" for k, v in files.items() if v.endswith(".onnx")))

    encoder_src = bundle / "mimi_encoder.onnx"
    if meta.get("insert_bos_before_voice"):
        bos = np.load(bundle / meta["bos_before_voice_file"])
        prepend_bos_to_encoder(encoder_src, out / "encoder.onnx", bos)
        check_encoder(encoder_src, out / "encoder.onnx", bos)
    else:
        shutil.copyfile(encoder_src, out / "encoder.onnx")
        print("  encoder: copied (this checkpoint has no BOS before the voice)")

    convert_tokenizer(bundle / meta["tokenizer_file"], out)

    upstream = yaml.safe_load(args.upstream_config.read_text()) if args.upstream_config else {}
    voices = {}
    if args.voice:
        (out / "voices").mkdir(exist_ok=True)
        for spec in args.voice:
            name, path = spec.split("=", 1)
            write_voice(Path(path), out / "voices" / f"{name}.wav")
            voices[name] = f"voices/{name}.wav"

    # Rules the caller applies before sherpa (sherpa only splits sentences).
    pocket = {
        "schema_version": 1,
        "language": meta["language"],
        "precision": args.precision,
        "files": files,  # sherpa-onnx OfflineTtsPocketModelConfig fields -> file
        "sample_rate": meta["sample_rate"],
        "num_layers": sum(1 for e in meta["flow_lm_state_manifest"] if e["key"] == "cache"),
        "text": {
            "remove_semicolons": bool(upstream.get("remove_semicolons", meta.get("remove_semicolons", False))),
            "replace_characters": upstream.get("replace_characters", {}),
            "pad_with_spaces_for_short_inputs": bool(meta.get("pad_with_spaces_for_short_inputs", False)),
            "capitalize_first_letter": bool(upstream.get("capitalize_first_letter", True)),
            "append_terminal_punctuation": bool(upstream.get("append_terminal_punctuation", True)),
        },
        # sherpa extra "frames_after_eos": this value when set, else (3 if <= 4 words else 1) + 2.
        "model_recommended_frames_after_eos": meta.get("model_recommended_frames_after_eos"),
        # Upstream generation defaults (sherpa's own default temperature is 0.7).
        "default_temperature": float(meta.get("default_temperature", upstream.get("default_temperature", 0.3))),
        "eos_threshold": float(meta.get("default_eos_threshold", upstream.get("default_eos_threshold", -4.0))),
        "min_frames_before_eos": 6,  # upstream ignores EOS before this; sherpa doesn't
        "has_voice_cloning": bool(meta.get("has_voice_cloning", True)),
        "voices": voices,
        "source": {"bundle": str(bundle), "upstream_config": str(args.upstream_config or "")},
    }
    (out / "pocket.json").write_text(json.dumps(pocket, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    lic = bundle.parent / "LICENSE"
    if lic.exists():
        shutil.copyfile(lic, out / "LICENSE")

    total = sum(f.stat().st_size for f in out.rglob("*") if f.is_file())
    print(f"  done: {total / 1e6:.0f} MB")


if __name__ == "__main__":
    main()
