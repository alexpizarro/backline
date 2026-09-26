// Backline real-time stem engine. See include/BacklineEngine.h for the contract.
#include "BacklineEngine.h"

#define SIGNALSMITH_USE_ACCELERATE 1
#include "vendor/signalsmith-stretch/signalsmith-stretch.h"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

namespace {

constexpr int kMaxStems = 8;
constexpr int kBlock = 1024;             // internal render quantum
constexpr int kXfade = 256;              // declick / loop-splice crossfade (~5.8 ms)
constexpr int kGainRampFrames = 441;     // full-scale gain ramp (~10 ms)
constexpr double kMaxRate = 2.0;

using Stretch = signalsmith::stretch::SignalsmithStretch<float>;

inline bool isIdentity(double rate, double semis) {
    return std::fabs(rate - 1.0) < 1e-6 && std::fabs(semis) < 1e-6;
}

/// Transparent below -1 dBFS, then a smooth tanh knee so boosted stems never hard-clip.
inline float softClip(float x) {
    constexpr float t = 0.89f;
    const float a = std::fabs(x);
    if (a <= t) return x;
    const float y = t + (1.0f - t) * std::tanh((a - t) / (1.0f - t));
    return std::copysign(y, x);
}

void softClipBuffer(float *x, int n) {
    for (int i = 0; i < n; ++i) x[i] = softClip(x[i]);
}

/// dst += src * gain, ramping `cur` towards `target` at most one full-scale step per kGainRampFrames.
void mixWithRamp(float *dstL, float *dstR, const float *srcL, const float *srcR, int n, float &cur, float target) {
    constexpr float step = 1.0f / kGainRampFrames;
    int i = 0;
    for (; i < n && cur != target; ++i) {
        cur = cur < target ? std::min(target, cur + step) : std::max(target, cur - step);
        dstL[i] += srcL[i] * cur;
        dstR[i] += srcR[i] * cur;
    }
    if (i < n && cur != 0.0f) {
        float g = cur;
        vDSP_vsma(srcL + i, 1, &g, dstL + i, 1, dstL + i, 1, vDSP_Length(n - i));
        vDSP_vsma(srcR + i, 1, &g, dstR + i, 1, dstR + i, 1, vDSP_Length(n - i));
    }
}

std::vector<float> makeClick(double sr, double freq, float amp) {
    const int n = int(sr * 0.045);
    std::vector<float> c(size_t(n), 0.0f);
    for (int i = 0; i < n; ++i) {
        const double t = i / sr;
        const double env = std::exp(-t / 0.009) * std::min(1.0, i / (sr * 0.0006));
        c[size_t(i)] = float(amp * env * (std::sin(2 * M_PI * freq * t) + 0.35 * std::sin(2 * M_PI * freq * 2.01 * t)));
    }
    return c;
}

} // namespace

struct BLEngine {
    explicit BLEngine(double sr) : sampleRate(sr) {
        for (auto &g : targetGain) g.store(1.0f);
        for (auto &g : curGain) g = 1.0f;
        clickAccent = makeClick(sr, 1760.0, 0.55f);
        clickNormal = makeClick(sr, 1320.0, 0.40f);
        for (auto &b : tmpOut) b.assign(kBlock, 0.0f);
        for (auto &b : xfadeBuf) b.assign(kXfade, 0.0f);
        for (auto &b : mixBuf) b.assign(kBlock, 0.0f);
    }

    const double sampleRate;

    // --- Song data. Mutated only while !ready and no render is in flight.
    int nStems = 0;
    int64_t length = 0;
    std::vector<float> data[kMaxStems * 2];
    bool pitchLocked[kMaxStems] = {};
    std::unique_ptr<Stretch> stretch[kMaxStems];
    int inCapacity = 0;
    std::vector<float> inBuf[kMaxStems * 2];
    float *inPtr[kMaxStems * 2] = {};
    int stretchInLatency = 0, stretchOutLatency = 0;

    std::atomic<bool> ready{false};
    std::atomic<int> inRender{0};

    // --- Controls (any thread → audio thread).
    std::atomic<float> targetGain[kMaxStems];
    std::atomic<double> rate{1.0};
    std::atomic<double> semitones{0.0};
    std::atomic<uint32_t> loopSeq{0};
    std::atomic<bool> loopEnabledW{false};
    std::atomic<int64_t> loopStartW{0}, loopEndW{0};
    std::atomic<bool> countInEnabled{false};
    std::atomic<double> countInBpm{0.0};
    std::atomic<int> countInBeats{4};
    std::atomic<float> clickGain{1.0f};

