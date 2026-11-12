# Security

## Reporting a vulnerability

Please report it privately with GitHub's **Report a vulnerability** button, in this repository's
**Security** tab. Don't open a public issue. A fix ships in the next release.

## What's in scope

Backline runs everything on the Mac and has no server of its own. The parts that handle data from
outside are:

- **YouTube import**: the bundled yt-dlp helper and QuickJS (`Vendor/`, run as separate processes),
  and the cookies Backline hands them after you sign in;
- **the Google sign-in web view** (`YouTubeSignIn.swift`, allow-listed hosts only);
- **model downloads** (`ModelDownloads.swift`): checked against a SHA-256 before use;
- **imported files** and **Record from an app** (Core Audio process tap, only the app you pick);
- **the installer** (`Backline.dmg`): signed with a Developer ID and notarized by Apple.

Only the latest release in [Releases](https://github.com/alexpizarro/backline/releases) is supported.
