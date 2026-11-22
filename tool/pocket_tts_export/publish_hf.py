#!/usr/bin/env python3
"""Package and upload sherpa-onnx Pocket TTS packs to Hugging Face Hub.

Packages each ``out/pocket-<language>-int8`` directory into a ``.tar.bz2`` archive,
writes a CC-BY-4.0 model card (with Kyutai attribution, prohibited-use notice, and
voice license breakdown), and uploads them to a public Hugging Face model repository
so the Flutter app can download languages on demand without a Hugging Face account.

Usage:
    .venv/bin/python publish_hf.py --dry-run
    .venv/bin/python publish_hf.py --repo Duf-1/pocket-tts-sherpa-onnx
"""

from __future__ import annotations

import argparse
import json
import tarfile
from pathlib import Path

from huggingface_hub import HfApi

DEFAULT_REPO = "Duf-1/pocket-tts-sherpa-onnx"
PACKS = {
    "en": "pocket-english-int8",
    "fr": "pocket-french-int8",
    "de": "pocket-german-int8",
    "es": "pocket-spanish-int8",
}

MODEL_CARD = """---
license: cc-by-4.0
language:
- en
- fr
- de
- es
library_name: sherpa-onnx
base_model:
- kyutai/pocket-tts
tags:
- tts
- text-to-speech
- onnx
- sherpa-onnx
- pocket-tts
- kyutai
---

# Pocket TTS — sherpa-onnx INT8 Packs (EN, FR, DE, ES)

Pre-packaged **INT8 ONNX** exports of [Kyutai Pocket TTS](https://huggingface.co/kyutai/pocket-tts) ready to load directly with [`sherpa-onnx`](https://github.com/k2-fsa/sherpa-onnx) (`OfflineTtsPocketModelConfig`).

Each archive (`pocket-<language>-int8.tar.bz2`, ~120 MB compressed / ~185 MB extracted) contains:
- `lm_main.int8.onnx` & `lm_flow.int8.onnx` (dynamic int8 MatMul/Gemm)
- `encoder.onnx` (fp32 Mimi encoder + speaker projection, with the multilingual `bos_before_voice` embedding prepended via `Concat` so `sherpa-onnx` 2.0.1 runs multilingual checkpoints out of the box)
- `decoder.onnx` (fp32 Mimi decoder with fixed sliding-window KV caches)
- `text_conditioner.onnx`, `vocab.json`, `token_scores.json`
- `pocket.json` (file map, upstream text-normalization rules, generation defaults)
- `voices/*.wav` (24 kHz mono reference voice clips trimmed with `end_on_pause`)

| Language | Archive | Voices included |
|---|---|---|
| English (`en`) | `pocket-english-int8.tar.bz2` | `alba` |
| French (`fr`) | `pocket-french-int8.tar.bz2` | `estelle`, `fabien` |
| German (`de`) | `pocket-german-int8.tar.bz2` | `juergen` |
| Spanish (`es`) | `pocket-spanish-int8.tar.bz2` | `lola` |

## Attribution & License (CC-BY-4.0)

* **Original Model & Weights:** [Kyutai Pocket TTS](https://huggingface.co/kyutai/pocket-tts) by **Kyutai** (Manu Orsini, Simon Rouard, Gabriel De Marmiesse, Václav Volhejn, Neil Zeghidour, Alexandre Défossez), licensed under [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/).
* **Modifications made in this derivative export:**
  1. Exported PyTorch weights (`english_2026-10`, `french`, `german`, `spanish`) to ONNX (opset 17) with fixed-size sliding-window KV caches and zero-initialized streaming states compatible with `sherpa-onnx`.
  2. Applied dynamic INT8 quantization (`MatMul` / `Gemm`) to `flow_lm_main` and `flow_lm_flow`.
  3. Prepended the learned `bos_before_voice` tensor to `encoder.onnx` for multilingual checkpoints and converted the SentencePiece tokenizer to `vocab.json` + `token_scores.json`.
* **Reference Voices (`voices/*.wav`):** Sourced from [`kyutai/tts-voices`](https://huggingface.co/kyutai/tts-voices) and [`kyutai/pocket-tts`](https://huggingface.co/kyutai/pocket-tts):
  * `estelle` (`unmute-prod-website/developpeuse-3.wav`) & `fabien` (`unmute-prod-website/fabieng-enhanced-v2.wav`): Kyutai recordings released under **CC0**.
  * `alba` (`alba-mackenna/casual.wav`): Voice-acted by Alba MacKenna, released under **CC-BY-4.0**.
  * `lola` (`common_voice_es_19762977-enhanced-v2.mp3`): From Mozilla Common Voice (**CC0**).
  * `juergen` (`de-DE-juergen.mp3`): From `kyutai/pocket-tts` (**CC-BY-4.0**).

## Prohibited Use

Per Kyutai's model terms:
> Use of this model must comply with all applicable laws and regulations and must not result in, involve, or facilitate any illegal, harmful, deceptive, fraudulent, or unauthorized activity. Prohibited uses include, without limitation, voice impersonation or cloning without explicit and lawful consent; misinformation, disinformation, or deception (including fake news, fraudulent calls, or presenting generated content as genuine recordings of real people or events); and the generation of unlawful, harmful, libelous, abusive, harassing, discriminatory, hateful, or privacy-invasive content.
"""

