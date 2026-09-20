# BreakBar testing guidelines

Maintainerd audits and reviewers read this file; edit it freely as the project conventions evolve.

- Run `make test` for every code change and `make build` before opening a pull request.
- Test scheduler and state-machine behavior with fixed dates and direct commands; tests must not depend on wall-clock sleeps.
- Cover each guarded transition with accepted, rejected, and idempotent cases where applicable.
- Persistence tests must use isolated temporary databases and verify both the current schema and every supported migration path.
- Recovery tests must reopen persisted state and confirm deadlines and interval history are preserved.
- Verify calendar and call behavior using synthetic constraints and signals rather than requiring live permission or a real meeting.
- Keep adapter failure tests deterministic; mock only the operating-system or hardware boundary, not the state machine under test.
- Use `make test-ui` for the isolated Settings and privacy acceptance smoke test. Treat normal app launch, permissions, menu-bar rendering, overlays, and restart recovery as manual acceptance checks until those flows gain UI automation.
- Hardware acceptance claims require the physical device and recorded firmware/API version; simulator or fake-server results are not substitutes.
- TODO: Expand SwiftUI/AppKit accessibility automation beyond Settings and add a machine-readable coverage command.
