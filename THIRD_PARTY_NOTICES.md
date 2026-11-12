# Third-party notices (Backline for Mac)

Backline's own code is MIT-licensed (`LICENSE`). The app bundles the components below; the in-app
Credits show the same list (`Backline/Resources/Acknowledgements.txt`).

## Code

| Component | Use | Licence | Source |
|---|---|---|---|
| Signalsmith Stretch | Time-stretch and pitch shift | MIT, (c) 2022 Geraint Luff / Signalsmith Audio Ltd. | https://github.com/Signalsmith-Audio/signalsmith-stretch |
| Signalsmith Linear | FFT and vector maths | MIT, (c) 2025 Signalsmith Audio | https://github.com/Signalsmith-Audio/linear |
| LAME | MP3 export | GNU LGPL v2; loaded dynamically from `Contents/Frameworks/libmp3lame.0.dylib`, replaceable (`Vendor/lame/COPYING`) | https://lame.sourceforge.io/ |
| yt-dlp | Web-link audio download | The Unlicense; compiled to native code with Nuitka (the compiler is AGPL-3.0, its output is not) | https://github.com/yt-dlp/yt-dlp |
| CPython runtime | Runs the compiled yt-dlp | Python Software Foundation License | https://www.python.org |
| certifi | CA certificates | Mozilla Public License 2.0 | https://github.com/certifi/python-certifi |
| pycryptodomex | Crypto for yt-dlp | BSD 2-Clause / Public Domain | https://github.com/Legrandin/pycryptodome |
| Brotli | Decompression | MIT | https://github.com/google/brotli |
| websockets | Networking | BSD 3-Clause | https://github.com/python-websockets/websockets |
| requests | Networking | Apache License 2.0 | https://github.com/psf/requests |
| urllib3 | Networking | MIT | https://github.com/urllib3/urllib3 |
| yt-dlp-ejs | Challenge solver | The Unlicense | https://github.com/yt-dlp/ejs |
| QuickJS-NG | JavaScript runtime for yt-dlp | MIT, (c) 2017-2026 Fabrice Bellard, Charlie Gordon and QuickJS-NG contributors | https://github.com/quickjs-ng/quickjs |
| go-play-in-the-band (adapted) | Tempo, key, progressive tempo | MIT | https://github.com/brucehoppe/go-play-in-the-band |
| JammLab (adapted) | Single-source-node playback design | MIT | https://github.com/cyberflow/JammLab |
| MSAF (adapted) | Foote novelty segmentation | MIT | https://github.com/urinieto/msaf |

## Models

| Model | Use | Licence | Source |
|---|---|---|---|
| HTDemucs 6-source (bundled) | Splits songs into parts | Code MIT (Meta); the weights are not covered by the MIT licence and are described by their author as for research purposes. Used converted to Core ML, in a free, non-commercial app, with credit (owner decision 10). | https://github.com/adefossez/demucs |
| Lead/rhythm guitar HTDemucs 2-source (bundled) | Splits lead from rhythm guitar | Checkpoint trained by "drypaint" (community); no licence published | https://huggingface.co/noblebarkrr/mvsepless_resources |
| Beat This! small (bundled) | Beat tracking | MIT, (c) 2024 Institute of Computational Perception, JKU Linz | https://github.com/CPJKU/beat_this |
| BS-RoFormer SW and MDX23C DrumSep (downloaded on request) | Cleaner parts, drum kit | No licence published (BS-RoFormer SW); CC BY-NC-SA 4.0 (MDX23C DrumSep) | https://github.com/alexpizarro/backline/releases/tag/models-1 |

## Fonts

| Font | Licence | Source |
|---|---|---|
| Plus Jakarta Sans | SIL Open Font License 1.1 | https://github.com/tokotype/PlusJakartaSans |
| JetBrains Mono | SIL Open Font License 1.1 | https://github.com/JetBrains/JetBrainsMono |
| Permanent Marker (Font Diner) | Apache License 2.0 | https://fonts.google.com/specimen/Permanent+Marker |
