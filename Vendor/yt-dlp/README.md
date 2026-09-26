# YouTube downloader (yt-dlp, compiled from source)

`yt-dlp-native-arm64.zip` is Backline's own build of [yt-dlp](https://github.com/yt-dlp/yt-dlp)
(Unlicense), made by `scripts/build-ytdlp.sh`:

- Source: the official `yt-dlp.tar.gz` of release 2026.08.19, SHA-256 checked.
- Compiled to native arm64 code with [Nuitka](https://nuitka.net) (standalone, CPython runtime inside),
  on a standalone CPython, so nothing links to the build machine.
- Only the YouTube and generic extractors are included. Backline only ever passes a
  `https://www.youtube.com/watch?v=<id>` link.
- Its libraries and their licences are listed in `BUILD-INFO.txt` and bundled under `licenses/` in the zip.

`scripts/embed-ytdlp.sh` (an Xcode build phase) checks the zip against `yt-dlp-native-arm64.zip.sha256`,
unpacks it to `Contents/Resources/yt-dlp`, adds [QuickJS-NG](https://github.com/quickjs-ng/quickjs) for
YouTube's JavaScript checks, and signs everything inside-out for the App Sandbox.

**To update:** change `YTDLP_VERSION` and `YTDLP_SHA256` in `scripts/build-ytdlp.sh` and run it. It takes
about 15 minutes the first time and needs Xcode's command-line tools and [uv](https://docs.astral.sh/uv/).
