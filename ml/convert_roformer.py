"""Convert BS-RoFormer SW (6 stems) to a Core ML package for Backline.

Checkpoint
  BS-Rofo-SW-Fixed.ckpt  699,412,152 B
  sha256 24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e
  https://huggingface.co/FractalSurfer/BS-RoFormer-SW-6stem (mirror of the deleted
  jarredou/enerjazzer BS-ROFO-SW-Fixed; the yaml is byte-identical)
  BS-Rofo-SW-Fixed.yaml
  sha256 f9fada9f94e5ba2d2e4600196299459294bc5f532b314c209cc156ac63e4329b
Architecture reference
  ZFTurbo/Music-Source-Separation-Training models/bs_roformer/bs_roformer.py

Why a re-implementation (same reason as ml/convert_beat_this.py): the upstream module is built
from einops `rearrange`/`pack`/`unpack`, `rotary_embedding_torch` (whose `einsum('..., f -> ... f')`
hits apple/coremltools#2644) and 62-way python loops over variable-width band slices.
`RoformerCore` below is a dependency-free, numerically identical rewrite that
  - uses only reshape / permute / matmul (no einsum, no einops, no rotary_embedding_torch),
  - bakes the interleaved RoPE into constant cos/sin tables of static length,
  - batches the 62 band-split projections and the 6x62 mask-estimator MLPs into 7 grouped
    matmuls each (bands of equal width are contiguous in `freqs_per_bands`), which turns
    ~1900 tiny ops into ~100 big ones,
  - has fully static shapes.
The STFT / iSTFT and the complex-number handling stay out of the graph: they run in Swift with
vDSP (BacklineKit/Sources/RoformerSeparator.swift), exactly as for HTDemucs.

Converted graph
  spec  [1, 1151, 4100]      complex-as-channels STFT of one 588800-sample stereo chunk.
                             Last axis is (freq, chan, re/im) flattened: index = f*4 + s*2 + c,
                             f in 0..1024, s in 0..1 (L,R), c in 0..1 (re,im).
  ->
  out   [1, 6, 1151, 4100]   per-stem masked spectrogram, same last-axis layout, DC bin zeroed.
The final waveform per stem/channel is iSTFT(out[stem][:, f*4 + s*2 + {0,1}]).

Subcommands
  ref <song> [<song> ...]    original upstream code (needs --msst clone): writes
                             $ROFORMER_FIXTURES/<song>/{bass,drums,...}.wav plus
                             chunk fixtures spec.f32 / out.f32 for the parity check.
  convert                    builds RoformerCore, checks parity against the upstream module,
                             converts FP32 + FP16, checks Core ML parity, benchmarks on the GPU.
  compare <refdir> <swiftdir>  per-stem SNR of Swift+CoreML wavs against the PyTorch wavs.

Usage (own venv, never ml/.venv*)
  uv venv --python 3.11 /tmp/roformer/.venv
  uv pip install torch coremltools numpy pyyaml soundfile einops beartype rotary_embedding_torch
  python ml/convert_roformer.py ref  song.mp3 --msst /tmp/roformer/msst
  python ml/convert_roformer.py convert
  python ml/convert_roformer.py compare $ROFORMER_FIXTURES/Big_Rock /tmp/hq/Big_Rock
"""
import argparse
import json
import math
import os
import sys
import time

import numpy as np
import torch
import torch.nn.functional as F
from torch import nn

ROOT = os.path.dirname(os.path.abspath(__file__))
# Fixtures are reference audio and 113 MB tensors: they default OUTSIDE the repo so they can
# never be committed. (ml/fixtures_beat/ is gitignored; ml/fixtures_roformer/ is not, so do not
# point this inside ml/ unless that line is added to .gitignore first.)
FIX = os.environ.get("ROFORMER_FIXTURES", "/tmp/roformer/fixtures_roformer")
CKPT = os.environ.get("ROFORMER_CKPT", "/tmp/roformer/dl/BS-Rofo-SW-Fixed.ckpt")
YAML = os.environ.get("ROFORMER_YAML", "/tmp/roformer/dl/BS-Rofo-SW-Fixed.yaml")

