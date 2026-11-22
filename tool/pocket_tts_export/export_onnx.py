#!/usr/bin/env python3
"""Export an upstream Pocket TTS checkpoint (kyutai-labs/pocket-tts) to ONNX.

Writes a KevinAHM-style bundle (bundle.json schema 2, same graph inputs/outputs),
so ``pack_sherpa.py`` and ``validate.py`` work on it unchanged:

    flow_lm_main.onnx   (sequence, text_embeddings, state_*) -> (conditioning, eos_logit, out_state_*)
    flow_lm_flow.onnx   (c, s, t, x) -> flow_dir                      [LSD velocity]
    mimi_encoder.onnx   (audio [1,1,N]) -> latents [1,F,1024]         [speaker_proj applied]
    mimi_decoder.onnx   (latent [1,F,32], state_*) -> (audio_frame, out_state_*)
    text_conditioner.onnx (token_ids [1,T]) -> embeddings [1,T,1024]
    *_int8.onnx         dynamic int8 (MatMul/Gemm only) of lm_main, lm_flow
    tokenizer.model, bos_before_voice.npy, bundle.json

How the stateful code is made exportable (pocket_tts 4.x passes state as dicts of tensors):
- Attention KV caches become fixed-size *sliding windows*: concat the new keys, keep
  the last L slots. Positions come from an int64 ``offset`` state, and slots never written
  get negative positions, which the existing mask drops. No scatter, no .item().
  FlowLM: L = --flow-cache (1000, like KevinAHM). Mimi decoder: L = its context (250),
  so decoding length is unbounded.
- Streaming convs return their new state instead of writing into the input tensor.
- Every state starts at zero (sherpa-onnx's init). The KV caches start at zeros instead of
  NaN, which is safe because masked slots are never read.
- The encoder's pad-to-whole-frames and causal mask use traced shapes, so any audio
  length works.

Each graph is checked against the original, unpatched PyTorch code (streaming over
several calls), first after patching and again through onnxruntime.

Usage:
    .venv/bin/python export_onnx.py --language french --out downloads/ours/french
    .venv/bin/python export_onnx.py --language french --out downloads/ours/french --allow-no-voice-cloning
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import torch
import torch.nn.functional as F
from onnxruntime.quantization import QuantType, quantize_dynamic
from torch import nn

from pocket_tts import TTSModel
from pocket_tts.modules import attention as attn_mod
from pocket_tts.modules import conv as conv_mod
from pocket_tts.modules import transformer as tr_mod
from pocket_tts.modules.stateful_module import StatefulModule, increment_steps, init_states
from pocket_tts.utils.utils import download_if_necessary

OPSET = 17
torch.manual_seed(0)


# ----------------------------------------------------------------- patches


def _sliding_append_and_get(self, k, v, state):
    if state is None:
        return _orig_append_and_get(self, k, v, state)
    cache, offset = state["cache"], state["offset"]
    t = k.shape[1]
    full = torch.cat([cache, torch.stack([k, v], dim=0).to(cache.dtype)], dim=2)  # [2,B,L+t,H,D]
    L = cache.shape[2]
    state["cache"] = full[:, :, t:]
    state["offset"] = offset + t  # rope offset was read before this call
    k_attn = full[0].permute(0, 2, 1, 3)
    v_attn = full[1].permute(0, 2, 1, 3)
    # slot i of `full` holds absolute position offset - L + i (negative = never written)
    pos_k = offset.view(-1, 1) - L + torch.arange(L + t, device=k.device, dtype=torch.long).view(1, -1)
    return k_attn, v_attn, pos_k, offset


def _traced_causal_mask(t, context, device):
    pos = torch.arange(t, device=device, dtype=torch.long).view(1, -1)
    return attn_mod._build_attention_mask(pos, pos, context)


def _functional_conv_forward(self, x, model_state):
    if model_state is None:
        return _orig_conv_forward(self, x, model_state)
    assert self.pad_mode == "constant", "replicate padding would need the `first` state"
    state = self.get_state(model_state)
    tp = self._effective_kernel_size - self._stride  # 0 for 1x1 convs: no state
    if tp:
        x = torch.cat([state["previous"], x], dim=-1)
    y = self.conv(x)
    if tp:
        state["previous"] = x[..., -tp:]
    return y


def _functional_convtr_forward(self, x, mimi_state):
    state = self.get_state(mimi_state)
    partial = state["partial"]
    y = self.convtr(x)
    pt = partial.shape[-1]
    if pt > 0:
        y = torch.cat([y[..., :pt] + partial, y[..., pt:]], dim=-1)
        for_partial = y[..., -pt:]
        if self.convtr.bias is not None:
            for_partial = for_partial - self.convtr.bias[:, None]
        state["partial"] = for_partial
        y = y[..., :-pt]
    return y


_orig_append_and_get = attn_mod._LinearKVCacheBackend.append_and_get
_orig_conv_forward = conv_mod.StreamingConv1d.forward
_orig_convtr_forward = conv_mod.StreamingConvTranspose1d.forward
_orig_causal_mask = attn_mod._cached_causal_mask


def apply_patches(on: bool) -> None:
    attn_mod._LinearKVCacheBackend.append_and_get = _sliding_append_and_get if on else _orig_append_and_get
    conv_mod.StreamingConv1d.forward = _functional_conv_forward if on else _orig_conv_forward
    conv_mod.StreamingConvTranspose1d.forward = _functional_convtr_forward if on else _orig_convtr_forward
    mask = _traced_causal_mask if on else _orig_causal_mask
    attn_mod._cached_causal_mask = mask
    tr_mod._cached_causal_mask = mask


# ----------------------------------------------------------------- state specs


def state_spec(root: nn.Module, prefix: str, attn_len: dict[str, int]) -> list[dict]:
    """Ordered list of the streaming-state tensors of `root`'s StatefulModules."""
    spec = []
    for name, mod in root.named_modules():
        if not isinstance(mod, StatefulModule):
            continue
        full = f"{prefix}.{name}" if prefix else name
        if isinstance(mod, attn_mod.StreamingMultiheadAttention):
            L = attn_len[full] if full in attn_len else attn_len["*"]
            spec.append(dict(module=full, key="cache", dtype="float32",
                             shape=[2, 1, L, mod.num_kv_heads, mod.dim_per_head]))
            spec.append(dict(module=full, key="offset", dtype="int64", shape=[1]))
        elif isinstance(mod, conv_mod.StreamingConv1d):
            tp = mod._effective_kernel_size - mod._stride
            if tp:
                spec.append(dict(module=full, key="previous", dtype="float32",
                                 shape=[1, mod.conv.in_channels, tp]))
        elif isinstance(mod, conv_mod.StreamingConvTranspose1d):
            pt = mod._kernel_size - mod._stride
            spec.append(dict(module=full, key="partial", dtype="float32",
                             shape=[1, mod.convtr.out_channels, pt]))
        else:
            raise NotImplementedError(type(mod))
    for i, e in enumerate(spec):
        e.update(index=i, input_name=f"state_{i}", output_name=f"out_state_{i}", fill="zeros",
                 path=f"{e['module']}/{e['key']}")
    return spec


