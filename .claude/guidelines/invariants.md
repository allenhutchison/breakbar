# BreakBar architectural invariants

Maintainerd architecture audits read this file; edit it freely and review every rule before relying on it as a complete contract.

- TODO: Human-review and expand this list as the remaining V1 milestones are implemented.
- The Mac owns policy, scheduling, durable timer recovery, and state-machine truth. No accessory or provider may become authoritative for a timer.
- Accessories are optional plugins. Disconnecting or removing one must not change the meaning or progress of the Mac timer.
- A state transition is durably committed before its resulting presentation or side effects are published.
- Live timer transitions save only the current recovery snapshot; do not record new work sessions, activity intervals, or transition history. Preserve legacy history for export/deletion.
- Schema migrations are versioned, transactional, preserve existing history, and reject databases newer than the app understands.
- A normal break cannot return to focus before its configured minimum; waking the Mac or exiting the screensaver never ends a break.
- Active detected or manual meetings suppress visible break enforcement. Refreshed calendar deletions and shortened events must release stale suppression. An overdue meeting ends with a full warning period, not an immediate forced overlay.
- Idle detection must not interrupt an active meeting or end a deliberate break before its minimum. Resume automatically after sufficient time away; short absences preserve the focus deadline. Explicit pause survives activity and restart.
- Calendar data is read-only, microphone audio is never captured, and derived call state contains only the minimum identity needed for scheduling.
- Every overlay has an accessible Mac-side safety escape; hardware or network failure can never trap the user.