    // Beat-grid metronome. Two grid buffers; the control thread fills the inactive one then
    // publishes it with an atomic index swap (the audio thread only reads the published one).
    struct Grid { std::vector<int64_t> frames; std::vector<uint8_t> accents; };
    Grid grids[2];
    std::atomic<int> gridIndex{-1};           // -1 = none
    std::atomic<bool> clickOn{false};
    std::atomic<uint32_t> gridGen{0};         // bumped on every publish (slot indices repeat)
    uint32_t gridGenSeen = UINT32_MAX;
    size_t gridCursor = 0;                    // next beat index at or after the heard position
    int64_t lastHeard = -1;
    int clickPlayFrom = -1, clickPlayPos = 0; // currently sounding click sample
    bool clickPlayAccent = false;
    std::atomic<bool> trainerOn{false};
    std::atomic<double> trainerFrom{0.7}, trainerStep{0.05}, trainerTo{1.0};
    std::atomic<int> trainerEvery{2};
    std::atomic<int64_t> pendingSeek{-1};
    std::atomic<int> pendingTransport{0};   // 1 play, 2 pause

    // --- Status (audio thread → any thread).
    std::atomic<int64_t> stPosition{0};
    std::atomic<bool> stPlaying{false};
    std::atomic<int> stCountInBeat{0};
    std::atomic<uint32_t> stLoopPasses{0};
    std::atomic<bool> stReachedEnd{false};
    std::atomic<int> stLatency{0};
    std::atomic<double> stRate{1.0};

    // --- Audio-thread state.
    bool playing = false;          // transport running (count-in or audio)
    bool audioRunning = false;     // past the count-in
    bool stretchMode = false;
    double curRate = 1.0, curSemis = 0.0;
    int64_t feedPos = 0;           // next source frame handed to the path
    double inFrac = 0.0;
    bool loopOn = false, loopArmed = false;
    int64_t loopA = 0, loopB = 0;
    uint32_t loopSeqSeen = UINT32_MAX;
    uint32_t loopPasses = 0;
    bool wrappedSinceArm = false;
    int64_t countInLeft = 0, countInTotal = 0, countInBeatLen = 0;
    float curGain[kMaxStems];
    int fadeInLeft = 0;
    int xfadeLeft = 0;
    std::vector<float> xfadeBuf[2];
    std::vector<float> tmpOut[2];
    std::vector<float> mixBuf[2];
    std::vector<float> clickAccent, clickNormal;

    // ------------------------------------------------------------------ helpers (audio thread)

    double pathLatency() const { return stretchInLatency + curRate * stretchOutLatency; }

    /// Source frame currently heard at the engine output.
    int64_t heardPosition() const {
        if (!audioRunning || !stretchMode) return std::clamp<int64_t>(feedPos, 0, length);
        const double lat = pathLatency();
        int64_t p = feedPos - int64_t(lat);
        if (loopOn && loopArmed && wrappedSinceArm && p < loopA && feedPos >= loopA && double(feedPos - loopA) < lat) {
            p += loopB - loopA;
        }
        return std::clamp<int64_t>(p, 0, length);
    }

    void armLoop(int64_t heard) { loopArmed = loopOn && heard < loopB; wrappedSinceArm = false; }

    /// Fills inBuf[0..n) for every stem from feedPos, wrapping the loop with a short splice crossfade
    /// and returning silence past the end of the song.
    void feed(int n) {
        int i = 0;
        const int S2 = nStems * 2;
        while (i < n) {
            const bool loopActive = loopOn && loopArmed;
            if (loopActive && feedPos >= loopB) {
                feedPos = loopA;
                ++loopPasses;
                wrappedSinceArm = true;
                if (trainerOn.load(std::memory_order_relaxed) && stretchMode) {
                    curRate = std::clamp(effectiveRate(curRate), 0.25, kMaxRate);
                }
            }
            if (feedPos >= length) {
                for (int k = 0; k < S2; ++k) std::memset(inPtr[k] + i, 0, sizeof(float) * size_t(n - i));
                feedPos += n - i;
                return;
            }
            const int64_t limit = loopActive ? loopB : length;
            const int seg = int(std::min<int64_t>(n - i, limit - feedPos));
            if (!loopActive) {
                for (int k = 0; k < S2; ++k)
                    std::memcpy(inPtr[k] + i, data[k].data() + feedPos, sizeof(float) * size_t(seg));
            } else {
                const int64_t zone = loopB - kXfade;
                const int64_t span = loopB - loopA;
                const int plain = int(std::clamp<int64_t>(zone - feedPos, 0, seg));
                for (int k = 0; k < S2; ++k) {
                    const float *src = data[k].data();
                    float *d = inPtr[k] + i;
                    if (plain > 0) std::memcpy(d, src + feedPos, sizeof(float) * size_t(plain));
                    for (int j = plain; j < seg; ++j) {
                        const int64_t p = feedPos + j;
                        const float w = 0.5f - 0.5f * std::cos(float(M_PI) * (float(p - zone) + 0.5f) / kXfade);
                        const int64_t q = p - span;
                        const float b = q >= 0 ? src[q] : 0.0f;
                        d[j] = src[p] * (1.0f - w) + b * w;
                    }
                }
            }
            feedPos += seg;
            i += seg;
        }
    }