def zero_states(spec: list[dict]) -> list[torch.Tensor]:
    dt = {"float32": torch.float32, "int64": torch.int64}
    return [torch.zeros(e["shape"], dtype=dt[e["dtype"]]) for e in spec]


def to_model_state(spec, tensors, root: nn.Module) -> dict:
    """Module names in the dict must match what get_state() looks up (stamped names).
    Stateless streaming modules (1x1 convs) still get an (empty) entry."""
    ms: dict[str, dict[str, torch.Tensor]] = {
        n: {} for n, m in root.named_modules() if isinstance(m, StatefulModule)}
    for e, t in zip(spec, tensors):
        ms.setdefault(e["module"], {})[e["key"]] = t
    return ms


def from_model_state(spec, ms) -> list[torch.Tensor]:
    return [ms[e["module"]][e["key"]] for e in spec]


# ----------------------------------------------------------------- wrappers


class FlowLMMain(nn.Module):
    def __init__(self, flow_lm, spec):
        super().__init__()
        self.flow_lm, self.spec = flow_lm, spec

    def forward(self, sequence, text_embeddings, *states):
        fl = self.flow_lm
        ms = to_model_state(self.spec, states, self.flow_lm)
        seq = torch.where(torch.isnan(sequence), fl.bos_emb, sequence)
        x = torch.cat([text_embeddings, fl.input_linear(seq)], dim=1)
        out = fl.transformer(x, ms)
        out = fl.out_norm(out).to(torch.float32)[:, -1]
        if fl.z_proj is not None:
            out = fl.z_proj(out)
        return (out, fl.out_eos(out), *from_model_state(self.spec, ms))


