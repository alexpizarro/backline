# Backline vs StemDeck — for a musician or student

*Compared 26 September 2026: Backline 0.13 against [StemDeck](https://github.com/stemdeckapp/stemdeck)
0.18.1. Both were read from source, not marketing copy. StemDeck's own README comparison table is out of
date (it still says there is no pitch shift or click track, and both exist now).*

Both apps split songs with the same open model, Meta's Demucs `htdemucs_6s`, so the raw stems sound much
the same. The difference is what each app does with them. StemDeck is a general, cross-platform stem tool
with a DAW-style mixer. Backline is a Mac-only practice player built around one goal: take a guitar part
out of a song and learn to play it.

## Side by side

| For a musician or student | Backline | StemDeck |
|---|---|---|
| **Slow down** | 50–150 % in 5 % steps, key unchanged | Only 0.75× or 1× on desktop (their team found slower sounded bad). 0–2× slider in the phone view |
| **Speed trainer** (gets faster each loop) | Yes: start, step, every N loops, target | No |
| **Transpose** | ±12 semitones for the whole song; drums never shift | ±6 semitones, and each instrument can be moved on its own |
| **Remove my part** | "I'm playing" buttons, remembered between songs. Guide mode plays your part quietly (−15 dB) | No preset; mute stems yourself |
| **Guitar** | **Lead and rhythm guitar as separate tracks** | One guitar track |
| **Vocals** | One vocal track | **Lead and backing vocals as separate tracks** |
| **Looping** | A/B button, edges snap to beats and bars, jump by bars with the arrow keys; a new song opens with the solo already looped | Drag a region or type exact times; no snapping |
| **Song sections** | Found automatically on every song; click one to loop it, double-click to rename | Added by hand (coloured, lockable), or optional AI labelling that takes minutes of CPU |
| **Click and count-in** | Click follows the detected beats; half/double time. Count-in is always 4 beats and the click volume is fixed | **Richer:** click volume, time signatures including odd meters (3+2+2), 0–4 bar count-in, beat grid you can correct with undo |
| **Remembers each song** | Everything: mix, loop, speed, key, sections, position | Mix, key and sections; not loop or speed (on their roadmap) |
| **Export** | One backing track (WAV/AIFF/MP3) **with your speed and key applied** | Mix, loop or **every stem** (WAV/MP3/FLAC/OGG), karaoke MP4, drag straight into a DAW. Speed is not applied |
| **Getting songs in** | Files, YouTube link, **record from any app** (Spotify, Apple Music, a browser) | Files, YouTube, **SoundCloud, search inside the app, playlists, import queue** |
| **Library** | Recently opened list | Folders, search, tags, favourites, trash |
| **Mixer** | Faders, on/off, solo | Same, plus level meters |
| **Practising next to tabs or a DAW** | **Mini player** floating above full-screen apps; single-key shortcuts; PageUp/PageDown for page-turner pedals | About 6 shortcuts; open it on a phone over Wi-Fi via QR code |
| **Where it runs** | macOS 26 on Apple silicon only | Mac (Intel too, macOS 13+), Windows, Linux, Docker; 11 languages |
| **Install** | Signed and notarized DMG; opens normally; no extra downloads | Unsigned on Mac (a Terminal command before first launch); downloads ~0.5 GB+ of runtime and models on first launch |
| **Separation speed** | Core ML on the Apple GPU: a 3:51 song in about 5 s on an M3 Max | PyTorch; in our measurements that path was about 3× slower on the same Mac |
| **Licence and community** | Free download; source public; one maintainer | Free, open source (Apache-2.0), ~3.9 k GitHub stars, Discord |

## Who each suits

- **Guitar or instrument student learning parts and solos → Backline.** Half speed, the speed trainer,
  the lead/rhythm split, "I'm playing", beat-snapped loops and per-song memory all serve practice.
  StemDeck's 0.75× floor is its biggest gap for students.
- **Singer or karaoke → StemDeck.** Lead/backing vocal split, per-instrument transpose, karaoke video.
- **Producer, remixer or DAW user → StemDeck.** Individual stem export, FLAC, drag-to-DAW.
- **Drummer, or anyone in prog or odd meters → StemDeck.** Better click and an editable beat grid.
- **Anyone not on a recent Apple silicon Mac → StemDeck.** Backline won't run for them.

## Why the lead/rhythm split matters for metal

In most rock and metal mixes the rhythm guitars are recorded two or four times and panned hard left and
right, while a solo is one take in the middle. Backline uses that convention: it pulls out the part that
sits in the centre and plays a solo-like register. Everything else stays as rhythm. We tested it on six
multitrack songs where the correct separate parts are known:

- **Removing the whole guitar stem** (what other stem apps give you) takes out about half of the rhythm
  guitar along with the solo.
- **Removing only the lead** keeps about 96 % of the rhythm guitar, and the backing track comes out 4–5 dB
  cleaner.
- **The trade-off:** a little of the solo is left behind. It's quiet enough to play over.

It works best on the usual hard-panned rhythm with a centred solo. If a song pans its guitars differently,
the split is less clean.

## What Backline could take from StemDeck

Individual stem export · click volume and count-in length · a shown tuning offset (it is already
detected) · library search · beat and bar lines on the waveform · a lead/backing vocal split.
