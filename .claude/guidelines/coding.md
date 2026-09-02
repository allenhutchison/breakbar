# BreakBar coding guidelines

Maintainerd audits and reviewers read this file; edit it freely as the project conventions evolve.

- Use Swift 6 and support macOS 14 or newer.
- Keep `BreakBarCore` deterministic and independent of SwiftUI, AppKit, EventKit, Core Audio, SQLite, networking, and hardware SDKs.
- Keep persistence and migrations in `BreakBarPersistence`; UI models must not become the database layer.
- Route user, provider, and accessory actions through typed `BreakCommand` events and the shared state machine.
- Publish UI state only after the corresponding durable transition succeeds.
- Keep calendar, call, idle, media, and accessory integrations behind focused adapters in `BreakBarApp` or a dedicated optional module.
- Make accessory integrations capability-based and optional. The Mac app remains fully usable without attached hardware.
- Prefer structured concurrency and explicit actor or main-actor isolation for shared mutable state.
- Present recoverable integration failures to the user without corrupting timer state or trapping them in an overlay.
- Never log or persist credentials, microphone content, browser history, meeting participants, or calendar titles by default.
- Coalesce repeated presentation updates when their rendered value has not changed.
- TODO: Choose and configure a non-mutating Swift formatting and linting check before making either a PR gate.
