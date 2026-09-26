"""
Convert Beat This! (Foscarin, Schlueter, Widmer, ISMIR 2024; MIT) to Core ML for Backline.

Why a re-implementation: the upstream model uses einops rearranges, rotary_embedding_torch
(einsum '..., f -> ... f' hits apple/coremltools#2644, plus dynamic int casts) and dynamic shapes.
`BeatThisStatic` below is a dependency-free, numerically identical rewrite that:
  - uses only reshape/permute/matmul (no einsum, no einops),
  - implements the (interleaved) rotary embedding with precomputed real cos/sin tables and a
    fixed 32x32 "rotate_half" matrix (no complex ops, no caches),
  - has fully static shapes: input mel (1, 1500, 128) -> beat/downbeat logits (1, 1500),
  - folds nothing by hand (BatchNorm eval + GELU(erf) are converted natively).
It loads the upstream Lightning checkpoint state_dict directly (small0 or final0).

Subcommands
  fixture  (run with /tmp/mirtest/.venv: needs beat_this, torchaudio, soxr, soundfile)
           -> writes ml/fixtures_beat/*.f32 (audio -> mel -> reference logits from the
              ORIGINAL beat_this code) and checks the rewrite against the original model.
  convert  (run with ml/.venv-convert: torch 2.7 + coremltools 9)
           -> builds BeatThisStatic, checks parity vs fixture logits, converts to
              ml/BeatThis_{small,final}.mlpackage (FP32 and FP16), checks Core ML parity,
              benchmarks ms per 1500-frame (30 s) chunk on CPU_AND_GPU.

Usage
  /tmp/mirtest/.venv/bin/python ml/convert_beat_this.py fixture
  ml/.venv-convert/bin/python   ml/convert_beat_this.py convert
"""
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
FIX = os.path.join(ROOT, "fixtures_beat")
CKPT_DIR = os.path.expanduser("~/.cache/torch/hub/checkpoints")
T = 1500  # frames per chunk (30 s at 50 fps), what the model was trained on
# Any song works as a parity fixture; set BEAT_FIXTURE_SONG to a local audio file you own.
FIXTURE_SONG = os.environ.get("BEAT_FIXTURE_SONG", os.path.join(ROOT, "fixture.mp3"))
FIXTURE_START_S = 60.0


# ----------------------------------------------------------------------------------------------
# Trace-friendly model
# ----------------------------------------------------------------------------------------------
class RMSNorm(nn.Module):
    # upstream: F.normalize(x, dim=-1) * sqrt(dim) * gamma
    def __init__(self, dim):
        super().__init__()
        self.scale = dim ** 0.5
        self.gamma = nn.Parameter(torch.ones(dim))

    def forward(self, x):
        n = torch.sqrt(torch.sum(x * x, dim=-1, keepdim=True)).clamp_min(1e-12)
        return x / n * (self.scale * self.gamma)


class FeedForward(nn.Module):
    def __init__(self, dim, mult=4):
        super().__init__()
        self.net = nn.Sequential(RMSNorm(dim), nn.Linear(dim, dim * mult), nn.GELU(),
                                 nn.Identity(), nn.Linear(dim * mult, dim), nn.Identity())

    def forward(self, x):
        return self.net(x)


def rope_tables(inv_freq: torch.Tensor, n: int):
    pos = torch.arange(n, dtype=torch.float32)
    f = pos[:, None] * inv_freq[None, :].float()          # (n, d/2)
    f = f.repeat_interleave(2, dim=-1)                      # (n, d) interleaved [f0 f0 f1 f1 ...]
    return f.cos(), f.sin()