class FlowLMFlow(nn.Module):
    def __init__(self, flow_net):
        super().__init__()
        self.flow_net = flow_net

    def forward(self, c, s, t, x):
        return self.flow_net(c, s, t, x)


class MimiEncoder(nn.Module):
    def __init__(self, mimi, speaker_proj_weight):
        super().__init__()
        self.mimi = mimi
        self.speaker_proj_weight = speaker_proj_weight

    def forward(self, audio):
        frame = self.mimi.frame_size
        n_samples = torch._shape_as_tensor(audio)[-1]
        n_frames = torch.div(n_samples + frame - 1, frame, rounding_mode="floor")
        # Upstream pads to a whole number of frames with zeros (pad_for_conv1d). F.pad needs a
        # Python int, which the tracer would freeze, so pad one full frame and keep exactly
        # ceil(N / frame) * frame samples (index_select keeps the length dynamic).
        x = F.pad(audio, (0, frame)).index_select(-1, torch.arange(n_frames * frame))
        emb = self.mimi.encoder(x, model_state=None)
        (emb,) = self.mimi.encoder_transformer(emb, model_state=None)
        emb = self.mimi._to_framerate(emb)
        return F.linear(emb.transpose(-1, -2).to(torch.float32), self.speaker_proj_weight)


class MimiDecoder(nn.Module):
    def __init__(self, mimi, emb_std, emb_mean, spec):
        super().__init__()
        self.mimi, self.spec = mimi, spec
        self.register_buffer("emb_std", emb_std.clone())
        self.register_buffer("emb_mean", emb_mean.clone())

    def forward(self, latent, *states):
        ms = to_model_state(self.spec, states, self.mimi)
        audio = self.mimi.decode_from_latent(latent * self.emb_std + self.emb_mean, ms)
        return (audio, *from_model_state(self.spec, ms))


class TextConditioner(nn.Module):
    def __init__(self, conditioner):
        super().__init__()
        self.conditioner = conditioner

    def forward(self, token_ids):
        return self.conditioner(token_ids)


# ----------------------------------------------------------------- checks


def report(name: str, a, b, tol: float) -> None:
    a = a.detach().cpu().numpy() if isinstance(a, torch.Tensor) else np.asarray(a)
    b = b.detach().cpu().numpy() if isinstance(b, torch.Tensor) else np.asarray(b)
    assert a.shape == b.shape, f"{name}: shape {a.shape} vs {b.shape}"
    err = float(np.abs(a - b).max()) if a.size else 0.0
    scale = float(np.abs(a).max()) if a.size else 0.0
    status = "ok" if err <= tol * max(scale, 1.0) else "FAIL"
    print(f"    {name:40s} max|diff| {err:.2e} (max|ref| {scale:.2e})  {status}")
    if status == "FAIL":
        raise SystemExit(f"check failed: {name}")


def ort_run(path: Path, feeds: dict) -> list[np.ndarray]:
    sess = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    return sess.run(None, {k: (v.numpy() if isinstance(v, torch.Tensor) else v) for k, v in feeds.items()})