    /// Rate the speed trainer wants for the current pass count (or the manual rate).
    double effectiveRate(double manual) const {
        if (!trainerOn.load(std::memory_order_relaxed) || !loopOn) return manual;
        const int every = std::max(1, trainerEvery.load(std::memory_order_relaxed));
        const double r = trainerFrom.load(std::memory_order_relaxed)
            + trainerStep.load(std::memory_order_relaxed) * double(loopPasses / uint32_t(every));
        return std::min(trainerTo.load(std::memory_order_relaxed), r);
    }

    void applyTranspose() {
        for (int s = 0; s < nStems; ++s)
            stretch[s]->setTransposeSemitones(float(pitchLocked[s] ? 0.0 : curSemis));
    }

    /// Re-primes every stretcher so its next output sample is source frame `p`.
    void seekStretchers(int64_t p) {
        const int len = std::min(inCapacity, stretch[0]->outputSeekLength(float(curRate)));
        feedPos = p;
        // Priming reads ahead; a loop wrap inside it isn't a pass the player heard.
        const uint32_t passes = loopPasses;
        const double rateBefore = curRate;
        feed(len);
        loopPasses = passes;
        curRate = rateBefore;
        for (int s = 0; s < nStems; ++s) {
            float *ins[2] = {inPtr[2 * s], inPtr[2 * s + 1]};
            stretch[s]->outputSeek(ins, len);
        }
        inFrac = 0.0;
    }

    void startAudioAt(int64_t p) {
        audioRunning = true;
        armLoop(p);
        if (stretchMode) seekStretchers(p);
        else feedPos = p;
    }

    /// Renders the current path (no count-in, no fades) into L/R, overwriting.
    void renderPath(float *L, float *R, int n) {
        std::memset(L, 0, sizeof(float) * size_t(n));
        std::memset(R, 0, sizeof(float) * size_t(n));
        if (!stretchMode) {
            feed(n);
            for (int s = 0; s < nStems; ++s)
                mixWithRamp(L, R, inPtr[2 * s], inPtr[2 * s + 1], n, curGain[s], targetGain[s].load(std::memory_order_relaxed));
        } else {
            inFrac += n * curRate;
            int inN = int(inFrac);
            inN = std::min(inN, inCapacity);
            inFrac -= inN;
            feed(inN);
            float *outs[2] = {tmpOut[0].data(), tmpOut[1].data()};
            for (int s = 0; s < nStems; ++s) {
                float *ins[2] = {inPtr[2 * s], inPtr[2 * s + 1]};
                stretch[s]->process(ins, inN, outs, n);
                mixWithRamp(L, R, outs[0], outs[1], n, curGain[s], targetGain[s].load(std::memory_order_relaxed));
            }
        }
    }

    /// Captures kXfade frames of the path as it is now, to crossfade into whatever comes next.
    void captureXfade() {
        renderPath(xfadeBuf[0].data(), xfadeBuf[1].data(), kXfade);
        xfadeLeft = kXfade;
    }

    void renderClicks(float *L, float *R, int n) {
        const float g = clickGain.load(std::memory_order_relaxed);
        for (int i = 0; i < n; ++i) {
            const int64_t t = countInTotal - countInLeft + i;
            const int64_t beat = t / countInBeatLen;
            const int64_t off = t - beat * countInBeatLen;
            const auto &c = beat == 0 ? clickAccent : clickNormal;
            const float v = off < int64_t(c.size()) ? c[size_t(off)] * g : 0.0f;
            L[i] = v;
            R[i] = v;
        }
    }

