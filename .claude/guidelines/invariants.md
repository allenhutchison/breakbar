# BreakBar architectural invariants

Maintainerd architecture audits read this file; edit it freely and review every rule before relying on it as a complete contract.

- TODO: Human-review and expand this list as the remaining V1 milestones are implemented.
- The Mac owns policy, scheduling, durable history, and state-machine truth. No accessory or provider may become authoritative for a timer.
- Accessories are optional plugins. Disconnecting or removing one must not change the meaning or progress of the Mac timer.
- A state transition is durably committed before its resulting presentation or side effects are published.
- At most one work session and one compatible primary interval may be open in SQLite.
- Schema migrations are versioned, transactional, preserve existing history, and reject databases newer than the app understands.
- A normal break cannot return to focus before its configured minimum; waking the Mac or exiting the screensaver never ends a break.
- Active detected or manual meetings suppress visible break enforcement. An overdue meeting ends with a full warning period, not an immediate forced overlay.
- Idle detection must not override a deliberate break, lunch, or active meeting, and tentative away time requires explicit classification after return.
- Calendar data is read-only, microphone audio is never captured, and derived call state contains only the minimum identity needed for scheduling.
- Every overlay has an accessible Mac-side safety escape; hardware or network failure can never trap the user.
