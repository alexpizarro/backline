# QuickJS-NG (JavaScript runtime for yt-dlp's YouTube challenge solver)

- Upstream: https://github.com/quickjs-ng/quickjs — release v0.17.0, asset `qjs-darwin-arm64`
- License: MIT (see LICENSE)
- Why: YouTube serves some formats only after solving an obfuscated JS "n"/signature challenge. yt-dlp's
  bundled `yt-dlp-ejs` solver needs a JS runtime; QuickJS-NG ≥ 0.12 is supported and fast. It is 1.3 MB,
  arm64, and links only libSystem — so Backline never uses a Deno/Node the user may have installed.
- Embedded by `scripts/embed-ytdlp.sh` at `Contents/Resources/yt-dlp/qjs`, signed with the helper
  entitlements (sandbox + inherit), SHA-256 checked against `SHA256`.
- Update: download the new `qjs-darwin-arm64`, update `SHA256`, run a YouTube import.