    /// Mixes metronome clicks for the beats heard during this block. `h0` is the heard source frame at
    /// the first rendered sample (captured before the path advanced) and `outOffset` where audio starts
    /// in the block. If the heard position wraps a loop inside the block, the scan runs in two pieces.
    void renderBeatClicks(float *L, float *R, int n, int64_t h0, int outOffset) {
        const float g = clickGain.load(std::memory_order_relaxed) * 0.8f;
        // Continue a click that started in an earlier block.
        auto playTail = [&](int from) {
            if (clickPlayFrom < 0) return;
            const auto &c = clickPlayAccent ? clickAccent : clickNormal;
            for (int i = from; i < n && clickPlayPos < int(c.size()); ++i, ++clickPlayPos) {
                L[i] += c[size_t(clickPlayPos)] * g; R[i] += c[size_t(clickPlayPos)] * g;
            }
            if (clickPlayPos >= int(c.size())) clickPlayFrom = -1;
        };
        playTail(0);
        const int gi = gridIndex.load(std::memory_order_acquire);
        const uint32_t gen = gridGen.load(std::memory_order_acquire);
        if (!clickOn.load(std::memory_order_relaxed) || gi < 0 || h0 < 0) { lastHeard = -1; return; }
        const Grid &grid = grids[gi];
        if (grid.frames.empty()) return;
        const double rate = stretchMode ? curRate : 1.0;
        const int span = n - outOffset;
        if (span <= 0) return;

        // Scan beats in source range [a, b) and place them at output offsets base + (f - a) / rate.
        auto scan = [&](int64_t a, int64_t b, int base) {
            if (gen != gridGenSeen || lastHeard < 0 || a != lastHeard) {
                gridGenSeen = gen;
                gridCursor = size_t(std::lower_bound(grid.frames.begin(), grid.frames.end(), a) - grid.frames.begin());
            }
            while (gridCursor < grid.frames.size() && grid.frames[gridCursor] < b) {
                const int64_t f = grid.frames[gridCursor];
                if (f >= a) {
                    const int off = base + int(double(f - a) / rate);
                    if (off >= 0 && off < n) {
                        clickPlayAccent = grid.accents[gridCursor] != 0;
                        clickPlayFrom = off; clickPlayPos = 0;
                        playTail(off);
                    }
                }
                ++gridCursor;
            }
            lastHeard = b;
        };
        const int64_t adv = int64_t(double(span) * rate + 0.5);
        const int64_t h1 = h0 + adv;
        if (loopOn && loopArmed && h0 < loopB && h1 > loopB) {
            const int64_t first = loopB - h0;
            const int k = outOffset + int(double(first) / rate);
            scan(h0, loopB, outOffset);
            lastHeard = -1;                       // force a re-seek at the loop start
            scan(loopA, loopA + (adv - first), k);
        } else {
            scan(h0, h1, outOffset);
        }
    }

    void syncControls() {
        // Loop (seqlock, single writer).
        const uint32_t s1 = loopSeq.load(std::memory_order_acquire);
        if (s1 != loopSeqSeen && (s1 & 1u) == 0) {
            const bool en = loopEnabledW.load(std::memory_order_relaxed);
            const int64_t a = loopStartW.load(std::memory_order_relaxed);
            const int64_t b = loopEndW.load(std::memory_order_relaxed);
            std::atomic_thread_fence(std::memory_order_acquire);
            if (loopSeq.load(std::memory_order_relaxed) == s1) {
                loopSeqSeen = s1;
                const int64_t A = std::clamp<int64_t>(a, 0, length);
                const int64_t B = std::clamp<int64_t>(b, 0, length);
                loopOn = en && B - A >= 4 * kXfade;
                loopA = A;
                loopB = B;
                armLoop(heardPosition());
                loopPasses = 0;
            }
        }
    }

    void render(float *L, float *R, int frames) {
        int done = 0;
        while (done < frames) {
            const int n = std::min(kBlock, frames - done);
            renderBlock(L + done, R + done, n);
            done += n;
        }
    }

