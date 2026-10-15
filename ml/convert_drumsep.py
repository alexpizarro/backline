"""Convert MDX23C DrumSep (5 stems, by jarredou) to a Core ML package.

Model: MDX23C / TFC-TDF-net v3 from ZFTurbo's Music-Source-Separation-Training.
    checkpoint  drumsep_5stems_mdx23c_jarredou.ckpt
                sha256 1f8e636fb674b88a52c8399fde9a4ebe2b72b065ca07eed4e03ab1c9f0bfb2e0
    config      config_mdx23c_drumsep2025.yaml
                sha256 d2962f43d6682e8ea84e77fb50a2680e4641ba1749ee95f8ea6e96bba3278944
    mirror      https://huggingface.co/dshdaaf/separation-models/tree/main/
                DRUMSEP/DRUMSEP-MDX23C_DrumSep_5stem_new_by_jarredou
    original    https://github.com/jarredou/models/releases/tag/DrumSep (repo deleted)

Same split as ml/convert_coreml.py: the STFT / iSTFT and all complex-number handling
stay out of the Core ML graph (they run in Swift with vDSP), so the converted "core" is
pure real-valued conv / linear / norm work with static shapes.

    input   spec  [1, 4, 1024, 1024]      complex-as-channels spectrogram of an
                                          11.876 s stereo chunk at 44.1 kHz
                                          (plane order: L.re, L.im, R.re, R.im)
    output  freq  [1, 5, 4, 1024, 1024]   per-part complex-as-channels spectrogram
                                          (parts: kick, snare, toms, hh, cymbals)

The part waveform is iSTFT(freq[part]). Unlike HTDemucs there is no time branch, and
unlike Demucs the STFT is *not* normalised (torch.stft(normalized=False)).

Usage:
    python convert_drumsep.py convert   --ckpt <ckpt> --config <yaml> --msst <repo> \
                                        --out DrumSepMDX23C.mlpackage --fixtures fixtures
    python convert_drumsep.py reference --ckpt <ckpt> --config <yaml> --msst <repo> \
                                        --wav drums.wav --outdir ref_stems
"""
import argparse
import os
import sys
import time

import numpy as np
import torch
import yaml
from ml_collections import ConfigDict


# ---------------------------------------------------------------------------- model


def load_net(msst_dir, config_path, ckpt_path, device="cpu"):
    """Builds TFC_TDF_net from the MSST clone and loads the checkpoint."""
    # Append (never insert at 0) so the stdlib keeps priority over the cloned repo.
    if msst_dir not in sys.path:
        sys.path.append(msst_dir)
    from models.mdx23c_tfc_tdf_v3 import TFC_TDF_net

    with open(config_path) as f:
        config = ConfigDict(yaml.load(f, Loader=yaml.FullLoader))
    net = TFC_TDF_net(config)
    state = torch.load(ckpt_path, map_location="cpu", weights_only=True)
    net.load_state_dict(state)
    net.eval().to(device)
    return net, config


class Core(torch.nn.Module):
    """TFC_TDF_net.forward with the STFT and iSTFT removed (spec in, spec out).

    All shapes are baked in at build time. Reading them off the tensor (as
    cac2cws / cws2cac do) emits aten::size + aten::Int nodes that the
    coremltools TorchScript frontend mis-handles, so every reshape here uses
    constants derived from the config instead.
    """

    def __init__(self, net, dim_f, frames):
        super().__init__()
        self.net = net
        k = net.num_subbands
        self.dim_f = dim_f
        self.frames = frames
        self.parts = net.num_target_instruments
        self.cac_c = 4                      # 2 channels x (re, im)
        self.cws_c = self.cac_c * k         # after cac2cws
        self.cws_f = dim_f // k

    def forward(self, spec):
        net = self.net
        F, T = self.dim_f, self.frames
        # cac2cws, static: [1, 4, F, T] -> [1, 4k, F/k, T]
        mix = x = spec.reshape(1, self.cws_c, self.cws_f, T)
        first_conv_out = x = net.first_conv(x)
        x = x.transpose(-1, -2)

        encoder_outputs = []
        for block in net.encoder_blocks:
            x = block.tfc_tdf(x)
            encoder_outputs.append(x)
            x = block.downscale(x)

        x = net.bottleneck_block(x)

        for block in net.decoder_blocks:
            x = block.upscale(x)
            x = torch.cat([x, encoder_outputs.pop()], 1)
            x = block.tfc_tdf(x)

        x = x.transpose(-1, -2)
        x = x * first_conv_out
        x = net.final_conv(torch.cat([mix, x], 1))
        # cws2cac then split the part axis, static:
        # [1, parts*4k, F/k, T] -> [1, parts*4, F, T] -> [1, parts, 4, F, T]
        x = x.reshape(1, self.parts * self.cac_c, F, T)
        return x.reshape(1, self.parts, self.cac_c, F, T)


