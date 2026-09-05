# BreakBar agent guide

These instructions apply to the entire repository. Read the relevant files in
`.claude/guidelines/` before changing code; they are the detailed contracts for
architecture, testing, invariants, and releases. Use
`planning/BreakBar V1 Design.md` for product intent, but prefer the current code
and tests when the design document has drifted.

## Product boundaries

- BreakBar is a Swift 6 menu-bar app for macOS 14 and later. The Mac owns timer
  policy, scheduling, persistence, and state-machine truth.
- External hardware is an optional accessory/plugin. The Mac app must remain
  complete and usable when no accessory is connected.
- Keep `BreakBarCore` deterministic and free of UI, OS-service, persistence,
  networking, and hardware dependencies. Put SQLite work in
  `BreakBarPersistence` and OS adapters/presentation in `BreakBarApp`.
- Route state changes through typed `BreakCommand` events. Persist a transition
  before publishing its UI or side effects.
- Calendar access is read-only. Do not persist calendar titles, captured audio,
  browser history, meeting participants, credentials, or other unnecessary
  personal data.
- BreakBar is an agent-style app (`LSUIElement`). Closing Settings, Today's
  History, or another auxiliary window must not terminate it; quitting is an
  explicit menu action.

## UI and timer behavior

- Reuse `StableTimerText` for countdowns inside SwiftUI views. It deliberately
  uses Menlo, a fixed-width frame, a maximum-width hidden sample, and disabled
  animation to prevent digit jitter.
- The menu-bar countdown is rendered as a fixed-size `NSImage` in `AppDelegate`.
  Preserve the monospaced font, explicit drawing coordinates, and small set of
  status-item width buckets. A variable-width SwiftUI label or a width derived
  from the current digits will reintroduce jitter or excessive menu-bar spacing.
- Avoid duplicate state icons. The status item supplies the menu-bar icon;
  countdown components should render the timer text assigned to them, not add a
  second state icon.
- Only redraw or publish timer presentation when the displayed value or state
  changes. Keep ticks aligned to second boundaries rather than accumulating a
  repeating interval's drift.
- Warnings require both a notification and a sound. Preserve accessible labels
  and a Mac-side escape from every overlay.

## Development and verification

- Use the repository Make targets instead of ad hoc Swift commands:

  ```sh
  make build
  make test
  ```

- Run both commands for every code change. State-machine, scheduling, and
  persistence tests must use fixed dates and synthetic inputs rather than wall
  clock sleeps or live permissions.
- For UI or integration changes, also test the actual app bundle. Quit only the
  specific development instance you launched before starting another; do not
  use a name-wide kill command that could terminate an installed production
  copy. Confirm with the maintainer if the development process cannot be
  identified unambiguously. Then launch one development instance:

  ```sh
  make run
  ```

- Normal and demo modes use separate databases. Use `make demo` only for an
  accelerated timer walkthrough; do not treat demo history as normal-mode
  persistence evidence.
- Manual acceptance should cover the menu-bar countdown, popover actions,
  notifications/sounds, Settings, Today's History, window closing, restart
  recovery, and any OS integration touched by the change. Hardware behavior
  cannot be declared verified until tested against the physical device and its
  actual firmware/API.
- The Makefile currently selects the installed Xcode beta because the standalone
  Command Line Tools may have a compiler/SDK mismatch. Override `DEVELOPER_DIR`
  only when a compatible Xcode is known to be installed.

## Git and pull requests

- Start work from an up-to-date, clean `main` and create a `codex/` branch. Do
  not push feature work directly to `main`.
- Keep changes narrow, preserve unrelated user work, stage explicit paths, and
  follow `.github/PULL_REQUEST_TEMPLATE.md`.
- Before opening a PR, run `make build`, `make test`, and the relevant manual
  acceptance checks. Record the exact results in the PR.
- This repository uses CodeRabbit (and may also use Gemini Code Assist), not
  Greptile. Address every actionable review thread, rerun gates after changes,
  and confirm CI and review state after the final push.
- After a PR is merged and its upstream branch is deleted, return to `main`,
  pull the latest changes, and delete the local topic branch before starting the
  next task.

## Releases and signing

- BreakBar is distributed outside the Mac App Store through GitHub Releases and
  the GitHub Pages site. Releases must be Developer ID-signed, hardened-runtime
  enabled, notarized by Apple, stapled, and shipped with a SHA-256 checksum.
- Use `scripts/bump-version.sh patch|minor|major`; never hand-edit bundle version
  fields. Build release notes from the complete change range since the previous
  tag.
- Prefer the protected GitHub Actions `Release` workflow. Keep a release draft
  until its target commit, assets, and recorded digest are correct. Never publish
  an unsigned fallback or a partially verified artifact.
- Signing certificates, private keys, passwords, and API credentials belong in
  1Password, the macOS login keychain, and protected GitHub secrets—not in the
  repository, command output, workflow artifacts, release notes, or logs. Do not
  print or inspect secret contents. Files moved to Trash are still recoverable
  and must not be treated as securely erased.
- A local Developer ID identity is usable only when the certificate and private
  key are paired in the login keychain. Keychain may require the maintainer to
  authorize `codesign`; never ask the maintainer to reveal a password.
- Restricted/sandboxed shells can misleadingly report zero signing identities,
  an invalid signature, an invalid entitlement blob, or an internal Code Signing
  error because they cannot reach macOS trust/keychain services. Before declaring
  an artifact broken, repeat signature and Gatekeeper checks in a native macOS
  context with approved keychain/security access.
- Validate the final ZIP, not only the build directory: download or copy it to a
  fresh directory, verify the checksum, extract it, and run:

  ```sh
  codesign --verify --deep --strict --verbose=2 BreakBar.app
  xcrun stapler validate BreakBar.app
  spctl --assess --type execute --verbose=2 BreakBar.app
  codesign -d --entitlements - --xml BreakBar.app
  ```

  Gatekeeper must report `source=Notarized Developer ID`, and the entitlement
  output must include `com.apple.security.automation.apple-events` so break-time
  media pausing continues to work.
- After publication, download the public release asset and repeat the checksum,
  signature, stapler, Gatekeeper, and entitlement checks. A successful workflow
  alone is not the final consumer-path verification.
