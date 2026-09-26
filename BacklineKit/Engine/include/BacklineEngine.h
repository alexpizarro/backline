// Backline real-time stem engine (C API over a C++ core).
//
// All stems are held in RAM as planar float32 and mixed inside one render callback, so they are
// sample-locked by construction. Each stem runs through its own Signalsmith Stretch instance
// (time-stretch + pitch-shift), which keeps mute/solo/volume changes instant even when stretched.
// Rate 1.0 / 0 st bypasses the stretcher entirely (no latency, no processing artefacts).
// The summed output passes through a soft limiter above -1 dBFS so boosted stems never clip.
//
// Threading: bl_engine_render / the export are the only calls that touch audio. Every other
// setter is a lock-free atomic write and may be called from any thread.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BLEngine BLEngine;

BLEngine *_Nonnull bl_engine_create(double sampleRate);
void bl_engine_destroy(BLEngine *_Nonnull e);

/// Stops playback, waits until the audio thread has left the engine, then (re)allocates storage for
/// `stemCount` stereo stems of `frames` frames. Fill channels via bl_engine_stem_channel, then commit.
bool bl_engine_allocate(BLEngine *_Nonnull e, int stemCount, int64_t frames);
float *_Nullable bl_engine_stem_channel(BLEngine *_Nonnull e, int stem, int channel);
/// Pitch-locked stems (drums) are time-stretched but never transposed.
void bl_engine_set_stem_pitch_locked(BLEngine *_Nonnull e, int stem, bool locked);
void bl_engine_commit(BLEngine *_Nonnull e);
int64_t bl_engine_length(const BLEngine *_Nonnull e);
int bl_engine_stem_count(const BLEngine *_Nonnull e);

/// Linear gain target; the engine ramps to it over ~10 ms.
void bl_engine_set_stem_gain(BLEngine *_Nonnull e, int stem, float gain);
void bl_engine_set_rate(BLEngine *_Nonnull e, double rate);
void bl_engine_set_semitones(BLEngine *_Nonnull e, double semitones);
void bl_engine_set_loop(BLEngine *_Nonnull e, bool enabled, int64_t start, int64_t end);
void bl_engine_set_count_in(BLEngine *_Nonnull e, bool enabled, double bpm, int beats);
void bl_engine_set_click_gain(BLEngine *_Nonnull e, float gain);
/// Metronome during playback on a beat grid (source frames; accent on bar starts). The grid is copied;
/// safe to call while playing (lock-free swap). Clicks are mixed after time-stretching, follow the
/// playback rate, are never pitch-shifted and are never exported.
void bl_engine_set_beat_grid(BLEngine *_Nonnull e, const int64_t *_Nullable frames, const uint8_t *_Nullable accents, int count);
void bl_engine_set_click(BLEngine *_Nonnull e, bool enabled);

/// Speed trainer: while looping, the rate becomes min(to, from + step·⌊passes/every⌋) exactly at each
/// loop wrap (sample-accurate, so the new speed starts on the loop's downbeat). Overrides set_rate.
void bl_engine_set_trainer(BLEngine *_Nonnull e, bool enabled, double from, double step, int every, double to);

void bl_engine_play(BLEngine *_Nonnull e);
void bl_engine_pause(BLEngine *_Nonnull e);
void bl_engine_seek(BLEngine *_Nonnull e, int64_t frame);

typedef struct {
    int64_t position;        ///< source frame currently being heard (latency compensated)
    bool playing;            ///< transport running, including the count-in
    int countInBeat;         ///< 0 when not counting in, else 1...beats
    uint32_t loopPasses;     ///< completed loop wraps since the loop was last changed or play began
    bool reachedEnd;         ///< playback ran off the end of the song and stopped
    int latencyFrames;       ///< current stretcher latency (output side)
    double rate;             ///< playback rate in effect (reflects the speed trainer)
} BLEngineStatus;

BLEngineStatus bl_engine_status(const BLEngine *_Nonnull e);

/// Real-time render. Writes (does not add) `frames` samples to each channel.
void bl_engine_render(BLEngine *_Nonnull e, float *_Nonnull left, float *_Nonnull right, int frames);

/// Offline render for export. `write` receives consecutive blocks; return false to cancel.
typedef bool (*BLExportWrite)(void *_Nullable ctx, const float *_Nonnull left, const float *_Nonnull right, int frames);

typedef struct {
    const float *_Nonnull gains;  ///< one linear gain per stem
    int gainCount;                ///< entries in `gains`; stems beyond it export silent
    double rate;
    double semitones;
    int64_t start;
    int64_t end;
} BLExportParams;

/// Returns the number of frames written, or -1 if cancelled.
int64_t bl_engine_export(BLEngine *_Nonnull e, const BLExportParams *_Nonnull p,
                         BLExportWrite _Nonnull write, void *_Nullable ctx);

/// Output length of an export with these params (frames).
int64_t bl_engine_export_length(const BLEngine *_Nonnull e, const BLExportParams *_Nonnull p);

#ifdef __cplusplus
}
#endif