# ------------------------------------------------------------------------- chunking
# Mirror of utils.model_utils.demix "generic" mode with batch_size = 1, which is what
# DrumSeparator.swift implements. batch_size > 1 shares one fade window across the
# whole batch (see the clone() comment in demix), so batch_size = 1 is both the exact
# and the better-sounding path.


def windowing_array(chunk, fade):
    w = np.ones(chunk, dtype=np.float32)
    w[-fade:] = np.linspace(1, 0, fade, dtype=np.float32)
    w[:fade] = np.linspace(0, 1, fade, dtype=np.float32)
    return w


def demix(net, config, mix, device, progress=False):
    """mix: float32 [2, n]. Returns float32 [parts, 2, n]."""
    parts = list(config.training.instruments)
    chunk = int(config.audio.chunk_size)
    overlap = int(config.inference.num_overlap)
    fade = chunk // 10
    step = chunk // overlap
    border = chunk - step
    n0 = mix.shape[-1]

    x = torch.from_numpy(mix)
    if n0 > 2 * border and border > 0:
        x = torch.nn.functional.pad(x[None], (border, border), mode="reflect")[0]
    padded = x.shape[-1]

    win = torch.from_numpy(windowing_array(chunk, fade))
    result = torch.zeros((len(parts), 2, padded), dtype=torch.float32)
    counter = torch.zeros(padded, dtype=torch.float32)

    i = 0
    t0 = time.time()
    with torch.inference_mode():
        while i < padded:
            part = x[:, i:i + chunk]
            seg = part.shape[-1]
            mode = "reflect" if seg > chunk // 2 else "constant"
            part = torch.nn.functional.pad(part[None], (0, chunk - seg), mode=mode)[0]
            out = net(part[None].to(device)).to("cpu", torch.float32)[0]

            w = win.clone()
            i += step
            if i - step == 0:
                w[:fade] = 1
            elif i >= padded:
                w[-fade:] = 1

            result[..., i - step:i - step + seg] += out[..., :seg] * w[:seg]
            counter[i - step:i - step + seg] += w[:seg]
            if progress:
                print(f"  chunk at {i - step} ({seg} samples) {time.time() - t0:.1f}s", flush=True)

    result = result / counter
    if n0 > 2 * border and border > 0:
        result = result[..., border:-border]
    return parts, result.numpy()


# ------------------------------------------------------------------------- commands


