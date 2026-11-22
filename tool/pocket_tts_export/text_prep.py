"""Pocket TTS text preparation, which sherpa-onnx doesn't do (the app must).

Port of ``prepare_text_prompt`` and ``_ensure_terminal_punctuation`` from
kyutai-labs/pocket-tts ``pocket_tts/models/text_chunking.py`` (MIT licence).
Keep it in sync with the Dart port in the app.

Input is one sentence (the app already splits text into sentences).
"""

from __future__ import annotations

import re

_TERMINAL_PUNCTUATION = ".!?…"
_WEAK_PUNCTUATION = ",;:-–—"
_CLOSERS = "\"'”’)]»"


def ensure_terminal_punctuation(text: str) -> str:
    core = text.rstrip(_CLOSERS + " ")
    closers = text[len(core):].strip()
    if not core or core[-1] in _TERMINAL_PUNCTUATION:
        return text
    if core[-1] in _WEAK_PUNCTUATION:
        return core.rstrip(_WEAK_PUNCTUATION + " ") + "." + closers
    return text + "."


def prepare_text_prompt(text: str, rules: dict) -> tuple[str, int]:
    """Return (prepared text, frames_after_eos guess). ``rules`` is pocket.json's "text"."""
    text = text.strip()
    replace = rules.get("replace_characters") or {}
    if replace:
        text = " ".join(text.translate(str.maketrans(replace)).split())
        # '"Hi?", she said' -> 'Hi?, she said' after deleting quotes: keep the sentence mark only.
        text = re.sub(r"([.!?…])\s*[,;:]", r"\1", text)
    if text == "":
        raise ValueError("Text prompt cannot be empty")
    text = text.replace("\n", " ").replace("\r", " ").replace("  ", " ")
    if rules.get("remove_semicolons"):
        text = text.replace(";", ",")
    frames_after_eos_guess = 3 if len(text.split()) <= 4 else 1
    if rules.get("capitalize_first_letter", True) and not text[0].isupper():
        text = text[0].upper() + text[1:]
    if rules.get("append_terminal_punctuation", True):
        text = ensure_terminal_punctuation(text)
    if rules.get("pad_with_spaces_for_short_inputs") and len(text.split()) < 5:
        text = " " * 8 + text
    return text, frames_after_eos_guess
