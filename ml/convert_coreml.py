"""Convert Demucs htdemucs_6s to a Core ML package.

The STFT / iSTFT and complex-number handling are moved out of the graph (they run
in Swift with vDSP). The converted "core" takes:
    mix   [1, 2, 343980]         time-domain stereo segment (44.1 kHz)
    spec  [1, 4, 2048, 336]      complex-as-channels spectrogram of `mix`
                                 (channel order: L.re, L.im, R.re, R.im)
and returns:
    freq  [1, 6, 4, 2048, 336]   per-source complex-as-channels spectrogram
    time  [1, 6, 2, 343980]      per-source time-branch waveform
The final waveform per source is  time + iSTFT(freq).
"""
import argparse
import math

import numpy as np
import torch
from torch import nn
from einops import rearrange
import coremltools as ct

from demucs.pretrained import get_model


class Core(nn.Module):
    def __init__(self, h):
        super().__init__()
        self.h = h

    def forward(self, mix, mag):
        h = self.h
        x = mag
        B, C, Fq, T = x.shape
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) / (1e-5 + std)

        xt = mix
        meant = xt.mean(dim=(1, 2), keepdim=True)
        stdt = xt.std(dim=(1, 2), keepdim=True)
        xt = (xt - meant) / (1e-5 + stdt)

        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(h.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(h.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = h.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and h.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = h.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + h.freq_emb_scale * emb
            saved.append(x)

        if h.crosstransformer:
            if h.bottom_channels:
                b, c, f, t = x.shape
                x = rearrange(x, "b c f t-> b c (f t)")
                x = h.channel_upsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = h.channel_upsampler_t(xt)
            x, xt = h.crosstransformer(x, xt)
            if h.bottom_channels:
                x = rearrange(x, "b c f t-> b c (f t)")
                x = h.channel_downsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = h.channel_downsampler_t(xt)

        for idx, decode in enumerate(h.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))
            offset = h.depth - len(h.tdecoder)
            if idx >= offset:
                tdec = h.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)

        S = len(h.sources)
        x = x.view(B, S, -1, Fq, T)
        x = x * std[:, None] + mean[:, None]
        xt = xt.view(B, S, -1, mix.shape[-1])
        xt = xt * stdt[:, None] + meant[:, None]
        return x, xt


def spec_cac(h, mix):
    z = h._spec(mix)                      # [B, C, F, T] complex
    return h._magnitude(z)                # [B, C*2, F, T]


def main():
    torch.backends.mha.set_fastpath_enabled(False)
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="HTDemucs6s.mlpackage")
    ap.add_argument("--precision", choices=["fp32", "fp16"], default="fp32")
    ap.add_argument("--fixtures", default="fixtures")
    args = ap.parse_args()

    bag = get_model("htdemucs_6s")
    h = bag.models[0].eval()
    L = int(h.segment * h.samplerate)
    print("segment samples", L, "sources", h.sources)

    torch.manual_seed(0)
    mix = torch.randn(1, 2, L) * 0.1
    mag = spec_cac(h, mix)
    print("spec shape", tuple(mag.shape))

    core = Core(h).eval()
    with torch.no_grad():
        ref_x, ref_xt = core(mix, mag)
        # sanity: must equal the full model
        full = h(mix)
        zout = h._mask(None, ref_x)
        rec = h._ispec(zout, L) + ref_xt
        print("core vs full max abs diff", (rec - full).abs().max().item())

        traced = torch.jit.trace(core, (mix, mag), check_trace=False)

    precision = ct.precision.FLOAT32 if args.precision == "fp32" else ct.precision.FLOAT16
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="mix", shape=tuple(mix.shape), dtype=np.float32),
            ct.TensorType(name="spec", shape=tuple(mag.shape), dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="freq", dtype=np.float32),
            ct.TensorType(name="time", dtype=np.float32),
        ],
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )
    mlmodel.short_description = "HTDemucs 6-source core (STFT/iSTFT external). Sources: " + ",".join(h.sources)
    mlmodel.author = "Meta AI (Demucs, MIT license); converted for Backline"
    mlmodel.license = "MIT"
    mlmodel.user_defined_metadata["sources"] = ",".join(h.sources)
    mlmodel.user_defined_metadata["segment_samples"] = str(L)
    mlmodel.user_defined_metadata["samplerate"] = str(h.samplerate)
    mlmodel.save(args.out)
    print("saved", args.out)

    # Fixtures for validating the Swift STFT/iSTFT.
    import os
    os.makedirs(args.fixtures, exist_ok=True)
    mix.numpy().astype(np.float32).tofile(f"{args.fixtures}/mix.f32")
    mag.numpy().astype(np.float32).tofile(f"{args.fixtures}/spec.f32")
    with torch.no_grad():
        zout = h._mask(None, ref_x)
        ispec = h._ispec(zout, L)
    ref_x.numpy().astype(np.float32).tofile(f"{args.fixtures}/freq.f32")
    ispec.numpy().astype(np.float32).tofile(f"{args.fixtures}/ispec.f32")
    full.numpy().astype(np.float32).tofile(f"{args.fixtures}/full.f32")
    print("fixtures written")


if __name__ == "__main__":
    main()