# ----------------------------------------------------------------- main


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--language", required=True, help="upstream config name, e.g. french, german, dutch")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--flow-cache", type=int, default=1000, help="FlowLM KV window (voice + text + frames)")
    ap.add_argument("--allow-no-voice-cloning", action="store_true",
                    help="accept the non-gated weights (to develop/check the exporter; voices won't clone)")
    ap.add_argument("--no-quantize", action="store_true")
    args = ap.parse_args()
    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)

    apply_patches(False)
    model = TTSModel.load_model(language=args.language)
    model.eval()
    if not model.has_voice_cloning and not args.allow_no_voice_cloning:
        raise SystemExit(
            "Got the weights *without* voice cloning: the gated repo kyutai/pocket-tts wasn't reachable.\n"
            "Accept its terms on huggingface.co, run `hf auth login`, and retry "
            "(or pass --allow-no-voice-cloning to test the exporter)."
        )
    cfg = model.config
    fl, mimi = model.flow_lm, model.mimi
    if fl.flow_type != "lsd":
        raise SystemExit(f"flow type {fl.flow_type!r}: sherpa-onnx's loop only does LSD")
    print(f"{args.language}: {sum(p.numel() for p in model.parameters()) / 1e6:.1f}M params, "
          f"{len(fl.transformer.layers)} layers, voice cloning: {model.has_voice_cloning}")

    flow_spec = state_spec(fl, "", {"*": args.flow_cache})
    mimi_ctx = {}
    for name, mod in mimi.named_modules():
        if isinstance(mod, attn_mod.StreamingMultiheadAttention):
            assert mod.context is not None, "Mimi attention without context window"
            mimi_ctx[name] = mod.context
    mimi_spec = state_spec(mimi, "", {**mimi_ctx, "*": max(mimi_ctx.values())})
    # get_state() looks states up by the names stamped by TTSModel, relative to flow_lm / mimi.
    for spec, root in ((flow_spec, fl), (mimi_spec, mimi)):
        names = dict(root.named_modules())
        assert all(names[e["module"]]._module_absolute_name == e["module"] for e in spec)

    rng = torch.Generator().manual_seed(0)
    voice = torch.randn(1, 1, 24000 * 3 + 777, generator=rng) * 0.1
    tokens = torch.randint(0, 4000, (1, 23), generator=rng)

    with torch.no_grad():
        # ---------- reference outputs from the untouched code
        apply_patches(False)
        ref_voice = model._encode_audio(voice)
        ref_text = fl.conditioner(tokens)
        voice2 = torch.randn(1, 1, 24000 * 5 + 1234, generator=rng) * 0.1  # lengths the trace never saw
        tokens2 = torch.randint(0, 4000, (1, 7), generator=rng)
        ref_voice2 = model._encode_audio(voice2)
        ref_text2 = fl.conditioner(tokens2)
        bos = fl.bos_before_voice.detach() if fl.insert_bos_before_voice else None
        prompt = torch.cat([bos, ref_voice], 1) if bos is not None else ref_voice
        ms = init_states(fl, 1, args.flow_cache)
        empty_seq = torch.empty(1, 0, fl.ldim)
        empty_txt = torch.empty(1, 0, fl.dim)
        latents_in = [torch.full((1, 1, fl.ldim), float("nan"))] + [torch.randn(1, 1, fl.ldim, generator=rng)
                                                                     for _ in range(4)]
        ref_main = []
        for seq, emb in [(empty_seq, prompt), (empty_seq, ref_text)] + [(l, empty_txt) for l in latents_in]:
            s = torch.where(torch.isnan(seq), fl.bos_emb, seq)
            o = fl.backbone(fl.input_linear(s), emb, s, ms)[:, -1]
            ref_main.append((o, fl.out_eos(o)))
            increment_steps(fl, ms, increment=seq.shape[1] + emb.shape[1])
        c0 = ref_main[-1][0]
        x0 = torch.randn(1, fl.ldim, generator=rng)
        st = (torch.zeros(1, 1), torch.ones(1, 1))
        ref_flow = fl.flow_net(c0, *st, x0)
        dec_lat = [torch.randn(1, n, fl.ldim, generator=rng) for n in (1, 3, 2, 15)]
        mstate = init_states(mimi, 1, 1000)
        ref_dec = []
        for lat in dec_lat:
            ref_dec.append(mimi.decode_from_latent(lat * fl.emb_std + fl.emb_mean, mstate))
            increment_steps(mimi, mstate, increment=lat.shape[1] * int(mimi.encoder_frame_rate / mimi.frame_rate))

        # ---------- patched torch wrappers must match
        apply_patches(True)
        w_main = FlowLMMain(fl, flow_spec).eval()
        w_flow = FlowLMFlow(fl.flow_net).eval()
        w_enc = MimiEncoder(mimi, fl.speaker_proj_weight).eval()
        w_dec = MimiDecoder(mimi, fl.emb_std, fl.emb_mean, mimi_spec).eval()
        w_txt = TextConditioner(fl.conditioner).eval()
        print("  patched torch vs original:")
        report("mimi_encoder", w_enc(voice), ref_voice, 1e-4)
        report("text_conditioner", w_txt(tokens), ref_text, 0)
        states = zero_states(flow_spec)
        main_feeds = []
        for i, (seq, emb) in enumerate([(empty_seq, prompt), (empty_seq, ref_text)] + [(l, empty_txt) for l in latents_in]):
            main_feeds.append((seq, emb, [s.clone() for s in states]))
            cond, eos, *states = w_main(seq, emb, *states)
            if i >= 1:
                report(f"flow_lm_main step {i} conditioning", cond, ref_main[i][0], 1e-4)
                report(f"flow_lm_main step {i} eos", eos, ref_main[i][1], 1e-4)
        report("flow_lm_flow", w_flow(c0, *st, x0), ref_flow, 1e-5)
        dstates = zero_states(mimi_spec)
        dec_feeds = []
        for i, lat in enumerate(dec_lat):
            dec_feeds.append((lat, [s.clone() for s in dstates]))
            audio, *dstates = w_dec(lat, *dstates)
            report(f"mimi_decoder call {i} ({lat.shape[1]} frames)", audio, ref_dec[i], 1e-4)

        # ---------- export
        print("  exporting:")

        def export(module, name, args_, in_names, out_names, dyn):
            path = out / f"{name}.onnx"
            torch.onnx.export(module, args_, str(path), dynamo=False, opset_version=OPSET,
                              input_names=in_names, output_names=out_names, dynamic_axes=dyn)
            onnx.checker.check_model(str(path))
            print(f"    {path.name}: {path.stat().st_size / 1e6:.1f} MB")
            return path

        fs = [e["input_name"] for e in flow_spec]
        fo = [e["output_name"] for e in flow_spec]
        p_main = export(w_main, "flow_lm_main", (empty_seq, prompt, *zero_states(flow_spec)),
                        ["sequence", "text_embeddings", *fs], ["conditioning", "eos_logit", *fo],
                        {"sequence": {1: "seq_len"}, "text_embeddings": {1: "text_len"}})
        p_flow = export(w_flow, "flow_lm_flow", (c0, *st, x0), ["c", "s", "t", "x"], ["flow_dir"],
                        {n: {0: "batch"} for n in ["c", "s", "t", "x", "flow_dir"]})
        p_enc = export(w_enc, "mimi_encoder", (voice,), ["audio"], ["latents"],
                       {"audio": {2: "audio_len"}, "latents": {1: "num_frames"}})
        ms_in = [e["input_name"] for e in mimi_spec]
        ms_out = [e["output_name"] for e in mimi_spec]
        p_dec = export(w_dec, "mimi_decoder", (dec_lat[1], *zero_states(mimi_spec)),
                       ["latent", *ms_in], ["audio_frame", *ms_out],
                       {"latent": {1: "seq_len"}, "audio_frame": {2: "num_samples"}})
        p_txt = export(w_txt, "text_conditioner", (tokens,), ["token_ids"], ["embeddings"],
                       {"token_ids": {1: "seq_len"}, "embeddings": {1: "seq_len"}})

        # ---------- onnxruntime must match too (other lengths than the traced ones)
        print("  onnxruntime vs original:")
        report("mimi_encoder (other length)", ort_run(p_enc, {"audio": voice2})[0], ref_voice2, 1e-3)
        report("text_conditioner (other length)", ort_run(p_txt, {"token_ids": tokens2})[0], ref_text2, 0)
        for i, (seq, emb, sts) in enumerate(main_feeds):
            o = ort_run(p_main, {"sequence": seq, "text_embeddings": emb, **dict(zip(fs, sts))})
            if i >= 1:
                report(f"flow_lm_main step {i} conditioning", o[0], ref_main[i][0], 1e-3)
        report("flow_lm_flow", ort_run(p_flow, {"c": c0, "s": st[0], "t": st[1], "x": x0})[0], ref_flow, 1e-4)
        for i, (lat, sts) in enumerate(dec_feeds):
            o = ort_run(p_dec, {"latent": lat, **dict(zip(ms_in, sts))})
            report(f"mimi_decoder call {i} ({lat.shape[1]} frames)", o[0], ref_dec[i], 1e-3)

    # ---------- int8 (MatMul/Gemm only: Kyutai's runtime never quantizes Mimi or the flow net,
    # so the decoder stays fp32; lm_flow int8 is offered but validate it by ear / ASR)
    if not args.no_quantize:
        for stem in ("flow_lm_main", "flow_lm_flow"):
            quantize_dynamic(str(out / f"{stem}.onnx"), str(out / f"{stem}_int8.onnx"),
                             weight_type=QuantType.QInt8, op_types_to_quantize=["MatMul", "Gemm"])
            print(f"    {stem}_int8.onnx: {(out / f'{stem}_int8.onnx').stat().st_size / 1e6:.1f} MB")

    # ---------- tokenizer, bos, bundle.json
    tok_path = str(cfg.flow_lm.lookup_table.tokenizer_path)
    if tok_path.split("@")[0].endswith(".json"):
        # sherpa needs SentencePiece pieces + scores; the repo ships the .model next to the .json.
        sp_path = tok_path.replace("tokenizer.json", "tokenizer.model")
        local = download_if_necessary(sp_path)
    else:
        local = download_if_necessary(tok_path)
    shutil.copyfile(local, out / "tokenizer.model")
    import sentencepiece as spm
    sp = spm.SentencePieceProcessor(model_file=str(out / "tokenizer.model"))
    probe = "Bonjour, ceci est un test. Guten Tag! ¿Qué tal? 3,14 € l'été."
    ids_model, ids_torch = sp.Encode(probe), fl.conditioner.tokenizer.encode(probe)
    print(f"  tokenizer.model == model's own tokenizer on a probe: {ids_model == ids_torch}")
    if ids_model != ids_torch:
        raise SystemExit("tokenizer.model disagrees with the checkpoint's tokenizer")

    if bos is not None:
        np.save(out / "bos_before_voice.npy", bos.numpy().astype(np.float32))
    bundle = {
        "schema_version": 2,
        "bundle_name": args.language,
        "language": args.language,
        "exported_by": "pocket_tts_export/export_onnx.py",
        "has_voice_cloning": bool(model.has_voice_cloning),
        "sample_rate": int(mimi.sample_rate),
        "frame_rate": float(mimi.frame_rate),
        "samples_per_frame": int(mimi.frame_size),
        "latent_dim": int(fl.ldim),
        "conditioning_dim": int(fl.dim),
        "tokenizer_file": "tokenizer.model",
        "insert_bos_before_voice": bool(fl.insert_bos_before_voice),
        "bos_before_voice_file": "bos_before_voice.npy" if bos is not None else None,
        "remove_semicolons": bool(cfg.remove_semicolons),
        "pad_with_spaces_for_short_inputs": bool(cfg.pad_with_spaces_for_short_inputs),
        "model_recommended_frames_after_eos": cfg.model_recommended_frames_after_eos,
        "default_temperature": float(cfg.default_temperature),
        "default_eos_threshold": float(cfg.default_eos_threshold),
        "max_token_per_chunk": 50,
        "flow_cache_length": args.flow_cache,
        "flow_lm_state_manifest": flow_spec,
        "mimi_state_manifest": mimi_spec,
        "predefined_voices": [],
    }
    (out / "bundle.json").write_text(json.dumps(bundle, indent=2) + "\n")
    print(f"done -> {out}")


if __name__ == "__main__":
    main()