LICENSE_TEXT = """Creative Commons Attribution 4.0 International (CC-BY-4.0)

Original model weights: Kyutai Pocket TTS (https://huggingface.co/kyutai/pocket-tts)
by Kyutai (Manu Orsini, Simon Rouard, Gabriel De Marmiesse, Václav Volhejn,
Neil Zeghidour, Alexandre Défossez).

Licensed under CC-BY-4.0: https://creativecommons.org/licenses/by/4.0/

Changes made: Exported to ONNX with sliding-window KV caches, dynamic int8
quantization on FlowLM main/flow networks, BOS-prefixed Mimi encoder graph,
and SentencePiece vocabulary JSON conversion for sherpa-onnx.
"""


def build_archive(pack_dir: Path, dist_dir: Path) -> Path:
    meta = json.loads((pack_dir / "pocket.json").read_text(encoding="utf-8"))
    if not meta.get("has_voice_cloning", False):
        raise SystemExit(f"{pack_dir} was exported without voice cloning; refusing to package.")
    (pack_dir / "LICENSE").write_text(LICENSE_TEXT, encoding="utf-8")
    archive_path = dist_dir / f"{pack_dir.name}.tar.bz2"
    print(f"  packing {pack_dir.name} -> {archive_path.name} ...")
    with tarfile.open(archive_path, "w:bz2") as tar:
        for item in sorted(pack_dir.rglob("*")):
            if item.name.startswith("."):
                continue
            arcname = f"{pack_dir.name}/{item.relative_to(pack_dir)}"
            tar.add(item, arcname=arcname, recursive=False)
    size_mb = archive_path.stat().st_size / 1e6
    print(f"    wrote {archive_path} ({size_mb:.1f} MB)")
    return archive_path


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out-dir", type=Path, default=Path("out"), help="folder holding pocket-*-int8 directories")
    ap.add_argument("--dist-dir", type=Path, default=Path("out/dist"), help="where .tar.bz2 archives are written")
    ap.add_argument("--repo", default=DEFAULT_REPO, help="Hugging Face model repo id (<user>/<repo>)")
    ap.add_argument("--dry-run", action="store_true", help="build archives and README locally without uploading")
    args = ap.parse_args()

    args.dist_dir.mkdir(parents=True, exist_ok=True)
    readme_path = args.dist_dir / "README.md"
    readme_path.write_text(MODEL_CARD, encoding="utf-8")
    license_path = args.dist_dir / "LICENSE"
    license_path.write_text(LICENSE_TEXT, encoding="utf-8")

    archives = []
    for lang, name in PACKS.items():
        pack_dir = args.out_dir / name
        if not pack_dir.exists():
            raise SystemExit(f"Missing pack directory: {pack_dir}")
        archives.append(build_archive(pack_dir, args.dist_dir))

    if args.dry_run:
        print(f"Dry run complete. Files ready in {args.dist_dir}")
        return

    api = HfApi()
    url = api.create_repo(repo_id=args.repo, repo_type="model", exist_ok=True, private=False)
    print(f"Uploading to {url} ...")
    api.upload_folder(
        repo_id=args.repo,
        repo_type="model",
        folder_path=str(args.dist_dir),
        commit_message="Upload sherpa-onnx Pocket TTS int8 packs (en, fr, de, es)",
    )
    print(f"Done! Public URLs:\n  https://huggingface.co/{args.repo}")
    for a in archives:
        print(f"  https://huggingface.co/{args.repo}/resolve/main/{a.name}")


if __name__ == "__main__":
    main()
