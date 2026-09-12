# Contributing to BreakBar

BreakBar is a maintainer-directed project. Bug reports and focused feature
proposals are welcome, but pull requests are considered only after the maintainer
has explicitly signed off on the proposed implementation in a linked issue.

## Proposing a change

- Search the existing issues and pull requests first.
- Open an issue describing the problem and the user-visible outcome before
  investing in an implementation intended for this repository.
- Discuss the proposal in that issue and wait for explicit maintainer signoff
  before opening a pull request. An issue by itself is not approval to proceed.
- Pull requests without that signoff will likely be closed without review.
- Report security or privacy vulnerabilities privately as described in
  [SECURITY.md](SECURITY.md), not in a public issue.

If you want to make a change independently, fork the repository and maintain
the change there. If you believe it would help other BreakBar users, file an
issue so the idea can be discussed before any upstream implementation begins.

## Development setup

For approved upstream work or development in a fork, BreakBar requires macOS 14
or later, Swift 6, and a compatible Xcode toolchain. The Makefile currently
defaults to `/Applications/Xcode-beta.app`; override `DEVELOPER_DIR` if your
compatible Xcode is installed elsewhere.

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

Open a pull request only after receiving explicit maintainer signoff in a
linked issue, and keep the implementation within the agreed scope. Keep pull
requests narrow and explain both the user-facing outcome and the reason for the
change. Add deterministic tests for behavior changes and update documentation
when behavior changes.

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