    void renderBlock(float *L, float *R, int n) {
        syncControls();
        // Transport commands first, so a fresh play resets the speed trainer before the rate is read.
        const int64_t seekTo = pendingSeek.exchange(-1, std::memory_order_acq_rel);
        const int transport = pendingTransport.exchange(0, std::memory_order_acq_rel);
        if (transport == 1 && !playing) loopPasses = 0;

        const double wantRate = std::clamp(effectiveRate(rate.load(std::memory_order_relaxed)), 0.25, kMaxRate);
        const double wantSemis = std::clamp(semitones.load(std::memory_order_relaxed), -24.0, 24.0);
        const bool wantStretch = !isIdentity(wantRate, wantSemis);

        if (seekTo >= 0) {
            const int64_t p = std::clamp<int64_t>(seekTo, 0, std::max<int64_t>(0, length - 1));
            if (playing && audioRunning) {
                captureXfade();
                stretchMode = wantStretch;
                curRate = wantRate; curSemis = wantSemis;
                if (stretchMode) applyTranspose();
                startAudioAt(p);
            } else {
                feedPos = p;
                armLoop(p);
            }
            stReachedEnd.store(false, std::memory_order_relaxed);
        }

        if (transport == 2 && playing) {
            // Pause: fade the current path out over one crossfade, keep the heard position.
            if (audioRunning) {
                const int64_t heard = heardPosition();
                captureXfade();
                feedPos = heard;
            }
            playing = false;
            audioRunning = false;
            countInLeft = 0;
        } else if (transport == 1 && !playing) {
            playing = true;
            stReachedEnd.store(false, std::memory_order_relaxed);
            if (feedPos >= length) feedPos = 0;
            const double bpm = countInBpm.load(std::memory_order_relaxed);
            const int beats = countInBeats.load(std::memory_order_relaxed);
            curRate = wantRate; curSemis = wantSemis;
            stretchMode = wantStretch;
            if (stretchMode) applyTranspose();
            loopPasses = 0;
            if (countInEnabled.load(std::memory_order_relaxed) && bpm > 20 && beats > 0) {
                countInBeatLen = std::max<int64_t>(1, int64_t(std::llround(60.0 / (bpm * curRate) * sampleRate)));
                countInTotal = countInBeatLen * beats;
                countInLeft = countInTotal;
                audioRunning = false;
            } else {
                startAudioAt(feedPos);
                fadeInLeft = kXfade;
            }
        }

        // Rate / pitch changes while audio is running.
        if (playing && audioRunning) {
            if (wantStretch != stretchMode) {
                const int64_t heard = heardPosition();
                // Old path continues from `heard` for the crossfade; the new one restarts at `heard`.
                captureXfade();
                stretchMode = wantStretch;
                curRate = wantRate; curSemis = wantSemis;
                if (stretchMode) applyTranspose();
                startAudioAt(heard);
            } else if (stretchMode) {
                curRate = wantRate;
                if (wantSemis != curSemis) { curSemis = wantSemis; applyTranspose(); }
            }
        } else if (!playing) {
            curRate = wantRate; curSemis = wantSemis;
            stretchMode = wantStretch;
        }

        int offset = 0;
        int countBeat = 0;
        if (playing && !audioRunning && countInLeft > 0) {
            const int m = int(std::min<int64_t>(n, countInLeft));
            renderClicks(L, R, m);
            countInLeft -= m;
            countBeat = int((countInTotal - countInLeft - 1) / countInBeatLen) + 1;
            offset = m;
            if (countInLeft == 0) {
                // Stretch mode re-reads the rate at the downbeat.
                curRate = wantRate; curSemis = wantSemis;
                stretchMode = wantStretch;
                if (stretchMode) applyTranspose();
                startAudioAt(feedPos);
                fadeInLeft = kXfade;
                countBeat = 0;
            }
        }

        int64_t clickFrom = -1;
        if (playing && audioRunning && offset < n) {
            clickFrom = heardPosition();
            renderPath(L + offset, R + offset, n - offset);
            // A fresh start with nothing to crossfade from gets a short fade-in.
            if (fadeInLeft > 0) {
                const int m = std::min(fadeInLeft, n - offset);
                for (int i = 0; i < m; ++i) {
                    const float w = float(kXfade - fadeInLeft + i + 1) / kXfade;
                    L[offset + i] *= w;
                    R[offset + i] *= w;
                }
                fadeInLeft -= m;
            }
        } else if (offset < n) {
            std::memset(L + offset, 0, sizeof(float) * size_t(n - offset));
            std::memset(R + offset, 0, sizeof(float) * size_t(n - offset));
        }

        // Crossfade out of the previous path (seek, pause, rate-mode switch).
        if (xfadeLeft > 0) {
            const int m = std::min(xfadeLeft, n);
            const int base = kXfade - xfadeLeft;
            for (int i = 0; i < m; ++i) {
                const float w = 0.5f + 0.5f * std::cos(float(M_PI) * (float(base + i) + 0.5f) / kXfade); // 1 → 0
                L[i] = L[i] * (1.0f - w) + xfadeBuf[0][size_t(base + i)] * w;
                R[i] = R[i] * (1.0f - w) + xfadeBuf[1][size_t(base + i)] * w;
            }
            xfadeLeft -= m;
        }

        if (playing && audioRunning) renderBeatClicks(L, R, n, clickFrom, offset);

        softClipBuffer(L, n);
        softClipBuffer(R, n);

        // End of song (no loop): stop and rewind.
        if (playing && audioRunning && !(loopOn && loopArmed) && heardPosition() >= length) {
            playing = false;
            audioRunning = false;
            feedPos = 0;
            stReachedEnd.store(true, std::memory_order_relaxed);
        }

        stPosition.store(playing && !audioRunning ? feedPos : heardPosition(), std::memory_order_relaxed);
        stPlaying.store(playing, std::memory_order_relaxed);
        stCountInBeat.store(countBeat, std::memory_order_relaxed);
        stLoopPasses.store(loopPasses, std::memory_order_relaxed);
        stLatency.store(stretchMode ? int(pathLatency() / curRate) : 0, std::memory_order_relaxed);
        stRate.store(stretchMode ? curRate : 1.0, std::memory_order_relaxed);
    }
};

