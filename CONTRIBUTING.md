# Contributing to BreakBar

Thanks for helping improve BreakBar. Bug reports, focused feature proposals,
documentation improvements, and code contributions are welcome.

## Before opening a change

- Search the existing issues and pull requests first.
- Open an issue before investing in a substantial feature or architectural
  change so its product fit and scope can be discussed.
- Report security or privacy vulnerabilities privately as described in
  [SECURITY.md](SECURITY.md), not in a public issue.

## Development setup

BreakBar requires macOS 14 or later, Swift 6, and a compatible Xcode toolchain.
The Makefile currently defaults to `/Applications/Xcode-beta.app`; override
`DEVELOPER_DIR` if your compatible Xcode is installed elsewhere.

Build and test with the repository targets:

```sh
make build
make test
```

Launch a development build with:

```sh
make run
```

The app appears only in the menu bar. Normal and demo modes use separate local
databases; `make demo` is useful for an accelerated timer walkthrough but is
not evidence for normal-mode persistence behavior.

## Project boundaries

- Keep `BreakBarCore` deterministic and independent of UI, persistence,
  networking, hardware, and operating-system services.
- Keep SQLite work in `BreakBarPersistence` and OS adapters and presentation in
  `BreakBarApp`.
- Route state changes through typed `BreakCommand` events, and persist a
  transition before publishing its UI or side effects.
- Keep accessories optional. The Mac app must remain complete without them.
- Do not log or persist credentials, calendar titles, captured audio, browser
  history, meeting participants, or other unnecessary personal data.

See [AGENTS.md](AGENTS.md) and the files in
[`.claude/guidelines`](.claude/guidelines/) for the detailed architecture,
testing, privacy, UI, and release contracts.

## Pull requests

Keep pull requests narrow and explain both the user-facing outcome and the
reason for the change. Add deterministic tests for behavior changes and update
documentation when behavior changes.

Before submitting:

```sh
make test
make build
git diff --check
```

For UI or integration changes, also test the built app and describe the manual
acceptance performed. Do not claim hardware behavior is verified without the
physical device and its actual firmware/API.

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
