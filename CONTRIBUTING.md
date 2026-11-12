# Contributing to Backline

Backline is a personal project: one person decides what goes in. **Bug reports and ideas are welcome as
issues. Pull requests aren't taken for now.** You're free to fork it under the MIT licence.

## Reporting a bug

Open an issue with the **Bug report** form. The most useful details are:

- your Mac (chip and memory) and the macOS version;
- the Backline version (Backline > About Backline);
- what you did, what you expected, and what happened instead;
- for a song that splits badly or a link that fails, the kind of song or the link. Please don't attach
  music you don't have the rights to share;
- for a crash, the report from Console > Crash Reports (files starting with `Backline`).

Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Building

See [Build from source](README.md#build-from-source) in the README: Xcode 26, XcodeGen and Git LFS, then
`xcodegen generate`. The Xcode project is generated and not committed. After adding or moving a file, run
`xcodegen generate` again.

## If you work on a fork

These are the rules this repository follows. A change that keeps them is easier to bring back.

- **Nothing leaves the Mac** except what the user asked for: a link they pasted, the model download, and
  the Google sign-in page they opened. No analytics, no tracking, no accounts.
- **Tests.** `swift test --package-path BacklineKit` passes before each change.
- **README.** Every release updates the README and its screenshots (the `readme-reviewed-for` line at
  the end says which version it was last checked for).
- **Commits.** `type: what changed and why`, then bullet points. Types: `feat`, `fix`, `refactor`,
  `docs`, `chore`, `test`.

By sending code or text to this repository you agree it's released under the [MIT licence](LICENSE).