// ---------------------------------------------------------------------------------------- C API

extern "C" {

BLEngine *bl_engine_create(double sampleRate) { return new BLEngine(sampleRate); }

void bl_engine_destroy(BLEngine *e) {
    e->ready.store(false);
    while (e->inRender.load() != 0) std::this_thread::yield();
    delete e;
}

bool bl_engine_allocate(BLEngine *e, int stemCount, int64_t frames) {
    if (stemCount < 1 || stemCount > kMaxStems || frames < 1) return false;
    e->ready.store(false);
    while (e->inRender.load() != 0) std::this_thread::yield();

    e->nStems = stemCount;
    e->length = frames;
    for (int k = 0; k < kMaxStems * 2; ++k) {
        if (k < stemCount * 2) e->data[k].assign(size_t(frames), 0.0f);
        else std::vector<float>().swap(e->data[k]);
    }
    int seekLen = 0;
    for (int s = 0; s < kMaxStems; ++s) {
        e->pitchLocked[s] = false;
        if (s < stemCount) {
            if (!e->stretch[s]) e->stretch[s] = std::make_unique<Stretch>(long(1234 + s));
            e->stretch[s]->presetDefault(2, float(e->sampleRate), true);
            seekLen = std::max(seekLen, e->stretch[s]->outputSeekLength(float(kMaxRate)));
        } else {
            e->stretch[s].reset();
        }
    }
    e->stretchInLatency = e->stretch[0]->inputLatency();
    e->stretchOutLatency = e->stretch[0]->outputLatency();
    e->inCapacity = std::max(int(kBlock * kMaxRate) + 64, seekLen + 64);
    for (int k = 0; k < kMaxStems * 2; ++k) {
        if (k < stemCount * 2) {
            e->inBuf[k].assign(size_t(e->inCapacity), 0.0f);
            e->inPtr[k] = e->inBuf[k].data();
        } else {
            std::vector<float>().swap(e->inBuf[k]);
            e->inPtr[k] = nullptr;
        }
    }
    // Reset transport.
    e->playing = e->audioRunning = false;
    e->feedPos = 0;
    e->inFrac = 0;
    e->loopOn = e->loopArmed = false;
    e->loopSeqSeen = UINT32_MAX;
    e->xfadeLeft = e->fadeInLeft = 0;
    e->countInLeft = 0;
    e->pendingSeek.store(-1);
    e->pendingTransport.store(0);
    e->stPosition.store(0);
    e->stPlaying.store(false);
    e->stReachedEnd.store(false);
    for (int s = 0; s < kMaxStems; ++s) e->curGain[s] = e->targetGain[s].load();
    return true;
}

float *bl_engine_stem_channel(BLEngine *e, int stem, int channel) {
    if (stem < 0 || stem >= e->nStems || channel < 0 || channel > 1) return nullptr;
    return e->data[stem * 2 + channel].data();
}

void bl_engine_set_stem_pitch_locked(BLEngine *e, int stem, bool locked) {
    if (stem >= 0 && stem < kMaxStems) e->pitchLocked[stem] = locked;
}

void bl_engine_commit(BLEngine *e) { e->ready.store(true); }
int64_t bl_engine_length(const BLEngine *e) { return e->length; }
int bl_engine_stem_count(const BLEngine *e) { return e->nStems; }

void bl_engine_set_stem_gain(BLEngine *e, int stem, float gain) {
    if (stem >= 0 && stem < kMaxStems) e->targetGain[stem].store(std::max(0.0f, gain), std::memory_order_relaxed);
}

void bl_engine_set_rate(BLEngine *e, double rate) { e->rate.store(rate, std::memory_order_relaxed); }
void bl_engine_set_semitones(BLEngine *e, double s) { e->semitones.store(s, std::memory_order_relaxed); }

void bl_engine_set_loop(BLEngine *e, bool enabled, int64_t start, int64_t end) {
    const uint32_t s = e->loopSeq.load(std::memory_order_relaxed);
    e->loopSeq.store(s + 1, std::memory_order_relaxed);          // odd: writing
    std::atomic_thread_fence(std::memory_order_release);
    e->loopEnabledW.store(enabled, std::memory_order_relaxed);
    e->loopStartW.store(start, std::memory_order_relaxed);
    e->loopEndW.store(end, std::memory_order_relaxed);
    e->loopSeq.store(s + 2, std::memory_order_release);          // even: stable
}

void bl_engine_set_count_in(BLEngine *e, bool enabled, double bpm, int beats) {
    e->countInEnabled.store(enabled, std::memory_order_relaxed);
    e->countInBpm.store(bpm, std::memory_order_relaxed);
    e->countInBeats.store(beats, std::memory_order_relaxed);
}

void bl_engine_set_click_gain(BLEngine *e, float gain) { e->clickGain.store(gain, std::memory_order_relaxed); }

void bl_engine_set_beat_grid(BLEngine *e, const int64_t *frames, const uint8_t *accents, int count) {
    const int cur = e->gridIndex.load(std::memory_order_acquire);
    const int next = cur == 0 ? 1 : 0;
    // The audio thread may still be reading `cur`; wait until no render is in flight before
    // overwriting `next` if it was published before (double-buffer reuse).
    while (e->inRender.load() != 0) std::this_thread::yield();
    auto &g = e->grids[next];
    g.frames.assign(frames, frames + (frames ? count : 0));
    g.accents.assign(accents, accents + (accents ? count : 0));
    if (g.accents.size() != g.frames.size()) g.accents.assign(g.frames.size(), 0);
    e->gridIndex.store(count > 0 ? next : -1, std::memory_order_release);
    e->gridGen.fetch_add(1, std::memory_order_release);
}

void bl_engine_set_click(BLEngine *e, bool enabled) { e->clickOn.store(enabled, std::memory_order_relaxed); }

void bl_engine_set_trainer(BLEngine *e, bool enabled, double from, double step, int every, double to) {
    e->trainerFrom.store(from, std::memory_order_relaxed);
    e->trainerStep.store(step, std::memory_order_relaxed);
    e->trainerEvery.store(std::max(1, every), std::memory_order_relaxed);
    e->trainerTo.store(std::max(from, to), std::memory_order_relaxed);
    e->trainerOn.store(enabled, std::memory_order_release);
}

void bl_engine_play(BLEngine *e) { e->pendingTransport.store(1, std::memory_order_release); }
void bl_engine_pause(BLEngine *e) { e->pendingTransport.store(2, std::memory_order_release); }
void bl_engine_seek(BLEngine *e, int64_t frame) { e->pendingSeek.store(std::max<int64_t>(0, frame), std::memory_order_release); }

BLEngineStatus bl_engine_status(const BLEngine *e) {
    BLEngineStatus s;
    s.position = e->stPosition.load(std::memory_order_relaxed);
    s.playing = e->stPlaying.load(std::memory_order_relaxed);
    s.countInBeat = e->stCountInBeat.load(std::memory_order_relaxed);
    s.loopPasses = e->stLoopPasses.load(std::memory_order_relaxed);
    s.reachedEnd = e->stReachedEnd.load(std::memory_order_relaxed);
    s.latencyFrames = e->stLatency.load(std::memory_order_relaxed);
    s.rate = e->stRate.load(std::memory_order_relaxed);
    return s;
}

void bl_engine_render(BLEngine *e, float *left, float *right, int frames) {
    e->inRender.fetch_add(1);
    if (!e->ready.load() || e->nStems == 0) {
        std::memset(left, 0, sizeof(float) * size_t(frames));
        std::memset(right, 0, sizeof(float) * size_t(frames));
    } else {
        e->render(left, right, frames);
    }
    e->inRender.fetch_sub(1);
}

int64_t bl_engine_export_length(const BLEngine *e, const BLExportParams *p) {
    const int64_t start = std::clamp<int64_t>(p->start, 0, e->length);
    const int64_t end = std::clamp<int64_t>(p->end <= 0 ? e->length : p->end, start, e->length);
    const double rate = std::clamp(p->rate, 0.25, kMaxRate);
    if (isIdentity(rate, p->semitones)) return end - start;
    return int64_t(std::llround(double(end - start) / rate));
}

int64_t bl_engine_export(BLEngine *e, const BLExportParams *p, BLExportWrite write, void *ctx) {
    const int64_t start = std::clamp<int64_t>(p->start, 0, e->length);
    const int64_t end = std::clamp<int64_t>(p->end <= 0 ? e->length : p->end, start, e->length);
    const double rate = std::clamp(p->rate, 0.25, kMaxRate);
    const double semis = std::clamp(p->semitones, -24.0, 24.0);
    const bool identity = isIdentity(rate, semis);
    const int64_t outLen = bl_engine_export_length(e, p);

    // Mix stems into two groups (transposed / pitch-locked) with static gains.
    auto mixGroup = [&](int group, int64_t pos, int n, float *L, float *R) {
        std::memset(L, 0, sizeof(float) * size_t(n));
        std::memset(R, 0, sizeof(float) * size_t(n));
        const int avail = int(std::clamp<int64_t>(end - pos, 0, n));
        if (avail <= 0) return;
        for (int s = 0; s < e->nStems; ++s) {
            if ((group == 1) != e->pitchLocked[s]) continue;
            float g = s < p->gainCount ? p->gains[s] : 0.0f;
            if (g == 0.0f) continue;
            vDSP_vsma(e->data[2 * s].data() + pos, 1, &g, L, 1, L, 1, vDSP_Length(avail));
            vDSP_vsma(e->data[2 * s + 1].data() + pos, 1, &g, R, 1, R, 1, vDSP_Length(avail));
        }
    };

    std::vector<float> outL(kBlock), outR(kBlock);
    int64_t produced = 0;

    if (identity) {
        std::vector<float> gL(kBlock), gR(kBlock);
        while (produced < outLen) {
            const int n = int(std::min<int64_t>(kBlock, outLen - produced));
            mixGroup(0, start + produced, n, outL.data(), outR.data());
            mixGroup(1, start + produced, n, gL.data(), gR.data());
            vDSP_vadd(outL.data(), 1, gL.data(), 1, outL.data(), 1, vDSP_Length(n));
            vDSP_vadd(outR.data(), 1, gR.data(), 1, outR.data(), 1, vDSP_Length(n));
            softClipBuffer(outL.data(), n);
            softClipBuffer(outR.data(), n);
            if (!write(ctx, outL.data(), outR.data(), n)) return -1;
            produced += n;
        }
        return produced;
    }

    Stretch st[2];
    const int cap = int(kBlock * kMaxRate) + 64;
    int seekLen = 0;
    for (int g = 0; g < 2; ++g) {
        st[g].presetDefault(2, float(e->sampleRate), false);
        st[g].setTransposeSemitones(float(g == 0 ? semis : 0.0));
        seekLen = std::max(seekLen, st[g].outputSeekLength(float(rate)));
    }
    std::vector<float> in[2][2], out[2][2];
    for (int g = 0; g < 2; ++g)
        for (int c = 0; c < 2; ++c) {
            in[g][c].assign(size_t(std::max(cap, seekLen)), 0.0f);
            out[g][c].assign(kBlock, 0.0f);
        }
    for (int g = 0; g < 2; ++g) {
        mixGroup(g, start, seekLen, in[g][0].data(), in[g][1].data());
        float *ins[2] = {in[g][0].data(), in[g][1].data()};
        st[g].outputSeek(ins, seekLen);
    }
    int64_t feed = start + seekLen;
    double frac = 0.0;
    while (produced < outLen) {
        const int n = int(std::min<int64_t>(kBlock, outLen - produced));
        frac += n * rate;
        const int inN = std::min(int(frac), cap);
        frac -= inN;
        std::memset(outL.data(), 0, sizeof(float) * size_t(n));
        std::memset(outR.data(), 0, sizeof(float) * size_t(n));
        for (int g = 0; g < 2; ++g) {
            mixGroup(g, feed, inN, in[g][0].data(), in[g][1].data());
            float *ins[2] = {in[g][0].data(), in[g][1].data()};
            float *outs[2] = {out[g][0].data(), out[g][1].data()};
            st[g].process(ins, inN, outs, n);
            vDSP_vadd(outL.data(), 1, outs[0], 1, outL.data(), 1, vDSP_Length(n));
            vDSP_vadd(outR.data(), 1, outs[1], 1, outR.data(), 1, vDSP_Length(n));
        }
        feed += inN;
        softClipBuffer(outL.data(), n);
        softClipBuffer(outR.data(), n);
        if (!write(ctx, outL.data(), outR.data(), n)) return -1;
        produced += n;
    }
    return produced;
}

} // extern "C"