# ---- everything the Swift side has to agree with -------------------------------------------
STEMS = ["bass", "drums", "other", "vocals", "guitar", "piano"]   # yaml training.instruments
CHUNK = 588_800          # audio.chunk_size
N_FFT = 2048             # model.stft_n_fft / stft_win_length
HOP = 512                # model.stft_hop_length
FRAMES = CHUNK // HOP + 1        # 1151, torch.stft(center=True)
BINS = N_FFT // 2 + 1            # 1025
FLAT = BINS * 2 * 2              # 4100 = bins * channels * (re,im)
DIM = 256
DEPTH = 12
HEADS = 8
DIM_HEAD = 64
NUM_OVERLAP = 2          # inference.num_overlap
ZERO_DC = True           # upstream BSRoformer default; see note in `convert`
FREQS_PER_BAND = (
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    12, 12, 12, 12, 12, 12, 12, 12,
    24, 24, 24, 24, 24, 24, 24, 24,
    48, 48, 48, 48, 48, 48, 48, 48,
    128, 129,
)
assert sum(FREQS_PER_BAND) == BINS and len(FREQS_PER_BAND) == 62
# per-band input width after stereo + complex interleaving
BAND_W = tuple(4 * f for f in FREQS_PER_BAND)


def band_groups():
    """Runs of equal-width bands: [(first_band, count, width), ...]. 7 groups for this config."""
    groups, i = [], 0
    while i < len(BAND_W):
        j = i
        while j < len(BAND_W) and BAND_W[j] == BAND_W[i]:
            j += 1
        groups.append((i, j - i, BAND_W[i]))
        i = j
    return groups


GROUPS = band_groups()


# ---------------------------------------------------------------------------------------------
# Trace-friendly rewrite
# ---------------------------------------------------------------------------------------------
class RMSNorm(nn.Module):
    """upstream: F.normalize(x, dim=-1, p=2) * sqrt(dim) * gamma"""

    def __init__(self, dim):
        super().__init__()
        self.scale = dim ** 0.5
        self.gamma = nn.Parameter(torch.ones(dim))

    def forward(self, x):
        n = torch.sqrt(torch.sum(x * x, dim=-1, keepdim=True)).clamp_min(1e-12)
        return x / n * (self.scale * self.gamma)


class FeedForward(nn.Module):
    """Same Sequential indices as upstream so the state dict loads unchanged (2/5 are dropout)."""

    def __init__(self, dim, mult=4):
        super().__init__()
        self.net = nn.Sequential(RMSNorm(dim), nn.Linear(dim, dim * mult), nn.GELU(),
                                 nn.Identity(), nn.Linear(dim * mult, dim), nn.Identity())

    def forward(self, x):
        return self.net(x)


def rope_tables(inv_freq: torch.Tensor, n: int):
    """rotary_embedding_torch: freqs = outer(pos, inv_freq) then repeat each element twice."""
    f = torch.arange(n, dtype=torch.float32)[:, None] * inv_freq[None, :].float()
    f = f.repeat_interleave(2, dim=-1)
    return f.cos(), f.sin()


def rotate_half(x, half: int):
    """Interleaved variant used by rotary_embedding_torch: (-x1, x0, -x3, x2, ...).
    `half` is passed in, never read off the tensor: every shape here must stay a python int or
    the trace emits aten::Int nodes that coremltools cannot fold (apple/coremltools#2644)."""
    a, b = x.unflatten(-1, (half, 2)).unbind(dim=-1)
    return torch.stack((-b, a), dim=-1).flatten(-2)