def rotate_half_matrix(d):
    # interleaved rotate_half: out[2i] = -x[2i+1], out[2i+1] = x[2i]  ==  x @ R
    R = torch.zeros(d, d)
    for i in range(d // 2):
        R[2 * i + 1, 2 * i] = -1.0
        R[2 * i, 2 * i + 1] = 1.0
    return R


class Attention(nn.Module):
    """Gated MHA with interleaved RoPE on q,k. Input (B, N, C)."""

    def __init__(self, dim, heads, dim_head, seq_len, inv_freq, use_sdpa):
        super().__init__()
        self.heads, self.dim_head, self.use_sdpa = heads, dim_head, use_sdpa
        self.norm = RMSNorm(dim)
        self.to_qkv = nn.Linear(dim, heads * dim_head * 3, bias=False)
        self.to_gates = nn.Linear(dim, heads)
        self.to_out = nn.Sequential(nn.Linear(heads * dim_head, dim, bias=False), nn.Identity())
        cos, sin = rope_tables(inv_freq, seq_len)
        self.register_buffer("cos", cos, persistent=False)   # (N, d)
        self.register_buffer("sin", sin, persistent=False)
        self.register_buffer("rot", rotate_half_matrix(dim_head), persistent=False)

    def forward(self, x):
        B, N, _ = x.shape
        h, d = self.heads, self.dim_head
        x = self.norm(x)
        qkv = self.to_qkv(x).reshape(B, N, 3, h, d).permute(2, 0, 3, 1, 4)  # (3, B, h, N, d)
        q, k, v = qkv[0], qkv[1], qkv[2]
        q = q * self.cos + torch.matmul(q, self.rot) * self.sin
        k = k * self.cos + torch.matmul(k, self.rot) * self.sin
        if self.use_sdpa:
            out = F.scaled_dot_product_attention(q, k, v)
        else:
            att = torch.matmul(q, k.transpose(-1, -2)) * (d ** -0.5)
            out = torch.matmul(att.softmax(dim=-1), v)
        g = torch.sigmoid(self.to_gates(x)).permute(0, 2, 1).unsqueeze(-1)  # (B, h, N, 1)
        out = (out * g).permute(0, 2, 1, 3).reshape(B, N, h * d)
        return self.to_out(out)


class PartialFT(nn.Module):
    def __init__(self, dim, n_freq, n_time, inv_freq, use_sdpa):
        super().__init__()
        heads = dim // 32
        self.attnF = Attention(dim, heads, 32, n_freq, inv_freq, use_sdpa)
        self.ffF = FeedForward(dim)
        self.attnT = Attention(dim, heads, 32, n_time, inv_freq, use_sdpa)
        self.ffT = FeedForward(dim)

    def forward(self, x):                       # (1, c, f, t)
        x = x[0].permute(2, 1, 0)               # (t, f, c)   == "(b t) f c"
        x = x + self.attnF(x)
        x = x + self.ffF(x)
        x = x.permute(1, 0, 2)                  # (f, t, c)   == "(b f) t c"
        x = x + self.attnT(x)
        x = x + self.ffT(x)
        return x.permute(2, 0, 1).unsqueeze(0)  # (1, c, f, t)


class FrontendBlock(nn.Module):
    def __init__(self, cin, cout, n_freq, n_time, inv_freq, use_sdpa):
        super().__init__()
        self.partial = PartialFT(cin, n_freq, n_time, inv_freq, use_sdpa)
        self.conv2d = nn.Conv2d(cin, cout, (2, 3), (2, 1), (0, 1), bias=False)
        self.norm = nn.BatchNorm2d(cout)
        self.act = nn.GELU()

    def forward(self, x):
        return self.act(self.norm(self.conv2d(self.partial(x))))


class BeatThisStatic(nn.Module):
    def __init__(self, transformer_dim=512, n_layers=6, stem_dim=32, n_time=T, use_sdpa=False):
        super().__init__()
        inv_freq = 1.0 / (10000 ** (torch.arange(0, 32, 2)[:16].float() / 32))
        self.bn1d = nn.BatchNorm1d(128)
        self.stem_conv = nn.Conv2d(1, stem_dim, (4, 3), (4, 1), (0, 1), bias=False)
        self.bn2d = nn.BatchNorm2d(stem_dim)
        self.stem_act = nn.GELU()
        blocks, dim, nf = [], stem_dim, 32
        for _ in range(3):
            blocks.append(FrontendBlock(dim, dim * 2, nf, n_time, inv_freq, use_sdpa))
            dim *= 2
            nf //= 2
        self.blocks = nn.ModuleList(blocks)
        self.linear = nn.Linear(dim * nf, transformer_dim)
        heads = transformer_dim // 32
        self.layers = nn.ModuleList([nn.ModuleList([
            Attention(transformer_dim, heads, 32, n_time, inv_freq, use_sdpa),
            FeedForward(transformer_dim)]) for _ in range(n_layers)])
        self.norm = RMSNorm(transformer_dim)
        self.head = nn.Linear(transformer_dim, 2)

    def forward(self, mel):                     # (1, T, 128)
        x = self.bn1d(mel.permute(0, 2, 1))     # (1, 128, T)
        x = self.stem_act(self.bn2d(self.stem_conv(x.unsqueeze(1))))  # (1, 32, 32, T)
        for b in self.blocks:
            x = b(x)                            # -> (1, 256, 4, T)
        B, C, Fq, Tt = x.shape
        x = x.permute(0, 3, 1, 2).reshape(B, Tt, C * Fq)   # "b c f t -> b t (c f)"
        x = self.linear(x)
        for attn, ff in self.layers:
            x = attn(x) + x
            x = ff(x) + x
        x = self.head(self.norm(x))             # (1, T, 2)
        down = x[..., 1]
        beat = x[..., 0] + down                 # SumHead
        return beat, down


def upstream_key_map(k: str) -> str | None:
    """Map upstream BeatThis state_dict key -> BeatThisStatic key (None = drop)."""
    if k.startswith("model."):
        k = k[len("model."):]
    if "rotary_embed" in k or k.endswith("num_batches_tracked"):
        return None
    k = k.replace("frontend.stem.bn1d.", "bn1d.").replace("frontend.stem.conv2d.", "stem_conv.")
    k = k.replace("frontend.stem.bn2d.", "bn2d.").replace("frontend.blocks.", "blocks.")
    k = k.replace("frontend.linear.", "linear.").replace("transformer_blocks.layers.", "layers.")
    k = k.replace("transformer_blocks.norm.", "norm.").replace("task_heads.beat_downbeat_lin.", "head.")
    return k


def load_static(name: str, use_sdpa=False) -> BeatThisStatic:
    ck = torch.load(os.path.join(CKPT_DIR, f"beat_this-{name}.ckpt"), map_location="cpu", weights_only=True)
    hp = ck["hyper_parameters"]
    assert hp.get("spect_dim", 128) == 128 and hp.get("head_dim", 32) == 32 and hp.get("stem_dim", 32) == 32
    m = BeatThisStatic(transformer_dim=hp["transformer_dim"], n_layers=hp["n_layers"], use_sdpa=use_sdpa)
    sd = {}
    for k, v in ck["state_dict"].items():
        nk = upstream_key_map(k)
        if nk is not None:
            sd[nk] = v
    missing, unexpected = m.load_state_dict(sd, strict=False)
    missing = [k for k in missing if not k.endswith(("cos", "sin", "rot"))]
    assert not missing and not unexpected, (missing, unexpected)
    # rotary freqs in the checkpoint must equal the default ones we bake into cos/sin
    rf = [v for k, v in ck["state_dict"].items() if k.endswith("rotary_embed.freqs")][0]
    assert torch.allclose(rf, 1.0 / (10000 ** (torch.arange(0, 32, 2)[:16].float() / 32)))
    return m.eval()


# ----------------------------------------------------------------------------------------------
# fixture: original beat_this pipeline -> reference tensors
# ----------------------------------------------------------------------------------------------
def save_f32(name, arr):
    arr = np.ascontiguousarray(arr, dtype="<f4")
    arr.tofile(os.path.join(FIX, name))
    return list(arr.shape)


def cmd_fixture():
    import soundfile as sf
    import soxr
    from beat_this.inference import load_model
    from beat_this.preprocessing import LogMelSpect
    from beat_this.model.postprocessor import Postprocessor
    import torchaudio

    os.makedirs(FIX, exist_ok=True)
    from beat_this.preprocessing import load_audio
    wav, sr = load_audio(FIXTURE_SONG)   # beat_this loader (falls back to soundfile/libsndfile mp3)
    mono = wav.mean(1) if wav.ndim == 2 else wav
    a = int(FIXTURE_START_S * sr)
    n_src = int(math.ceil((T - 1) * 441 * sr / 22050)) + 4096
    x22 = soxr.resample(mono[a:a + n_src], in_rate=sr, out_rate=22050)
    n = (T - 1) * 441                                 # center=True -> 1 + n//441 = 1500 frames
    x22 = x22[:n].astype(np.float32)
    shapes = {"audio_22050.f32": save_f32("audio_22050.f32", x22)}

    lms = LogMelSpect()
    mel = lms(torch.from_numpy(x22))                  # (1500, 128)
    assert mel.shape == (T, 128), mel.shape
    shapes["mel.f32"] = save_f32("mel.f32", mel.numpy())
    fb = lms.spect_class.mel_scale.fb                 # (513, 128)
    shapes["mel_fbank_513x128.f32"] = save_f32("mel_fbank_513x128.f32", fb.numpy())
    # intermediate: normalized magnitude STFT (frames x 513) so a Swift port can check each stage
    win = torch.hann_window(1024)
    st = torch.stft(torch.from_numpy(x22), 1024, 441, window=win, center=True, pad_mode="reflect",
                    normalized=True, return_complex=True).abs().T
    shapes["stft_mag_1500x513.f32"] = save_f32("stft_mag_1500x513.f32", st.numpy())
    chk = torch.log1p(1000 * (st @ fb))
    print("mel recompute max diff", float((chk - mel).abs().max()))

    report = {}
    for name in ["small0", "final0"]:
        orig = load_model(os.path.join(CKPT_DIR, f"beat_this-{name}.ckpt"), "cpu")
        with torch.inference_mode():
            o = orig(mel.unsqueeze(0))
            ob, od = o["beat"][0].numpy(), o["downbeat"][0].numpy()
            st_m = load_static(name)
            sb, sdb = st_m(mel.unsqueeze(0))
            sb2, sdb2 = load_static(name, use_sdpa=True)(mel.unsqueeze(0))
        tag = name.rstrip("0")
        shapes[f"beat_logits_{tag}.f32"] = save_f32(f"beat_logits_{tag}.f32", ob)
        shapes[f"downbeat_logits_{tag}.f32"] = save_f32(f"downbeat_logits_{tag}.f32", od)
        pb, pd = Postprocessor("minimal")(torch.from_numpy(ob), torch.from_numpy(od))
        report[name] = {
            "rewrite_vs_upstream_max_abs_beat": float(np.abs(sb[0].numpy() - ob).max()),
            "rewrite_vs_upstream_max_abs_downbeat": float(np.abs(sdb[0].numpy() - od).max()),
            "rewrite_sdpa_vs_upstream_max_abs_beat": float(np.abs(sb2[0].numpy() - ob).max()),
            "beats_s": [round(float(v), 4) for v in pb], "downbeats_s": [round(float(v), 4) for v in pd],
        }
        print(name, {k: v for k, v in report[name].items() if "max" in k}, "beats", len(pb), "downbeats", len(pd))
    meta = {
        "source": f"{os.path.basename(FIXTURE_SONG)} from {FIXTURE_START_S}s, libsndfile decode (float64), mean of channels, "
                  f"soxr.resample(HQ default) to 22050 Hz, first {(T - 1) * 441} samples",
        "dtype": "little-endian float32, row-major (C order)",
        "shapes": shapes,
        "mel": "torchaudio MelSpectrogram(sr=22050,n_fft=1024,win=1024,hop=441,hann periodic,center=True reflect-pad 512,"
               "normalized='frame_length' i.e. |STFT|/sqrt(1024), power=1, f_min=30,f_max=11000,n_mels=128,"
               "mel_scale='slaney', norm=None) -> log1p(1000*x); layout (frames, 128)",
        "reference": report,
    }
    json.dump(meta, open(os.path.join(FIX, "fixture.json"), "w"), indent=1)
    print("wrote", FIX)


# ----------------------------------------------------------------------------------------------
# convert: static model -> Core ML, parity + timing
# ----------------------------------------------------------------------------------------------
def load_f32(name, shape):
    return np.fromfile(os.path.join(FIX, name), dtype="<f4").reshape(shape)


def cmd_convert():
    import coremltools as ct

    mel = load_f32("mel.f32", (T, 128))
    x = torch.from_numpy(mel).unsqueeze(0)
    results = {}
    variants = sys.argv[2:] or ["small0", "final0"]
    for name in variants:
        tag = name.rstrip("0")
        ref_b = load_f32(f"beat_logits_{tag}.f32", (T,))
        ref_d = load_f32(f"downbeat_logits_{tag}.f32", (T,))
        for use_sdpa in (True, False):
            m = load_static(name, use_sdpa=use_sdpa)
            with torch.no_grad():
                tb, td = m(x)
            print(f"[{name}] torch-{torch.__version__} rewrite(sdpa={use_sdpa}) vs upstream: "
                  f"beat {np.abs(tb[0].numpy() - ref_b).max():.2e} downbeat {np.abs(td[0].numpy() - ref_d).max():.2e}")
            try:
                with torch.no_grad():
                    traced = torch.jit.trace(m, x)
                break
            except Exception as e:  # pragma: no cover
                print("trace failed", use_sdpa, e)
        for prec_name, prec in (("fp32", ct.precision.FLOAT32), ("fp16", ct.precision.FLOAT16)):
            t0 = time.time()
            ml = ct.convert(traced, convert_to="mlprogram",
                            inputs=[ct.TensorType(name="mel", shape=(1, T, 128), dtype=np.float32)],
                            outputs=[ct.TensorType(name="beat", dtype=np.float32),
                                     ct.TensorType(name="downbeat", dtype=np.float32)],
                            minimum_deployment_target=ct.target.macOS15,
                            compute_precision=prec, compute_units=ct.ComputeUnit.CPU_AND_GPU)
            conv_s = time.time() - t0
            ml.short_description = (f"Beat This! {name} (Foscarin et al. 2024, MIT). Input: log-mel (1,1500,128) "
                                    f"@50 fps; outputs beat/downbeat logits (1,1500). sdpa={use_sdpa} {prec_name}")
            suffix = "" if prec_name == "fp32" else "_fp16"
            path = os.path.join(ROOT, f"BeatThis_{'small' if tag == 'small' else 'final'}{suffix}.mlpackage")
            ml.save(path)
            for cu_name, cu in (("CPU_AND_GPU", ct.ComputeUnit.CPU_AND_GPU), ("CPU_ONLY", ct.ComputeUnit.CPU_ONLY),
                                ("ALL", ct.ComputeUnit.ALL)):
                mm = ct.models.MLModel(path, compute_units=cu)
                out = mm.predict({"mel": mel[None]})
                times = []
                for _ in range(5):
                    t1 = time.time()
                    out = mm.predict({"mel": mel[None]})
                    times.append(time.time() - t1)
                b, d = out["beat"].reshape(-1), out["downbeat"].reshape(-1)
                r = {
                    "convert_s": round(conv_s, 1),
                    "ms_per_chunk_median": round(1000 * float(np.median(times)), 1),
                    "max_abs_beat": float(np.abs(b - ref_b).max()),
                    "max_abs_downbeat": float(np.abs(d - ref_d).max()),
                    "sign_agree_beat": float(((b > 0) == (ref_b > 0)).mean()),
                    "sign_agree_downbeat": float(((d > 0) == (ref_d > 0)).mean()),
                }
                results[f"{name}/{prec_name}/{cu_name}"] = r
                print(f"[{name}] {prec_name} {cu_name}: {r}", flush=True)
    json.dump(results, open(os.path.join(FIX, "coreml_parity.json"), "w"), indent=1)


if __name__ == "__main__":
    {"fixture": cmd_fixture, "convert": cmd_convert}[sys.argv[1]]()
