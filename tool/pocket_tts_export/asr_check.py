#!/usr/bin/env python3
"""Transcribe WAVs with Whisper (mlx-audio, Apple GPU) and print the word error rate.

Runs with the tests_tts venv, which already has mlx-audio:
    ../tests_tts/.venv/bin/python asr_check.py --lang de --expect "Guten Tag." a.wav b.wav
    ../tests_tts/.venv/bin/python asr_check.py --lang de --dir out/validate/pocket-german-int8

With --dir, it checks every <k>_sherpa_t*.wav that validate.py wrote, against <k>_text.txt.
"""

import argparse
import re
import unicodedata
from pathlib import Path

from mlx_audio.stt.utils import load_model

MODEL = "mlx-community/whisper-large-v3-turbo-asr-fp16"


def words(s: str) -> list[str]:
    s = unicodedata.normalize("NFC", s.lower()).replace("’", "'")
    return re.findall(r"[\w']+", s)


def wer(ref: list[str], hyp: list[str]) -> float:
    d = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, d[0] = d[0], i
        for j, h in enumerate(hyp, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r != h))
    return d[-1] / max(len(ref), 1)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", required=True, help="whisper language code: de, fr, en, ...")
    ap.add_argument("--expect", help="the text that was synthesized")
    ap.add_argument("--dir", help="a validate.py output directory")
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--max-wer", type=float, help="exit 1 if the mean WER is above this (e.g. 0.2)")
    ap.add_argument("wavs", nargs="*")
    args = ap.parse_args()

    jobs = [(w, args.expect) for w in args.wavs]
    if args.dir:
        d = Path(args.dir)
        for txt in sorted(d.glob("*_text.txt")):
            k = txt.name.split("_")[0]
            jobs += [(str(w), txt.read_text(encoding="utf-8")) for w in sorted(d.glob(f"{k}_sherpa_t*.wav"))
                     if not w.name.endswith("_t0.wav")]
    model = load_model(args.model)
    scores = []
    for wav, expect in jobs:
        text = model.generate(wav, language=args.lang).text.strip()
        scores.append(wer(words(expect), words(text)))
        print(f"{scores[-1]:6.1%}  {wav}\n        {text}")
    if scores:
        mean = sum(scores) / len(scores)
        print(f"mean WER {mean:.1%} over {len(scores)} file(s)")
        if args.max_wer is not None and mean > args.max_wer:
            raise SystemExit(f"FAIL: mean WER above {args.max_wer:.0%}")


if __name__ == "__main__":
    main()