class Attention(nn.Module):
    """Gated MHA with interleaved RoPE on q and k. Input (batch, seq, dim), both static."""

    def __init__(self, dim, heads, dim_head, batch, seq, inv_freq, use_sdpa):
        super().__init__()
        self.heads, self.dim_head, self.use_sdpa = heads, dim_head, use_sdpa
        self.batch, self.seq = batch, seq
        self.norm = RMSNorm(dim)
        self.to_qkv = nn.Linear(dim, heads * dim_head * 3, bias=False)
        self.to_gates = nn.Linear(dim, heads)
        self.to_out = nn.Sequential(nn.Linear(heads * dim_head, dim, bias=False), nn.Identity())
        cos, sin = rope_tables(inv_freq, seq)
        self.register_buffer("cos", cos, persistent=False)      # (seq, dim_head)
        self.register_buffer("sin", sin, persistent=False)

    def forward(self, x):
        B, N, h, d = self.batch, self.seq, self.heads, self.dim_head
        x = self.norm(x)
        qkv = self.to_qkv(x).reshape(B, N, 3, h, d).permute(2, 0, 3, 1, 4)   # (3, B, h, N, d)
        q, k, v = qkv[0], qkv[1], qkv[2]
        q = q * self.cos + rotate_half(q, d // 2) * self.sin
        k = k * self.cos + rotate_half(k, d // 2) * self.sin
        if self.use_sdpa:
            out = F.scaled_dot_product_attention(q, k, v)
        else:
            att = torch.matmul(q, k.transpose(-1, -2)) * (d ** -0.5)
            out = torch.matmul(att.softmax(dim=-1), v)
        g = torch.sigmoid(self.to_gates(x)).permute(0, 2, 1).unsqueeze(-1)   # (B, h, N, 1)
        out = (out * g).permute(0, 2, 1, 3).reshape(B, N, h * d)
        return self.to_out(out)


class Transformer(nn.Module):
    """depth-1 upstream Transformer with norm_output=False."""

    def __init__(self, dim, batch, seq, inv_freq, use_sdpa):
        super().__init__()
        self.layers = nn.ModuleList([nn.ModuleList([
            Attention(dim, HEADS, DIM_HEAD, batch, seq, inv_freq, use_sdpa), FeedForward(dim)])])
        self.norm = nn.Identity()

    def forward(self, x):
        for attn, ff in self.layers:
            x = attn(x) + x
            x = ff(x) + x
        return self.norm(x)


class GroupedBandSplit(nn.Module):
    """62 (RMSNorm + Linear(width, dim)) bands as 7 batched matmuls. In (1, T, 4100) out (62, T, dim)."""

    def __init__(self, dim, frames):
        super().__init__()
        self.frames = frames
        self.gamma = nn.ParameterList()      # per group (count, width), already x sqrt(width)
        self.weight = nn.ParameterList()     # per group (count, width, dim)
        self.bias = nn.ParameterList()       # per group (count, 1, dim)
        for _, c, w in GROUPS:
            self.gamma.append(nn.Parameter(torch.ones(c, 1, w)))
            self.weight.append(nn.Parameter(torch.zeros(c, w, dim)))
            self.bias.append(nn.Parameter(torch.zeros(c, 1, dim)))

    def forward(self, spec):
        T = self.frames
        outs, off = [], 0
        for gi, (_, c, w) in enumerate(GROUPS):
            v = spec[0, :, off:off + c * w].reshape(T, c, w).permute(1, 0, 2)    # (c, T, w)
            off += c * w
            n = torch.sqrt(torch.sum(v * v, dim=-1, keepdim=True)).clamp_min(1e-12)
            v = v / n * self.gamma[gi]
            outs.append(torch.matmul(v, self.weight[gi]) + self.bias[gi])        # (c, T, dim)
        return torch.cat(outs, dim=0)                                            # (62, T, dim)


class GroupedMaskEstimator(nn.Module):
    """One stem's 62 MLP(dim -> 4*dim -> 2*width) + GLU heads, batched per width group.
    In (62, T, dim) out (T, 4100)."""

    def __init__(self, dim, frames, mlp_expansion_factor=4):
        super().__init__()
        self.frames = frames
        hidden = dim * mlp_expansion_factor
        self.w1 = nn.Parameter(torch.zeros(len(BAND_W), dim, hidden))
        self.b1 = nn.Parameter(torch.zeros(len(BAND_W), 1, hidden))
        self.w2 = nn.ParameterList()
        self.b2 = nn.ParameterList()
        for _, c, w in GROUPS:
            self.w2.append(nn.Parameter(torch.zeros(c, hidden, 2 * w)))
            self.b2.append(nn.Parameter(torch.zeros(c, 1, 2 * w)))

    def forward(self, x):
        h = torch.tanh(torch.matmul(x, self.w1) + self.b1)       # (62, T, hidden)
        T = self.frames
        outs = []
        for gi, (first, c, w) in enumerate(GROUPS):
            y = torch.matmul(h[first:first + c], self.w2[gi]) + self.b2[gi]      # (c, T, 2w)
            z = y[..., :w] * torch.sigmoid(y[..., w:])                           # nn.GLU(dim=-1)
            outs.append(z.permute(1, 0, 2).reshape(T, c * w))
        return torch.cat(outs, dim=-1)                                           # (T, 4100)


class RoformerCore(nn.Module):
    """spec (1, FRAMES, 4100) -> masked per-stem spectrogram (1, 6, FRAMES, 4100)."""

    def __init__(self, frames=FRAMES, use_sdpa=True, zero_dc=ZERO_DC, num_stems=6):
        super().__init__()
        inv_freq = 1.0 / (10000 ** (torch.arange(0, DIM_HEAD, 2).float() / DIM_HEAD))
        nb = len(BAND_W)
        self.frames = frames
        self.band_split = GroupedBandSplit(DIM, frames)
        self.layers = nn.ModuleList([nn.ModuleList([
            Transformer(DIM, nb, frames, inv_freq, use_sdpa),      # over time, batched over bands
            Transformer(DIM, frames, nb, inv_freq, use_sdpa),      # over bands, batched over time
        ]) for _ in range(DEPTH)])
        self.final_norm = RMSNorm(DIM)
        self.mask_estimators = nn.ModuleList([GroupedMaskEstimator(DIM, frames) for _ in range(num_stems)])
        dc = torch.ones(FLAT)
        if zero_dc:
            dc[:4] = 0.0        # freq bin 0, both channels, re+im
        self.register_buffer("dc", dc, persistent=False)
        self.num_stems = num_stems

    def forward(self, spec):
        x = self.band_split(spec)                     # (62, T, dim)
        for time_tr, freq_tr in self.layers:
            x = time_tr(x)                            # attends over T, batch = bands
            x = x.permute(1, 0, 2)                    # (T, 62, dim)
            x = freq_tr(x)                            # attends over bands, batch = T
            x = x.permute(1, 0, 2)                    # (62, T, dim)
        x = self.final_norm(x)
        mask = torch.stack([m(x) for m in self.mask_estimators], dim=0)   # (n, T, 4100)
        T = self.frames
        s = spec.reshape(T, BINS * 2, 2)
        m = mask.reshape(self.num_stems, T, BINS * 2, 2)
        sr, si = s[..., 0:1], s[..., 1:2]
        mr, mi = m[..., 0:1], m[..., 1:2]
        out = torch.cat((sr * mr - si * mi, sr * mi + si * mr), dim=-1)
        return (out.reshape(1, self.num_stems, T, FLAT) * self.dc)


# ---------------------------------------------------------------------------------------------
# weight loading
# ---------------------------------------------------------------------------------------------
def load_core(frames=FRAMES, use_sdpa=True, zero_dc=ZERO_DC) -> RoformerCore:
    sd = torch.load(CKPT, map_location="cpu", weights_only=True)
    sd = sd.get("state_dict", sd)
    core = RoformerCore(frames=frames, use_sdpa=use_sdpa, zero_dc=zero_dc)

    # the baked RoPE tables must match the checkpoint's own rotary freqs
    want = 1.0 / (10000 ** (torch.arange(0, DIM_HEAD, 2).float() / DIM_HEAD))
    rot = [v for k, v in sd.items() if k.endswith("rotary_embed.freqs")]
    assert len(rot) == 2 * DEPTH, len(rot)
    for v in rot:
        assert torch.allclose(v, want, atol=1e-7), "checkpoint uses non-default rotary freqs"

    # transformers + final_norm: identical module paths, load straight through
    direct = {k: v for k, v in sd.items()
              if (k.startswith("layers.") and "rotary_embed" not in k) or k.startswith("final_norm.")}
    missing, unexpected = core.load_state_dict(direct, strict=False)
    assert not unexpected, unexpected[:5]
    missing = [k for k in missing if not k.startswith(("band_split.", "mask_estimators."))]
    assert not missing, missing[:5]

    with torch.no_grad():
        # band split: stack per width group, fold sqrt(width) into gamma, transpose the Linear
        for gi, (first, c, w) in enumerate(GROUPS):
            g = torch.stack([sd[f"band_split.to_features.{first + j}.0.gamma"] for j in range(c)])
            core.band_split.gamma[gi].copy_((g * (w ** 0.5)).reshape(c, 1, w))
            wt = torch.stack([sd[f"band_split.to_features.{first + j}.1.weight"] for j in range(c)])
            core.band_split.weight[gi].copy_(wt.transpose(1, 2))
            bt = torch.stack([sd[f"band_split.to_features.{first + j}.1.bias"] for j in range(c)])
            core.band_split.bias[gi].copy_(bt.reshape(c, 1, DIM))
        for s in range(len(core.mask_estimators)):
            me = core.mask_estimators[s]
            p = f"mask_estimators.{s}.to_freqs"
            w1 = torch.stack([sd[f"{p}.{j}.0.0.weight"] for j in range(len(BAND_W))])
            me.w1.copy_(w1.transpose(1, 2))
            b1 = torch.stack([sd[f"{p}.{j}.0.0.bias"] for j in range(len(BAND_W))])
            me.b1.copy_(b1.unsqueeze(1))
            for gi, (first, c, w) in enumerate(GROUPS):
                w2 = torch.stack([sd[f"{p}.{first + j}.0.2.weight"] for j in range(c)])
                me.w2[gi].copy_(w2.transpose(1, 2))
                b2 = torch.stack([sd[f"{p}.{first + j}.0.2.bias"] for j in range(c)])
                me.b2[gi].copy_(b2.unsqueeze(1))
    return core.eval()


def load_upstream(msst: str, zero_dc=ZERO_DC):
    """The original BSRoformer module, for the parity reference."""
    import yaml
    sys.path.insert(0, msst)
    from models.bs_roformer.bs_roformer import BSRoformer
    cfg = yaml.load(open(YAML), Loader=yaml.UnsafeLoader)
    mc = dict(cfg["model"])
    for k in ("multi_stft_resolution_loss_weight", "multi_stft_resolutions_window_sizes",
              "multi_stft_hop_size", "multi_stft_normalized"):
        mc.pop(k, None)
    m = BSRoformer(**mc, zero_dc=zero_dc)
    sd = torch.load(CKPT, map_location="cpu", weights_only=True)
    m.load_state_dict(sd.get("state_dict", sd), strict=True)
    return m.eval(), cfg


# ---------------------------------------------------------------------------------------------
# STFT front/back end: must match BacklineKit/Sources/RoformerSeparator.swift
# ---------------------------------------------------------------------------------------------
def spec_of(chunk: torch.Tensor) -> torch.Tensor:
    """chunk (2, CHUNK) -> (1, FRAMES, 4100), last axis f*4 + s*2 + c."""
    z = torch.stft(chunk, n_fft=N_FFT, hop_length=HOP, win_length=N_FFT, normalized=False,
                   window=torch.hann_window(N_FFT), center=True, pad_mode="reflect",
                   return_complex=True)                             # (2, 1025, T)
    z = torch.view_as_real(z)                                       # (2, 1025, T, 2)
    z = z.permute(2, 1, 0, 3).reshape(1, z.shape[2], FLAT)          # (1, T, (f s c))
    return z.contiguous()


def istft_of(out: np.ndarray) -> np.ndarray:
    """out (6, FRAMES, 4100) -> (6, 2, CHUNK)."""
    t = torch.from_numpy(np.ascontiguousarray(out))
    n, T, _ = t.shape
    z = t.reshape(n, T, BINS, 2, 2).permute(0, 3, 2, 1, 4).reshape(n * 2, BINS, T, 2)
    y = torch.istft(torch.view_as_complex(z.contiguous()), n_fft=N_FFT, hop_length=HOP,
                    win_length=N_FFT, normalized=False, window=torch.hann_window(N_FFT),
                    center=True, length=CHUNK)
    return y.reshape(n, 2, CHUNK).numpy()


def windowing_array(chunk=CHUNK, overlap=NUM_OVERLAP):
    fade = chunk // 10
    w = np.ones(chunk, dtype=np.float32)
    w[-fade:] = np.linspace(1, 0, fade)
    w[:fade] = np.linspace(0, 1, fade)
    return w, fade


def demix(forward, mix: np.ndarray, n_stems=6, log=None):
    """utils.model_utils.demix 'generic' mode. `forward(chunk (2, CHUNK)) -> (n, 2, CHUNK)`."""
    step = CHUNK // NUM_OVERLAP
    border = CHUNK - step
    base, fade = windowing_array()
    n0 = mix.shape[-1]
    if n0 > 2 * border and border > 0:
        mix = np.pad(mix, ((0, 0), (border, border)), mode="reflect")
    n = mix.shape[-1]
    result = np.zeros((n_stems, 2, n), dtype=np.float32)
    counter = np.zeros(n, dtype=np.float32)
    i, ci = 0, 0
    starts = list(range(0, n, step))
    while i < n:
        part = mix[:, i:i + CHUNK]
        clen = part.shape[-1]
        mode = "reflect" if clen > CHUNK // 2 else "constant"
        part = np.pad(part, ((0, 0), (0, CHUNK - clen)), mode=mode)
        y = forward(torch.from_numpy(np.ascontiguousarray(part)))
        i += step
        w = base.copy()
        if i - step == 0:
            w[:fade] = 1
        elif i >= n:
            w[-fade:] = 1
        result[..., i - step:i - step + clen] += y[..., :clen] * w[:clen]
        counter[i - step:i - step + clen] += w[:clen]
        ci += 1
        if log:
            log(ci, len(starts))
    out = np.divide(result, counter, out=np.zeros_like(result), where=counter > 0)
    if n0 > 2 * border and border > 0:
        out = out[..., border:-border]
    return np.nan_to_num(out, copy=False, nan=0.0)


# ---------------------------------------------------------------------------------------------
# ref: upstream PyTorch, full song + chunk fixtures
# ---------------------------------------------------------------------------------------------
def load_audio_44k(path):
    import soundfile as sf
    try:
        x, sr = sf.read(path, dtype="float32", always_2d=True)
    except Exception:
        import librosa
        x, sr = librosa.load(path, sr=44100, mono=False)
        x = np.asarray(x, dtype=np.float32)
        return (x if x.ndim == 2 else np.stack([x, x])), 44100
    x = x.T
    if x.shape[0] == 1:
        x = np.concatenate([x, x], 0)
    assert sr == 44100, f"{path} is {sr} Hz; decode to 44.1 kHz first"
    return np.ascontiguousarray(x[:2]), sr


def cmd_ref(args):
    import soundfile as sf
    m, cfg = load_upstream(args.msst)
    assert cfg["audio"]["chunk_size"] == CHUNK and cfg["inference"]["num_overlap"] == NUM_OVERLAP
    assert list(cfg["training"]["instruments"]) == STEMS
    torch.set_num_threads(os.cpu_count())
    for song in args.songs:
        name = os.path.splitext(os.path.basename(song))[0]
        od = os.path.join(FIX, name)
        os.makedirs(od, exist_ok=True)
        mix, _ = load_audio_44k(song)
        if args.seconds:
            mix = mix[:, :int(args.seconds * 44100)]
        # The Swift side must start from the exact same samples, so hand it a float WAV rather
        # than letting AVFoundation re-decode the mp3 with a different decoder.
        sf.write(os.path.join(od, "mix.wav"), mix.T, 44100, subtype="FLOAT")
        print(f"[{name}] {mix.shape[-1] / 44100:.1f}s", flush=True)
        t0 = time.time()
        saved = {}

        def fwd(chunk):
            with torch.inference_mode():
                y = m(chunk.unsqueeze(0))[0].float().numpy()
            if not saved:          # keep the first chunk as the Core ML parity fixture
                sp = spec_of(chunk)
                with torch.inference_mode():
                    saved["spec"] = sp.numpy()
                    saved["out"] = core_from_upstream_spec(m, sp).numpy()
            return y

        def log(i, tot):
            el = time.time() - t0
            print(f"\r  chunk {i}  {el:.0f}s elapsed, {el / i:.1f}s/chunk", end="", flush=True)

        y = demix(fwd, mix, log=log)
        print(f"\n[{name}] {time.time() - t0:.0f}s total", flush=True)
        for s, name_s in enumerate(STEMS):
            sf.write(os.path.join(od, f"{name_s}.wav"), y[s].T, 44100, subtype="FLOAT")
        saved["spec"].astype("<f4").tofile(os.path.join(od, "spec.f32"))
        saved["out"].astype("<f4").tofile(os.path.join(od, "out.f32"))
        json.dump({"stems": STEMS, "frames": FRAMES, "flat": FLAT, "chunk": CHUNK,
                   "zero_dc": ZERO_DC, "seconds": mix.shape[-1] / 44100},
                  open(os.path.join(od, "meta.json"), "w"), indent=1)
        print("wrote", od, flush=True)


def core_from_upstream_spec(m, spec):
    """Run the upstream module's own band-split..mask path on our `spec` layout, so the
    fixture `out` is exactly what the Core ML graph must reproduce."""
    from einops import rearrange
    T = spec.shape[1]
    stft_repr = spec.reshape(T, BINS * 2, 2).permute(1, 0, 2).unsqueeze(0)   # (1, f*s, T, 2)
    x = rearrange(stft_repr, "b f t c -> b t (f c)")
    x = m.band_split(x)
    for time_tr, freq_tr in m.layers:
        x = rearrange(x, "b t f d -> (b f) t d")
        x = time_tr(x)
        x = rearrange(x, "(b f) t d -> (b t) f d", b=1)
        x = freq_tr(x)
        x = rearrange(x, "(b t) f d -> b t f d", b=1)
    x = m.final_norm(x)
    mask = torch.stack([fn(x) for fn in m.mask_estimators], dim=1)
    mask = rearrange(mask, "b n t (f c) -> b n f t c", c=2)
    sc = torch.view_as_complex(stft_repr.unsqueeze(1).contiguous()) * torch.view_as_complex(mask.contiguous())
    out = torch.view_as_real(sc)                       # (1, n, f*s, T, 2)
    out = out.permute(0, 1, 3, 2, 4).reshape(1, mask.shape[1], T, FLAT)
    if ZERO_DC:
        out = out.clone()
        out[..., :4] = 0.0
    return out[0]


# ---------------------------------------------------------------------------------------------
# convert
# ---------------------------------------------------------------------------------------------
def snr_db(ref, got):
    ref, got = np.asarray(ref, np.float64), np.asarray(got, np.float64)
    e = float(np.sum((ref - got) ** 2))
    return float("inf") if e == 0 else 10 * math.log10(float(np.sum(ref ** 2)) / e)


def cmd_convert(args):
    import coremltools as ct

    fixture = args.fixture
    if fixture is None:
        cands = [d for d in sorted(os.listdir(FIX)) if os.path.exists(os.path.join(FIX, d, "spec.f32"))] \
            if os.path.isdir(FIX) else []
        fixture = os.path.join(FIX, cands[0]) if cands else None
    if fixture:
        spec = torch.from_numpy(np.fromfile(os.path.join(fixture, "spec.f32"), "<f4")
                                .reshape(1, FRAMES, FLAT).copy())
        ref = np.fromfile(os.path.join(fixture, "out.f32"), "<f4").reshape(6, FRAMES, FLAT)
        print("fixture", fixture, "spec rms", float(spec.pow(2).mean().sqrt()))
    else:
        torch.manual_seed(0)
        spec, ref = torch.randn(1, FRAMES, FLAT) * 0.05, None
        print("no fixture; random input (parity vs upstream only)")

    results = {}
    # sdpa=True keeps the 62x8x1151x1151 attention matrix out of memory (2.6 GB per layer if
    # materialised) and converts to the fused ios18 op; the explicit-matmul variant is the fallback.
    core = load_core(use_sdpa=not args.no_sdpa)
    with torch.inference_mode():
        t0 = time.time()
        got = core(spec)[0].numpy()
        print(f"rewrite forward {time.time() - t0:.1f}s on cpu")
    if ref is not None:
        results["rewrite_vs_upstream"] = {
            "snr_db": round(snr_db(ref, got), 2),
            "max_abs": float(np.abs(ref - got).max()),
            "ref_absmax": float(np.abs(ref).max()),
        }
        print("rewrite vs upstream:", results["rewrite_vs_upstream"], flush=True)

    if args.upstream_check:
        m, _ = load_upstream(args.upstream_check)
        with torch.inference_mode():
            up = core_from_upstream_spec(m, spec).numpy()
        print("live upstream vs rewrite: snr", round(snr_db(up, got), 2), "max",
              float(np.abs(up - got).max()), flush=True)

    try:
        with torch.inference_mode():
            traced = torch.jit.trace(core, spec, check_trace=False)
        print("traced, sdpa =", not args.no_sdpa, flush=True)
    except Exception as e:
        print("trace failed, sdpa =", not args.no_sdpa, repr(e)[:400], flush=True)
        core = load_core(use_sdpa=args.no_sdpa)
        with torch.inference_mode():
            got = core(spec)[0].numpy()
            traced = torch.jit.trace(core, spec, check_trace=False)
        print("traced, sdpa =", args.no_sdpa, flush=True)
    del core

    for prec_name, prec in (("fp32", ct.precision.FLOAT32), ("fp16", ct.precision.FLOAT16)):
        if args.precision not in ("both", prec_name):
            continue
        path = args.out if args.precision == prec_name and args.out else \
            os.path.join(ROOT, f"BSRoformerSW{'' if prec_name == 'fp32' else '_fp16'}.mlpackage")
        t0 = time.time()
        ml = ct.convert(
            traced, convert_to="mlprogram",
            inputs=[ct.TensorType(name="spec", shape=(1, FRAMES, FLAT), dtype=np.float32)],
            outputs=[ct.TensorType(name="out", dtype=np.float32)],
            minimum_deployment_target=ct.target.macOS15,
            compute_precision=prec, compute_units=ct.ComputeUnit.CPU_AND_GPU,
        )
        conv_s = time.time() - t0
        ml.short_description = (
            "BS-RoFormer SW 6-stem core (STFT/iSTFT external). Input: complex-as-channels STFT of "
            f"a {CHUNK}-sample 44.1 kHz stereo chunk, (1, {FRAMES}, {FLAT}), last axis f*4+s*2+c. "
            f"Output: masked per-stem spectrogram (1, 6, {FRAMES}, {FLAT}), DC zeroed. Stems: "
            + ",".join(STEMS))
        ml.author = "BS-RoFormer SW checkpoint (jarredou/enerjazzer); architecture ZFTurbo/MSST; converted for Backline"
        ml.license = "unknown (upstream declares none)"
        ml.user_defined_metadata.update({
            "stems": ",".join(STEMS), "chunk_samples": str(CHUNK), "frames": str(FRAMES),
            "n_fft": str(N_FFT), "hop_length": str(HOP), "num_overlap": str(NUM_OVERLAP),
            "samplerate": "44100", "zero_dc": str(ZERO_DC),
            "ckpt_sha256": "24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e",
        })
        ml.save(path)
        size_mb = sum(os.path.getsize(os.path.join(dp, f))
                      for dp, _, fs in os.walk(path) for f in fs) / 2 ** 20
        print(f"saved {path} ({size_mb:.0f} MB, convert {conv_s:.0f}s)", flush=True)

        r = {"convert_s": round(conv_s), "size_mb": round(size_mb)}
        for cu_name, cu in (("CPU_AND_GPU", ct.ComputeUnit.CPU_AND_GPU),) + \
                           ((("ALL", ct.ComputeUnit.ALL),) if args.all_units else ()):
            mm = ct.models.MLModel(path, compute_units=cu)
            o = mm.predict({"spec": spec.numpy()})["out"][0]
            ts = []
            for _ in range(args.reps):
                t1 = time.time()
                mm.predict({"spec": spec.numpy()})
                ts.append(time.time() - t1)
            rr = {"s_per_chunk_median": round(float(np.median(ts)), 3),
                  "vs_rewrite_snr_db": round(snr_db(got, o), 2)}
            if ref is not None:
                rr["vs_upstream_snr_db"] = round(snr_db(ref, o), 2)
                wav_ref, wav_got = istft_of(ref), istft_of(o)
                rr["istft_snr_db"] = round(snr_db(wav_ref, wav_got), 2)
                rr["per_stem_istft_snr_db"] = {
                    STEMS[s]: round(snr_db(wav_ref[s], wav_got[s]), 1) for s in range(6)}
            r[cu_name] = rr
            print(f"  {prec_name} {cu_name}: {rr}", flush=True)
            del mm
        results[prec_name] = r

    os.makedirs(FIX, exist_ok=True)
    json.dump(results, open(os.path.join(FIX, "coreml_parity.json"), "w"), indent=1)
    print(json.dumps(results, indent=1))


# ---------------------------------------------------------------------------------------------
# compare: Swift output vs PyTorch output
# ---------------------------------------------------------------------------------------------
def cmd_compare(args):
    import soundfile as sf
    rows = {}
    for s in STEMS:
        a, _ = load_audio_44k(os.path.join(args.refdir, f"{s}.wav"))
        b, _ = load_audio_44k(os.path.join(args.gotdir, f"{s}.wav"))
        n = min(a.shape[-1], b.shape[-1])
        rows[s] = {"snr_db": round(snr_db(a[:, :n], b[:, :n]), 1),
                   "max_abs": float(np.abs(a[:, :n] - b[:, :n]).max()),
                   "n": n}
        print(f"{s:8s} snr {rows[s]['snr_db']:7.1f} dB  max abs {rows[s]['max_abs']:.2e}")
    print(json.dumps(rows))
    return rows


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("ref")
    p.add_argument("songs", nargs="+")
    p.add_argument("--msst", required=True, help="clone of ZFTurbo/Music-Source-Separation-Training")
    p.add_argument("--seconds", type=float, default=0)
    p.set_defaults(fn=cmd_ref)
    p = sub.add_parser("convert")
    p.add_argument("--fixture", default=None, help="$ROFORMER_FIXTURES/<song>")
    p.add_argument("--out", default=None)
    p.add_argument("--precision", choices=["fp32", "fp16", "both"], default="both")
    p.add_argument("--reps", type=int, default=3)
    p.add_argument("--all-units", action="store_true")
    p.add_argument("--no-sdpa", action="store_true", help="explicit matmul attention instead of sdpa")
    p.add_argument("--upstream-check", default=None, help="msst clone, re-runs upstream live")
    p.set_defaults(fn=cmd_convert)
    p = sub.add_parser("compare")
    p.add_argument("refdir")
    p.add_argument("gotdir")
    p.set_defaults(fn=cmd_compare)
    a = ap.parse_args()
    a.fn(a)