def cmd_convert(args):
    import coremltools as ct

    net, config = load_net(args.msst, args.config, args.ckpt)
    parts = list(config.training.instruments)
    chunk = int(config.audio.chunk_size)
    n_fft = int(config.audio.n_fft)
    hop = int(config.audio.hop_length)
    dim_f = int(config.audio.dim_f)
    frames = chunk // hop + 1          # torch.stft(center=True) frame count
    print(f"parts {parts}  chunk {chunk}  n_fft {n_fft}  hop {hop}  dim_f {dim_f}  frames {frames}")

    torch.manual_seed(0)
    mix = torch.randn(1, 2, chunk) * 0.05
    with torch.inference_mode():
        spec = net.stft(mix)
    assert tuple(spec.shape) == (1, 4, dim_f, frames), spec.shape

    core = Core(net, dim_f, frames).eval()
    with torch.inference_mode():
        ref = core(spec)
        # The core plus an external STFT/iSTFT must equal the unmodified model.
        full = net(mix)
        rec = net.stft.inverse(ref)
        err = (rec - full).abs().max().item()
        print(f"core + external STFT vs full model: max abs diff {err:.3e}")
        assert err < 1e-5, err
        traced = torch.jit.trace(core, (spec,), check_trace=False)

    precision = {"fp32": ct.precision.FLOAT32, "fp16": ct.precision.FLOAT16}[args.precision]
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="spec", shape=tuple(spec.shape), dtype=np.float32)],
        outputs=[ct.TensorType(name="freq", dtype=np.float32)],
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )
    mlmodel.short_description = (
        "MDX23C DrumSep 5-stem core (STFT/iSTFT external). Parts: " + ",".join(parts)
    )
    mlmodel.author = "jarredou (MDX23C DrumSep); architecture ZFTurbo; converted for Backline"
    mlmodel.license = "CC BY-NC-SA 4.0 (research/personal use)"
    md = mlmodel.user_defined_metadata
    md["parts"] = ",".join(parts)
    md["chunk_samples"] = str(chunk)
    md["n_fft"] = str(n_fft)
    md["hop_length"] = str(hop)
    md["dim_f"] = str(dim_f)
    md["frames"] = str(frames)
    md["num_overlap"] = str(int(config.inference.num_overlap))
    md["samplerate"] = str(int(config.audio.sample_rate))
    mlmodel.save(args.out)
    print("saved", args.out)

    if args.fixtures:
        os.makedirs(args.fixtures, exist_ok=True)
        with torch.inference_mode():
            wave = net.stft.inverse(ref)
        mix.numpy().astype(np.float32).tofile(f"{args.fixtures}/mix.f32")
        spec.numpy().astype(np.float32).tofile(f"{args.fixtures}/spec.f32")
        ref.numpy().astype(np.float32).tofile(f"{args.fixtures}/freq.f32")
        wave.numpy().astype(np.float32).tofile(f"{args.fixtures}/wave.f32")
        with open(f"{args.fixtures}/shapes.txt", "w") as f:
            f.write(f"mix {tuple(mix.shape)}\nspec {tuple(spec.shape)}\n"
                    f"freq {tuple(ref.shape)}\nwave {tuple(wave.shape)}\n")
        print("fixtures written to", args.fixtures)


def cmd_reference(args):
    import soundfile as sf

    device = args.device
    net, config = load_net(args.msst, args.config, args.ckpt, device=device)
    audio, sr = sf.read(args.wav, dtype="float32", always_2d=True)
    assert sr == int(config.audio.sample_rate), f"{sr} != {config.audio.sample_rate}"
    mix = np.ascontiguousarray(audio.T)
    if mix.shape[0] == 1:
        mix = np.repeat(mix, 2, axis=0)
    print(f"{args.wav}: {mix.shape[1]} samples ({mix.shape[1] / sr:.1f} s) on {device}")

    t0 = time.time()
    parts, out = demix(net, config, mix, device, progress=args.progress)
    print(f"demix took {time.time() - t0:.1f}s")

    os.makedirs(args.outdir, exist_ok=True)
    for i, name in enumerate(parts):
        sf.write(f"{args.outdir}/{name}.wav", out[i].T, sr, subtype="FLOAT")
    rest = mix - out.sum(axis=0)
    sf.write(f"{args.outdir}/rest.wav", rest.T, sr, subtype="FLOAT")
    print("wrote", parts, "+ rest to", args.outdir)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--ckpt", required=True)
        p.add_argument("--config", required=True)
        p.add_argument("--msst", required=True, help="clone of ZFTurbo/Music-Source-Separation-Training")

    c = sub.add_parser("convert")
    common(c)
    c.add_argument("--out", default="DrumSepMDX23C.mlpackage")
    c.add_argument("--precision", choices=["fp32", "fp16"], default="fp32")
    c.add_argument("--fixtures", default="")
    c.set_defaults(func=cmd_convert)

    r = sub.add_parser("reference")
    common(r)
    r.add_argument("--wav", required=True)
    r.add_argument("--outdir", required=True)
    r.add_argument("--device", default="cpu", choices=["cpu", "mps"])
    r.add_argument("--progress", action="store_true")
    r.set_defaults(func=cmd_reference)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
