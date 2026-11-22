#!/usr/bin/env python3
"""Smoke-test an export of ours with one of Kyutai's precomputed voice states.

Handy before you have the gated voice-cloning weights: the non-gated checkpoint has a
zeroed Mimi encoder, so cloning from audio can't work, but Kyutai publishes the FlowLM
state *after* each catalog voice's prompt (``languages/<lang>/embeddings/<voice>.safetensors``).
We place that KV cache into our sliding-window layout, then generate with our ONNX
graphs (numpy loop from validate.py) and write WAVs for asr_check.py.

Only for bundles made by export_onnx.py (offset + sliding cache state layout).

    .venv/bin/python check_predefined_voice.py downloads/ours_nvc/french --voice estelle \
        --text "Aujourd'hui, maman est morte."
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import soundfile as sf
from huggingface_hub import hf_hub_download
from safetensors.numpy import load_file

from text_prep import prepare_text_prompt
from validate import Reference

REPO = "kyutai/pocket-tts-without-voice-cloning"
REVISION = "a7056f505a4a8ca72d8b5fb1440071d6f1a35739"  # pocket_tts.utils.utils.get_predefined_voice


def predefined_state(ref: Reference, language: str, voice: str) -> dict:
    path = hf_hub_download(REPO, f"languages/{language}/embeddings/{voice}.safetensors", revision=REVISION)
    raw = load_file(path)
    state = ref._state("flow_lm_state_manifest", zero_init=True)
    for e in ref.meta["flow_lm_state_manifest"]:
        prefix = e["module"] + "/"
        if e["key"] == "cache":
            src = raw[prefix + "cache"]  # [2, 1, P, H, D], every slot valid
            if prefix + "current_end" in raw:
                p = raw[prefix + "current_end"].shape[0]
            else:
                p = int(np.asarray(raw[prefix + "offset"]).reshape(-1)[0])
            src = src[:, :, :p]
            L = e["shape"][2]
            assert p <= L, f"voice prompt ({p}) longer than the cache window ({L})"
            dst = state[e["input_name"]]
            dst[:, :, L - p:] = src  # last slots = positions 0 .. p-1
            state["_p"] = p
        elif e["key"] == "offset":
            pass
    p = state.pop("_p")
    for e in ref.meta["flow_lm_state_manifest"]:
        if e["key"] == "offset":
            state[e["input_name"]] = np.array([p], dtype=np.int64)
    print(f"  {voice}: {p} prompt positions")
    return state


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bundle", type=Path)
    ap.add_argument("--voice", default="estelle")
    ap.add_argument("--text", action="append", required=True)
    ap.add_argument("--precision", default="int8", choices=["int8", "fp32"])
    ap.add_argument("--temperature", type=float, default=0.3)
    ap.add_argument("--upstream-config", type=Path, help="for replace_characters")
    ap.add_argument("--out", type=Path, default=Path("out/predefined"))
    args = ap.parse_args()

    ref = Reference(args.bundle, args.precision)
    meta = ref.meta
    rules = {"remove_semicolons": meta["remove_semicolons"],
             "pad_with_spaces_for_short_inputs": meta["pad_with_spaces_for_short_inputs"]}
    if args.upstream_config:
        import yaml
        rules["replace_characters"] = yaml.safe_load(args.upstream_config.read_text()).get("replace_characters", {})
    state = predefined_state(ref, meta["language"], args.voice)
    out = args.out / f"{meta['language']}-{args.precision}-{args.voice}"
    out.mkdir(parents=True, exist_ok=True)
    for k, raw in enumerate(args.text):
        text, guess = prepare_text_prompt(raw, rules)
        rec = meta.get("model_recommended_frames_after_eos")
        audio = ref.generate(text, None, rec if rec is not None else guess + 2, 1,
                             temperature=args.temperature, state=state)
        wav = out / f"{k}_sherpa_t{args.temperature}.wav"  # name matches asr_check.py --dir
        sf.write(str(wav), audio, 24000, subtype="FLOAT")
        (out / f"{k}_text.txt").write_text(text, encoding="utf-8")
        print(f"  [{k}] {len(audio) / 24000:.2f} s -> {wav}")
    print(json.dumps({"out": str(out)}))


if __name__ == "__main__":
    main()
