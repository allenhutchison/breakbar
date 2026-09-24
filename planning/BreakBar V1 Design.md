# BreakBar V1

## Product and Technical Design

**Status:** Implementation-ready draft

**Platform:** Native macOS menu-bar application

**Optional accessory:** BUSY Bar on the home LAN

**Last updated:** August 31, 2026

---

## 1. Executive summary

BreakBar is a native macOS menu-bar application that prevents long, uninterrupted periods of sitting while working from home. It combines a Mac-driven visible countdown, calendar-aware scheduling, live meeting detection, and a deliberately disruptive full-screen overlay. Optional accessory plugins can mirror state and provide additional acknowledgement controls; the first supported accessory is a BUSY Bar placed across the room.

The experience is built around a simple behavioral loop:

1. The user explicitly clocks in.
2. BreakBar plans the next break around calendar commitments while counting seated work and meeting time.
3. Five minutes before a break, BreakBar warns the user and shows a countdown.
4. When the break is due, a full-screen overlay interrupts work.
5. The user starts the break from the Mac or a configured accessory. That action dismisses the overlay, starts the macOS screensaver, and begins a minimum five-minute break.
6. After five minutes, the Mac changes from a minimum-break countdown to an extended-break count-up. The user returns from the Mac or a configured accessory to start a fresh focus interval. An earlier return is rejected.

When installed, the BUSY Bar is also the family-facing status display. It shows `BUSY`, `MEET`, `BREAK`, `LUNCH`, `AWAY`, or `FREE`, with useful countdowns or elapsed time. The Mac is always the source of truth; accessory availability never changes the meaning or progress of a timer.

### 1.1 Mac-first product boundary

BreakBar must be complete and useful with no external hardware. The built-in Mac interaction is the baseline input/output plugin and cannot be disabled. Accessories may add remote presentation, sound, presence, or physical input, but they cannot own scheduling, persistence, or an otherwise unavailable transition.

The accessory boundary is capability-based rather than BUSY-specific:

```text
BreakBar core ── presentation ──▶ Mac UI (always present)
       │
       └── presentation ──▶ Accessory plugins (zero or more)

Mac commands ──────────────▶ typed app events
Accessory input plugins ───▶ typed app events
```

V1 accessory plugins are trusted, compile-time Swift modules conforming to `BreakBarAccessory`. Dynamic third-party loading, process isolation, and a public plugin SDK are deferred until the protocol has been proven with real hardware.

Calendar integration is required in V1. Scheduled meetings influence break placement, but calendar end times are not blindly trusted: recognized video-call or audio activity can keep the app in `MEETING` after a scheduled event ends. If a break is overdue when the actual call ends, the user still receives a five-minute warning before the overlay.

Travel is a first-class forced-away transition. A classified travel calendar block produces a five-minute departure warning, then a `TIME TO GO` overlay at the travel start. Break enforcement and the focus timer are suspended while traveling and through a connected offsite meeting. Returning home or explicitly resuming starts a fresh focus interval.

All state changes are written to a local SQLite database. BreakBar derives daily summaries and exports an idempotent Markdown section into configured Obsidian daily notes.

> **Hardware validation requirement:** BUSY’s published materials indicate local HTTP control over USB or Wi-Fi, custom drawing on a 72×16 RGB front display, audio control, state APIs, and input forwarding. Exact endpoints, event semantics, ownership of the physical controls, authentication behavior, update rates, and coexistence with built-in apps must be validated against the purchased device’s installed firmware and its device-hosted OpenAPI definition before the integration is considered complete.

---

## 2. Problem and product intent

Ordinary calendar alerts and watch stand reminders are too easy to dismiss without physically leaving the desk. A useful system must interrupt attention, require movement, respect meetings, and remain pleasant enough not to be disabled after a few days.

BreakBar is therefore not a conventional Pomodoro app. Its purpose is to enforce a physical context switch at a healthy cadence while fitting around the realities of a workday: meetings overrun, lunch is not a five-minute break, travel takes the user away from the home office, and the user may forget to classify time perfectly.

### 2.1 Product principles

- **Movement is the goal; a working app is the prerequisite.** Mac controls provide the complete flow. A remote physical control can strengthen the movement contract when an accessory is configured.
- **Five minutes is a minimum, not a fixed break length.** Longer walks are expected and welcomed.
- **Calendar is a plan; live activity is evidence.** A scheduled meeting can predict a conflict, while active call audio may prove that the meeting is still happening.
- **No surprise interruption during an active call.** A call may defer enforcement; when it ends, the normal five-minute warning is preserved.
- **The Bar communicates to the household.** Text carries the meaning; color is only reinforcement.
- **The Mac owns policy and history.** Device firmware state is never the only copy of a timer or work log.
- **Fail safe for the person, not for timer purity.** Every overlay has accessible deferral or clock-out controls, and accessory failure never traps the user.
- **Local-first and inspectable.** No cloud service is needed for core behavior or time history.

---

## 3. Goals and non-goals

### 3.1 V1 goals

1. Make the user stand up approximately once per hour during an explicitly started work session.
2. Provide a native menu-bar countdown and a hard-to-ignore full-screen interruption on the single active display.
3. Support optional accessory plugins, beginning with the BUSY Bar over Wi-Fi as a family-facing status sign and remote physical break control.
4. Respect scheduled meetings and detect actual call continuation beyond the calendar end.
5. Pull a break forward when an upcoming meeting would otherwise consume its deadline.
6. Model lunch, travel, offsite meetings, unclassified idle time, and clocked-out time separately from focus and normal breaks.
7. Record trustworthy local interval history and daily totals.
8. Export a stable, regenerable work section to Obsidian daily notes.
9. Continue useful behavior when the Bar, calendar permission, call detection, Obsidian vault, or network is unavailable.

### 3.2 Non-goals for V1

- Team presence, Slack/Teams status synchronization, or a shared web service.
- Remote control of the Bar through BUSY’s cloud.
- Apple Watch, iPhone, or iPad companion apps.
- Productivity scoring, keystroke logging, screenshots, content inspection, or employee monitoring.
- Automatic inference of which project or task is being worked on.
- Editing calendar events.
- Full timesheet, billing, payroll, or HR functionality.
- Perfect recognition of every browser-based or unusual calling application.
- Multi-device synchronization.
- Automatic proof that the user walked; a deliberate break-start action is the V1 proxy, strengthened by a remote accessory when configured.
- Firmware modification. V1 uses the supported device interface only.

---

## 4. V1 defaults and configurable policy

| Setting | V1 default | Meaning |
| --- | ---: | --- |
| Target seated interval | 55 minutes | Preferred time from a completed break, lunch, or return until the next break begins |
| Warning duration | 5 minutes | Wrap-up period before a normal break or travel departure |
| Minimum normal break | 5 minutes | Earliest time the user may return to focus |
| Maximum seated interval | 75 minutes | Best-effort ceiling when not in a live call or higher-priority transition |
| Idle threshold | 10 minutes | Inactivity duration before time is tentatively classified as away |
| Device refresh | 1 second or event stream | Maximum normal lag for visible countdown and input handling |
| Meeting join tolerance | 5 minutes before/after boundary | Window for associating call activity with a calendar event |
| Travel adjacency | 15 minutes | Default maximum gap for linking travel and an offsite meeting |

The 55-minute target is a preference. The 75-minute ceiling is enforced whenever the user is not in a detected live call. A live call, travel deadline, explicit five-minute deferral, or system failure may violate it; BreakBar records the reason rather than disrupting an unsafe or socially inappropriate moment.

---

## 5. User experience

### 5.1 Onboarding

The first launch is a short setup assistant:

1. Explain the start-break / return-to-focus loop.
2. Request Calendar access and select included calendars.
3. Explain call detection and show recognized applications.
4. Optionally select the Obsidian vault, daily-note folder, and filename format.
5. Offer launch-at-login.
6. Run a two-minute guided dry run without writing work history.
7. Optionally install and configure an accessory plugin. The BUSY plugin discovers or accepts the Bar’s reserved LAN address, verifies firmware/API version and credentials, tests the chosen input, and previews its display.

When the BUSY plugin is configured, setup recommends a DHCP reservation on the router rather than a device-configured static address. Discovery by mDNS may be used, but the reserved address is the stable fallback.

### 5.2 Clocked out

BreakBar performs no break enforcement. The menu-bar item is neutral and offers `Clock In`. A connected Bar shows `FREE` or the user’s chosen neutral clock face. No calendar titles or call activity are logged while clocked out.

Clock-in is explicit in V1. The app may suggest it when work-like activity or a selected-calendar meeting is observed, but it does not start a session automatically.

Clocking out:

- closes the current interval and work session;
- cancels warnings and planned breaks;
- removes any BreakBar overlay;
- stops using call activity for scheduling;
- updates the Bar to `FREE`;
- recomputes and exports the daily summary;
- asks for classification if unresolved idle time would materially affect the summary.

### 5.3 Focus

On clock-in or a completed return, a fresh focus interval begins. The menu-bar label shows the time until the planned break, for example `42:18`. Its menu shows:

- current state and timer;
- planned break time and the reason for any adjustment;
- seated since;
- next calendar constraint;
- today’s focus, meeting, break, lunch, and away totals;
- accessory connection status;
- `Take Break`, `Start Lunch`, `Go Away`, and `Clock Out` actions.

A connected Bar shows `BUSY 42:18`. A color such as red may reinforce “do not interrupt,” but text is authoritative.

### 5.4 Normal break warning

At five minutes before the planned break:

- the menu-bar label changes to a warning form such as `⚠ 5:00`;
- one macOS notification and one audible cue say “Break in 5 minutes—find a stopping point”;
- a connected Bar remains family-facing `BUSY`, with a short countdown if it fits;
- the state is logged as warning metadata, not as a separate working-time category.

If a call begins during the warning, the warning is suspended and the meeting takes precedence. When the call actually ends, a new full five-minute warning begins if the break remains due.

### 5.5 Break required

At the planned break time, BreakBar displays a full-screen overlay on the active display:

> **TIME TO GET UP**  
> Start your break on this Mac or with a connected accessory.

The overlay is visually dominant, avoids destructive app manipulation, and does not close or alter the user’s work. It blocks ordinary clicks from dismissing it. The menu bar and connected display accessories show `BREAK`.

The overlay always provides visible five-minute deferral and clock-out controls, described in Section 16. It must never imitate a macOS login screen or hide how to regain control.

### 5.6 Active break: the start/return contract

A valid `Start Break` command from the Mac or an accessory in `BREAK_REQUIRED` performs one atomic transition:

1. persist `break_started_at`;
2. remove the overlay;
3. display `BREAK 5:00` on the Mac and connected display accessories, counting down the remaining minimum;
4. start the macOS screensaver on a best-effort basis;
5. start the break interval.

At five minutes, the display changes to elapsed overtime:

```text
BREAK +0:00
BREAK +7:18
```

A `Return to Focus` command ends the break only if at least five minutes have elapsed. The Mac keeps that action disabled until then. If an accessory sends it early, BreakBar keeps the break active, optionally plays a gentle rejection sound, and briefly shows the remaining minimum, such as `2:13 MORE`.

The break does not end because the Mac wakes, the screensaver exits, the mouse moves, or the app restarts. A deliberate `Return to Focus` command ends it. Ending the break starts a fresh 55-minute interval.

### 5.7 Meetings

A connected Bar shows `MEET 18:42` during an in-progress scheduled meeting. If the calendar end passes while recognized call activity continues, it shows an elapsed overrun such as `MEET +03:12`.

Meeting detection uses layered evidence:

- included calendar event currently in progress;
- recognized application with live audio input, and optionally output;
- browser/application context when safely available;
- a small start/end debounce to avoid toggling on device reconfiguration.

Calendar events alone are enough to reserve time and present `MEETING`; actual audio activity may extend that state. Call activity outside a calendar event may also produce `MEETING` when confidence is high.

When an overdue meeting ends, the app starts a fresh five-minute warning. It never goes directly from live call to forced overlay unless the user explicitly chooses a stricter future policy.

### 5.8 Lunch

Lunch is a non-working state inside an open work session. It does not clock the user out, does not count toward working time, suppresses normal break enforcement, and resets the seated cycle on return.

Lunch may begin through:

- `Start Lunch` in the menu;
- classification of an idle interval;
- an accessory action mapped during a configured lunch event;
- a calendar-derived prompt at the start of an event classified as lunch.

V1 does not force lunch merely because a calendar event starts while the user remains active. The event is strong default evidence, not permission to rewrite observed time. A connected Bar shows `LUNCH` or optionally `LUNCH +32m`; no return countdown is required. `End Lunch` starts a fresh focus interval.

### 5.9 Idle and unclassified away time

After the configured idle threshold, BreakBar tentatively enters `AWAY_UNCLASSIFIED` and retroactively starts that interval at the last observed input time. A connected Bar shows `AWAY`. On return, the menu presents:

> You were away for 48 minutes.  
> **Lunch · Break · Meeting · Other away · Count as work**

If the interval overlaps a classified lunch event, `Lunch` is preselected. If it overlaps travel, travel rules take precedence and no ambiguous prompt is shown. A deliberately started break is already classified and never generates this prompt.

`Meeting` records the idle interval as meeting time, ending at the detected return, then starts a fresh focus cycle. `Count as work` restores the interval as focus according to the current implementation. `Break` counts as a break but does not fabricate start/return enforcement history. `Other away` remains inside the clocked-in span but is excluded from actual working time.

### 5.10 Travel and offsite meetings

A calendar event classified as travel is a scheduled forced-away transition.

Five minutes before it begins:

- the menu-bar item shows `Leave 5:00`;
- a non-modal warning appears;
- the Bar continues to show the present family status until the travel start.

At the travel start:

- a full-screen `TIME TO GO` overlay appears, including the next event/location when allowed;
- connected display accessories change immediately to `AWAY`;
- the focus/break scheduler is suspended;
- seated-time accumulation stops;
- an interval of type `travel` begins.

Unlike a normal break, travel does not require a separate break-start command. The overlay can be acknowledged with a deliberate Mac action, an accessory action, or trusted evidence that the Mac has left the home environment. This avoids trapping the user while carrying the laptop out.

An adjacent meeting marked offsite, or a meeting linked between outbound and return travel blocks, keeps the family-facing state `AWAY`. It is logged as a meeting with `location_context = away`, so reporting can distinguish travel from offsite meeting time without advertising `MEETING` on a Bar left at home.

Ending a travel block does not prove the user is home. BreakBar remains `AWAY` until one of these conditions is met:

- the offsite event chain has ended and the BUSY Bar/home-LAN presence is detected;
- the configured home-network signal is detected; or
- the user explicitly chooses `Return Home / Resume Focus`.

Return never resumes a partially used timer. It starts a fresh focus interval.

---

## 6. State model

A single flat enum cannot correctly represent “clocked in, in an offsite meeting, and away from home.” V1 therefore uses one authoritative state snapshot with three orthogonal regions plus a transient enforcement phase.

### 6.1 State regions

| Region | Values | Purpose |
| --- | --- | --- |
| Session | `CLOCKED_OUT`, `CLOCKED_IN` | Whether workday behavior and logging are active |
| Activity | `NONE`, `FOCUS`, `MEETING`, `BREAK`, `LUNCH`, `TRAVEL`, `AWAY_UNCLASSIFIED` | What the interval means in the time log |
| Location | `HOME`, `AWAY`, `UNKNOWN` | Whether home-office break enforcement is appropriate |
| Enforcement | `NONE`, `BREAK_WARNING`, `BREAK_REQUIRED`, `TRAVEL_WARNING`, `TRAVEL_REQUIRED` | Temporary user-interruption phase |

Derived output maps the combination to menu-bar, overlay, and Bar presentations. For example:

- `CLOCKED_IN + MEETING + AWAY` → log offsite meeting, suspend scheduler, Bar `AWAY`.
- `CLOCKED_IN + FOCUS + HOME + BREAK_WARNING` → count focus, menu warning, Bar `BUSY`.
- `CLOCKED_IN + BREAK + HOME` → break countdown/count-up, no overlay after the break-start command.

### 6.2 Authoritative state snapshot

Every transition produces an immutable snapshot containing:

```text
session_id
session_state
activity
location
enforcement
activity_started_at
last_meaningful_stand_at
nominal_break_due_at
planned_break_at
warning_started_at?
minimum_break_ends_at?
active_calendar_event_ids[]
active_call_evidence?
away_chain_id?
transition_reason
revision
```

All actions are serialized through a single scheduler/state-machine actor. UI, device, calendar, idle, and audio monitors emit events; they never mutate state directly.

### 6.3 Core transition table

| Current condition | Event/guard | Result | Required side effects |
| --- | --- | --- | --- |
| Clocked out | Clock In | Focus, home/unknown | Open session; start fresh cycle; update Bar |
| Focus | Planned break − 5m | Break warning | Notice; warning countdown |
| Break warning | Planned break reached; no call/travel | Break required | Persist; show overlay; Bar `BREAK` |
| Break warning/required | Live call begins | Meeting; enforcement none | Remove normal overlay if necessary; recompute after call |
| Break required | Start Break from Mac/accessory | Break active | Commit start; hide overlay; start screensaver; minimum countdown |
| Break active, <5m | Return command | No state change | Reject; show remaining time |
| Break active, ≥5m | Return command | Focus | Close break; fresh cycle |
| Focus/warning | Meeting starts | Meeting | Suppress normal enforcement; continue seated accumulation |
| Meeting | Calendar ends, call still active | Meeting overrun | Keep `MEETING`; show elapsed overrun |
| Meeting | Call/calendar evidence ends; break overdue | Break warning | Begin a full new five-minute warning |
| Meeting | Evidence ends; break not due | Focus | Recompute remaining seated time |
| Any clocked-in home activity | Lunch confirmed | Lunch | Close prior interval; suspend scheduler; Bar `LUNCH` |
| Lunch | End Lunch | Focus | Close lunch; fresh cycle |
| Focus/meeting | Idle threshold reached | Away unclassified | Retroactively split at last input; Bar `AWAY`; suspend scheduler |
| Away unclassified | Activity resumes | Await classification, then focus | Resolve interval; fresh cycle unless counted as work |
| Any clocked-in state | Travel warning time | Travel warning | `Leave 5:00`; normal break no longer competes |
| Any clocked-in state | Travel starts | Travel away + travel required | `TIME TO GO`; Bar `AWAY`; suspend scheduler |
| Travel | Adjacent offsite meeting starts | Meeting + away | Close travel interval; remain Bar `AWAY` |
| Away/offsite | Home return confirmed and chain ended | Focus + home | Close away state; fresh cycle |
| Any clocked-in state | Clock Out | Clocked out | Close intervals/session; clear overlay; Bar `FREE`; export |
| Any state | App relaunch | Recovered state | Reconcile persisted deadlines and external evidence |

### 6.4 Invariants

1. At most one work session is open.
2. At most one primary activity interval is open within a session.
3. Interval end is never earlier than its start.
4. `BREAK` cannot end normally before `minimum_break_ends_at`.
5. `TRAVEL`, `LUNCH`, and location `AWAY` suspend the break scheduler.
6. The Bar is never the sole holder of a deadline or state.
7. An accessory or permission failure cannot prevent clock-out or emergency overlay dismissal.
8. Every transition is idempotent by event ID and state revision.
9. Wall-clock changes do not shorten a minimum break; elapsed timers use a monotonic clock while persisted timestamps use UTC.
10. Resume after break, lunch, travel, or confirmed away starts a fresh interval unless the user explicitly reclassifies the absence as working time.

---

## 7. Scheduling and precedence

### 7.1 Time concepts

- **Seated-cycle origin:** the last return from a qualifying break, lunch, travel/away period, or clock-in.
- **Nominal break time:** origin + target seated interval.
- **Planned break time:** the nominal time adjusted around calendar constraints.
- **Warning time:** planned break time − warning duration.
- **Hard-limit time:** origin + maximum seated interval.

Focus and home-office meeting time both advance the seated cycle. Normal break, lunch, travel, and away time do not.

### 7.2 Calendar-aware pre-meeting scheduling

For each upcoming included meeting that intersects the nominal break or would push the user beyond the hard limit:

1. Compute a pre-meeting break start at `meeting.start − minimumBreak`.
2. Require enough time for the full warning before that start.
3. Require the minimum break to end no later than the meeting start.
4. If both fit, pull the planned break to that pre-meeting start.
5. Otherwise defer through the meeting and live call, then give a full five-minute post-meeting warning.

Example:

```text
10:00  seated-cycle origin
10:55  nominal break start
11:00  meeting begins

10:50  warning begins
10:55  break begins
11:00  minimum satisfied; meeting may begin
```

The engine must not repeatedly pull breaks earlier across a dense calendar. It chooses the latest feasible pre-meeting slot that protects the nominal deadline and minimum break. A manual break that satisfies the minimum invalidates the old plan and starts a new cycle.

### 7.3 Meeting overrun

If a calendar meeting ends while recognized call activity continues, meeting state continues. Once activity ends and debounce passes:

- if the nominal or hard-limit time has passed, start a new five-minute warning;
- otherwise return to focus with the original seated-cycle origin and recompute the plan.

This intentionally permits the hard limit to be exceeded by an active call. The exception is explicit and observable; V1 does not force an overlay over a live meeting.

### 7.4 Travel versus normal breaks

Travel is a higher-priority physical departure and satisfies the movement intent. If a normal break warning or deadline overlaps the travel warning/start window, cancel the normal break plan and use the travel transition. Do not issue a second break while traveling or immediately upon return. Return starts a fresh cycle.

### 7.5 Precedence order

When simultaneous evidence conflicts, apply this order:

1. **Clock out / explicit deferral** — user control and safety.
2. **Travel required** — fixed departure deadline.
3. **Confirmed away location** — do not enforce a home-office break remotely.
4. **Lunch** — explicit non-working interval.
5. **Active live call** — suppress normal forced break and preserve meeting status.
6. **Break required** — overlay and physical acknowledgement.
7. **Travel warning.**
8. **Break warning.**
9. **Scheduled meeting.**
10. **Focus.**

Higher precedence affects presentation and enforcement; it does not erase lower-level evidence needed for later reconciliation.

### 7.6 Calendar changes

Recompute the plan when EventKit signals a store change, on wake, on clock-in, and periodically as a backstop. A moved or deleted meeting may move the planned break later, but never retract a `BREAK_REQUIRED` overlay that is already visible unless a live call or higher-priority travel event begins. Once a warning has begun, moving the break later should be conservative and explain the reason in the menu.

---

## 8. Presentation mapping

| Effective state | Menu bar | BUSY Bar | Family meaning |
| --- | --- | --- | --- |
| Clocked out | neutral icon | `FREE` | Interrupt anytime |
| Focus | `42:18` | `BUSY 42m` | Please do not interrupt |
| Break warning | `⚠ 4:12` | `BUSY 4m` | Still working |
| Break required | `BREAK` | `BREAK` | Becoming available now |
| Minimum break | `☕ 3:42` | `BREAK 3:42` | Interruptible; minimum remains |
| Extended break | `☕ +7:18 ✓` | `BREAK +7m` | Interruptible |
| Meeting | `MEET 18m` | `MEET 18m` | Do not interrupt |
| Meeting overrun | `MEET +3m` | `MEET +3m` | Do not interrupt |
| Lunch | `LUNCH +32m` | `LUNCH` | Interruptible, not working |
| Travel/offsite | `AWAY` | `AWAY` | Not at home office |
| Idle away | `AWAY?` | `AWAY` | Not at desk |
| Bar disconnected | state + warning dot | last known display | Consult Mac; device may be stale |

The 72×16 front display imposes tight layout constraints. Exact abbreviations, font, animation, color, and update rate are prototype decisions to validate on hardware. The device should include a subtle freshness indicator if firmware supports one; otherwise the Mac menu must clearly report that a disconnected Bar may be stale.

---

## 9. Calendar and call detection

### 9.1 Calendar integration

Use EventKit directly. The user grants full event access because macOS does not provide read-only EventKit access for fetching existing events. BreakBar reads but never edits events.

Configuration includes:

- selected work calendars;
- excluded all-day, declined, canceled, and free-status events;
- meeting title/category patterns;
- lunch patterns such as `Lunch`;
- travel patterns such as `Travel`, `Commute`, or `Drive`;
- optional offsite indicators from location, URL, notes, or calendar selection;
- per-calendar overrides;
- whether meeting titles may be stored or exported.

Classification order is explicit travel/lunch overrides, structured location/availability hints, configured patterns, then generic busy event. Pattern matching is case-insensitive and testable in Settings. Calendar identifiers and occurrence start times, rather than titles, form stable event references.

### 9.2 Live call detector

Define a `CallActivityProvider` protocol so OS-specific approaches can evolve without changing the scheduler.

Preferred implementation on supported macOS versions:

- enumerate Core Audio process objects;
- observe process PID, bundle identifier, `isRunningInput`, and optionally `isRunningOutput`;
- match against a configurable allowlist of conferencing apps and browsers;
- correlate browser activity with an in-progress calendar event and, only if necessary and permission-safe, the browser/app’s visible context;
- debounce start and stop, for example two seconds to start and five seconds to end.

A recognized dedicated app using microphone input is high-confidence call evidence. A generic browser using input is medium-confidence and should normally require a nearby calendar meeting or user-approved browser rule. Output-only audio is insufficient by default because music and videos would be false positives.

V1 does not record audio, inspect audio content, capture meeting participants, or retain a stream of microphone usage. It stores only the derived call-active interval and optional recognized bundle ID for diagnostics.

If process-level input state is unavailable on the deployment target, the detector falls back in this order:

1. calendar-only meeting state;
2. user-maintained app heuristics and system microphone-use signal where supported;
3. manual `Meeting in progress` control.

The settings screen shows detector confidence and offers a live test. Calendar-only behavior remains fully usable when call detection is unavailable.

### 9.3 Meeting end decision

A meeting remains active while either of these is true:

- the included calendar occurrence is active; or
- associated high-confidence call evidence is active.

After the calendar event ends, only actual call evidence prolongs it. After the call ends early, the calendar occurrence still reserves meeting status unless the user manually ends it or a future configurable “follow live call” mode is introduced.

---

## 10. BUSY Bar accessory plugin

### 10.1 Responsibility boundary

BreakBar on macOS owns:

- session and activity state;
- all deadlines and scheduling;
- calendar and call interpretation;
- persistence and summaries;
- overlay and screensaver behavior;
- the semantic meaning of each button press.

The BUSY Bar provides:

- front-display text/color/animation;
- optional sound/haptic-like feedback if supported;
- physical input events;
- optional presence signal on the home LAN.

The built-in device Pomodoro timer is not authoritative in V1. It may be disabled or left unused to avoid two schedulers disagreeing.

### 10.2 Transport

- Power the Bar independently across the room.
- Connect over local Wi-Fi.
- Prefer mDNS discovery initially, verify stable device identity, and use a router DHCP reservation as fallback.
- Use local HTTP authentication if supported and store the PIN/access secret in macOS Keychain.
- Do not require BUSY cloud access.
- Prefer an event/WebSocket stream for state/input if reliable; otherwise poll input/state at approximately one second with bounded timeouts.
- Coalesce display updates and avoid repainting unchanged content.

### 10.3 Device adapter

All firmware-specific code sits behind the `BusyBarAccessory` implementation:

```text
discover() -> [Device]
connect(deviceID, address, credential)
capabilities() -> CapabilitySet
render(presentation, revision)
subscribeInputs() -> AsyncStream<InputEvent>
playFeedback(kind)
health() -> DeviceHealth
clearOwnedDisplayElements()
```

Each display write includes the BreakBar application namespace and current state revision where the API permits. Input events are debounced and interpreted according to the current state; a press received for an old revision is ignored.

### 10.4 Hardware acceptance checklist

Validate on the shipped unit and current firmware:

- local Wi-Fi HTTP access and authentication;
- mDNS advertisement and identity stability;
- device-hosted `/docs` and `/openapi.yaml` versions;
- exact front-display dimensions, fonts, colors, brightness, animation, and update limits;
- whether custom drawings persist, time out, or conflict with built-in applications;
- which physical control is appropriate and how press, release, long-press, and wheel events are exposed;
- whether input events can be streamed or must be polled;
- event latency, duplicates, and behavior during reconnect/reboot;
- sound playback and acceptable volume;
- device clock drift and whether it matters;
- firmware upgrade compatibility and recovery behavior;
- whether the API can expose a reliable local-presence signal without cloud routing.

Until these pass, UI mockups and automated fake-device tests are not proof of correct accessory behavior.

---

## 11. macOS implementation

### 11.1 Technology choice

- Swift and SwiftUI for the menu-bar interface and settings.
- AppKit for full-screen overlay windows and precise window-level behavior.
- Swift Concurrency with an actor-isolated state machine.
- EventKit for calendar events.
- Core Audio process APIs for live call evidence where supported.
- `CGEventSource.secondsSinceLastEventType` or an equivalent public API for aggregate idle duration.
- Network framework/URLSession for LAN communication.
- SQLite through a small migration-capable wrapper; avoid making UI models the database layer.
- OSLog for privacy-aware local diagnostics.
- ServiceManagement for launch at login.
- Keychain Services for the device access secret.

### 11.2 Overlay

Create a borderless AppKit window sized to the active screen, at an appropriate high level, with collection behavior that follows spaces and full-screen applications. On the user’s one-display setup, only the active display is required, but the window manager should not assume exactly one screen so adding a display cannot strand the UI.

The overlay:

- clearly identifies BreakBar and the required action;
- does not close applications or discard input;
- ignores ordinary Escape/click dismissal;
- exposes accessibility labels and sufficient contrast;
- displays device-offline fallback instructions when necessary;
- provides a visible five-minute deferral button;
- is recreated after display, space, wake, or resolution changes.

macOS prevents third-party apps from creating a truly unbreakable kiosk without elevated management. V1 should be strongly interruptive, not hostile or deceptive.

### 11.3 Screensaver

When the normal break starts, request the system screensaver using the least brittle supported mechanism available for the deployment target. Launching `ScreenSaverEngine` directly may work but is not a stable public product contract; treat it as an implementation to validate across supported macOS versions. If initiation fails, the break still starts and the error is logged. Optionally offer “lock screen instead” as an explicit user setting, never as the default.

Break state is independent of screensaver state. Waking the Mac does not end the break.

### 11.4 Sleep, wake, and clock changes

Before sleep, persist the state snapshot and outstanding monotonic durations. On wake:

- refresh calendar and device state;
- compute elapsed real time;
- if a break was active and its minimum passed, keep it active in extended mode;
- if focus was active, classify a long sleep as away rather than silently adding it to focus;
- if travel began during sleep, enter away/travel state without flashing a stale overlay after the departure has passed;
- never duplicate a warning or interval transition.

Use monotonic time for live countdowns and UTC timestamps for durable records. Time-zone changes affect display and daily-note placement, not elapsed duration.

---

## 12. Architecture

```text
EventKit ───────────────┐
Core Audio ─────────────┤
Idle / presence ────────┤     immutable state     MenuBar UI
Mac commands ───────────┼──▶ Scheduler Actor ───▶ Mac UI + Overlay
Accessory input ────────┤           │             Accessory Coordinator
Sleep/wake/time ────────┘           │
                                    ▼
                              SQLite Store
                                    │
                                    ▼
                            Summary + Obsidian Export
```

### 12.1 Components

| Component | Responsibility |
| --- | --- |
| `SchedulerEngine` | Pure scheduling calculations from policy, state, and calendar constraints |
| `StateMachine` actor | Serializes events, enforces guards/invariants, commits transitions |
| `CalendarProvider` | EventKit permission, fetch, change notifications, classification |
| `CallActivityProvider` | Live call evidence and confidence |
| `IdlePresenceProvider` | Idle time and home/away evidence |
| `AccessoryCoordinator` | Connects zero or more optional capability-based plugins and maps their input to typed events |
| `BusyBarAccessory` | BUSY-specific discovery, authentication, capabilities, display, input, and reconnect |
| `PresentationCoordinator` | Maps state snapshots to Mac and accessory-neutral presentation models |
| `OverlayController` | AppKit window lifecycle and safety escape |
| `SessionRepository` | SQLite migrations and transactional interval storage |
| `SummaryService` | Daily/category totals and correction-aware recomputation |
| `ObsidianExporter` | Idempotent Markdown rendering and atomic file replacement |
| `DiagnosticsStore` | Local, bounded health and transition records |

### 12.2 Event processing

1. A provider emits a typed event with source timestamp and unique ID.
2. The state-machine actor discards duplicates/stale revisions.
3. It evaluates precedence, guards, and scheduler output.
4. It commits the interval closure/opening and new snapshot in one SQLite transaction.
5. Only after commit does it publish presentation side effects.
6. Failed side effects are retried against the latest revision; they do not roll back historical truth.

This ordering prevents a device display success followed by a database failure from inventing a break that cannot be recovered after restart.

---

## 13. Data model

SQLite is the source of truth. Enable foreign keys and WAL mode, version every schema migration, and back up before destructive migrations.

### 13.1 Tables

#### `work_sessions`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | UUID text | Primary key |
| `started_at_utc` | timestamp | Required |
| `ended_at_utc` | timestamp nullable | Null while open |
| `timezone_id` | text | Time zone at start |
| `clock_in_source` | text | menu, suggestion, recovery |
| `clock_out_source` | text nullable | menu, recovery, auto-close correction |
| `notes` | text nullable | User correction note |
| `created_at_utc`, `updated_at_utc` | timestamp | Audit |

#### `intervals`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | UUID text | Primary key |
| `session_id` | UUID text | Foreign key |
| `kind` | enum text | focus, meeting, break, lunch, travel, away |
| `location_context` | enum text | home, away, unknown |
| `started_at_utc` | timestamp | Required |
| `ended_at_utc` | timestamp nullable | Only one open primary interval |
| `source` | enum text | state_machine, calendar, device, idle, user, recovery |
| `classification_confidence` | real nullable | For inferred intervals |
| `calendar_occurrence_id` | text nullable | Stable local reference |
| `calendar_title` | text nullable | Stored only if enabled |
| `minimum_satisfied_at_utc` | timestamp nullable | Breaks only |
| `away_chain_id` | UUID text nullable | Links travel and offsite meeting |
| `corrected_from_kind` | text nullable | Audit of user correction |
| `created_at_utc`, `updated_at_utc` | timestamp | Audit |

#### `state_snapshots`

Stores only the latest recoverable machine snapshot plus revision, deadlines, and last processed event IDs. It is operational state, not the reporting ledger.

#### `transition_log`

Bounded diagnostic history: timestamp, prior/new state summary, event type, reason code, revision, and redacted error. Calendar titles and secrets are excluded.

#### `daily_exports`

Tracks local date, note path, content hash, exported revision, and result. This makes exports idempotent and retryable.

### 13.2 Derived totals

- **Clocked-in span:** session end − start.
- **Working:** focus + meeting, including offsite meetings if configured as work.
- **Focus:** intervals of kind focus.
- **Meetings:** intervals of kind meeting.
- **Breaks:** intervals of kind break.
- **Lunch:** intervals of kind lunch; excluded from working.
- **Travel:** intervals of kind travel; separately reported, configurable whether counted as paid/work time.
- **Away:** intervals of kind away; excluded from working by default.

Warnings are not separate interval kinds; they inherit the underlying focus/meeting classification and are available in transition diagnostics.

### 13.3 Corrections

The history UI allows changing interval kind, start/end, or clock-out time. Corrections are transactional, preserve a minimal audit field, recompute summaries, and regenerate the Obsidian section. Overlaps and negative durations are rejected before save.

---

## 14. Obsidian export

Obsidian is an exported view, never the database. The user selects a vault or folder through a standard file picker. If sandboxed distribution is used, retain access with a security-scoped bookmark.

V1 updates a delimited section rather than blindly appending:

```markdown
<!-- breakbar:start -->
## Work

**Clocked in:** 8:47 AM  
**Clocked out:** 5:36 PM  
**Working:** 7h 08m · **Focus:** 4h 51m · **Meetings:** 2h 17m  
**Breaks:** 47m · **Lunch:** 54m · **Travel:** 60m

| Type | Start | End | Duration | Details |
| --- | --- | --- | ---: | --- |
| Focus | 8:47 AM | 9:42 AM | 55m | |
| Break | 9:42 AM | 9:55 AM | 13m | |
| Meeting | 10:03 AM | 10:47 AM | 44m | Mentoring 1:1 |
| Lunch | 12:08 PM | 1:02 PM | 54m | |
<!-- breakbar:end -->
```

Meeting titles are omitted unless explicitly enabled. Export occurs on clock-out, after corrections, on demand, and optionally after every closed interval. Write to a sibling temporary file, fsync as appropriate, and atomically replace the destination. If the note already contains the markers, replace only that section. If markers are malformed or duplicated, stop and report the conflict rather than risking unrelated note content.

Daily bucketing follows the user’s local time zone. Intervals crossing midnight are split for summary/export while remaining representable as one stored interval.

---

## 15. Configuration

### General

- target seated interval, warning, minimum break, and maximum seated interval;
- idle threshold;
- launch at login;
- menu-bar timer format and sounds;
- neutral clocked-out Bar display;
- optional lock-screen behavior after break starts.

### Calendar

- included calendars;
- ignored event availability/status types;
- meeting, lunch, travel, and offsite patterns;
- travel adjacency window;
- meeting-title retention/export;
- classification preview for upcoming events.

### Calls

- recognized app bundle IDs;
- browser rules;
- detector confidence test and status;
- start/end debounce;
- manual meeting override.

### BUSY Bar

- device identity, name, reserved IP/mDNS host, local credential;
- selected physical control;
- brightness, color theme, sound, and quiet hours;
- reconnect status and firmware/API versions;
- device test and display preview.

### Location and travel

- home-presence method: local Bar reachability, network identity if permission allows, or manual only;
- return confirmation policy;
- travel keyword/location rules.

### Obsidian

- enabled/disabled;
- vault/daily-note folder;
- filename format;
- section heading;
- export meeting titles and travel details;
- last export status and `Export now`.

---

## 16. Failure modes and safety escape hatches

| Failure | Required behavior |
| --- | --- |
| Bar unreachable before deadline | Mac timer and overlay continue; show offline status and on-overlay fallback |
| Bar disconnects during break | Break remains active; reconnect and accept second press later; allow explicit fallback end after minimum |
| Stale Bar display | Mark device offline in menu; retry latest revision; never replay intermediate displays |
| Duplicate/delayed button event | Debounce and revision-check; one event can cause at most one transition |
| Bar reboots | Rediscover, capability-check, repaint current state; Mac state is unchanged |
| Calendar permission denied/revoked | Explain degraded calendar-blind scheduling; normal timer still works |
| Call detector unavailable | Use calendar-only behavior and manual meeting override; show degraded status |
| Calendar service returns stale data | Refresh on store change/wake and periodic backstop; preserve already visible enforcement conservatively |
| Obsidian path unavailable | Queue export, retain SQLite data, show non-blocking error; never block clock-out |
| Database write fails | Do not claim a state transition completed; show actionable error and preserve an emergency exit |
| App crashes during overlay/break | Recover latest snapshot and elapsed time; do not restart minimum break from zero |
| Mac sleeps | Reconcile elapsed time on wake; classify long inactivity; avoid stale alarms |
| Network/VPN falsely implies home | Require event chain end plus trusted local evidence; provide manual `Still Away` |
| Screensaver launch fails | Break still starts; log and show a non-blocking diagnostic |
| User forgets to clock out | Suggest correction next launch; never silently create a multi-day working interval |

### 16.1 Escape design

The full-screen overlay includes:

- `BUSY Bar offline? Start break here` when the device cannot be reached;
- a visible `5 more minutes` button that records the deferral and returns to warning mode;
- an accessible menu command from the app’s status item;
- `Clock Out` after confirmation.

Deferral records the reason and moves the deadline five minutes later without restarting the focus interval. It never marks a five-minute break as completed. Clocking out remains available after explicit confirmation.

Travel overlays always include a Mac acknowledgement because departure must not depend on an accessory left across the room. If BreakBar itself becomes unresponsive, standard macOS Force Quit remains available.

---

## 17. Privacy and security

- Core behavior is local-only; no BUSY cloud account is required.
- Calendar access is used only while needed for scheduling. Event titles are not persisted by default.
- BreakBar never records microphone audio, call content, keystrokes, screenshots, browser history, or meeting participants.
- Call detection retains only derived active/inactive state and minimal diagnostic identity.
- The local BUSY credential is stored in Keychain, never in preferences or logs.
- Device requests stay on the LAN unless the user explicitly configures a remote endpoint in a future version.
- Obsidian access is limited to the selected folder/bookmark.
- SQLite and diagnostic files use the user’s standard application-support directory and inherit macOS file protection/permissions.
- Logs use privacy redaction for event titles, file paths, device secrets, and LAN addresses.
- A privacy screen explains each signal and provides independent disable controls, with the resulting functional degradation made clear.
- Provide `Export history` and `Delete all BreakBar data` controls. Deletion requires confirmation and does not delete unrelated Obsidian note content; it removes only marked BreakBar sections if explicitly requested.

---

## 18. Observability and supportability

The menu’s Diagnostics view shows:

- current state and revision;
- current timer origin, nominal due, planned due, and reason;
- next classified calendar constraint without title unless enabled;
- call evidence source/confidence;
- idle/home-presence signals;
- Bar address source, reachability, firmware/API version, last successful write, and last input event;
- database health and last Obsidian export;
- permission status.

Use structured OSLog categories for scheduler, state transitions, calendar, calls, device, persistence, overlay, and export. Keep an in-database ring buffer of redacted transition reasons for user-visible debugging. Provide `Copy diagnostics` that excludes calendar titles, credentials, full file paths, and IP addresses by default.

Useful counters include missed deadline by reason, meeting deferral duration, overlay-to-first-press latency, break duration, device reconnects, export failures, and recovery transitions. These remain local in V1; no telemetry service is required.

---

## 19. Testing plan

### 19.1 Unit tests

- nominal warning, required break, minimum countdown, extended count-up;
- early and valid second presses;
- pre-meeting break placement and infeasible-slot deferral;
- back-to-back and overlapping events;
- calendar end with continuing call activity;
- full five-minute warning after an overdue call ends;
- travel overriding break warning/required;
- travel → offsite meeting → travel → return chains;
- lunch and idle classification;
- clock-out from every state;
- sleep/wake, time-zone change, DST, and wall-clock rollback;
- duplicate/out-of-order events;
- crash recovery from every persisted state;
- daily totals and midnight splitting;
- idempotent Obsidian marker replacement.

Use a virtual clock and pure scheduling inputs so hour-long scenarios run instantly and deterministically.

### 19.2 Property/invariant tests

Generate random event streams and assert:

- no overlapping primary intervals;
- no normal break ends before its minimum;
- no enforcement while clocked out;
- no normal enforcement while confirmed away/lunch/travel;
- every open session has exactly one compatible open activity;
- state revisions increase monotonically;
- replaying the same event IDs does not change history.

### 19.3 Adapter tests

- Fake BUSY server generated from a captured device OpenAPI contract.
- Network loss, timeouts, 403, reboot, schema mismatch, slow responses, and duplicate input.
- EventKit permission states and synthetic calendar stores where practical.
- Call-provider fixtures for dedicated apps, browsers, microphone flaps, and audio-only false positives.
- Obsidian permission loss, malformed markers, concurrent note edit, and full disk.

### 19.4 UI and accessibility tests

- VoiceOver labels and keyboard navigation.
- Overlay across spaces, full-screen apps, sleep/wake, resolution changes, and display hot-plug.
- Visible five-minute deferral and clock-out controls at all supported sizes.
- Menu-bar legibility and countdown updates.
- Color-blind-safe meaning: every state is understandable from text alone.

### 19.5 BUSY accessory acceptance tests

Required to ship the BUSY accessory plugin, but not to ship or use the Mac app. Run against the actual purchased Bar and exact shipping firmware, then latest stable firmware:

1. sustained eight-hour connection test;
2. 100 start/return input cycles with latency and duplicate detection;
3. Wi-Fi roam, router reboot, DHCP renewal, Bar reboot, and Mac sleep/wake;
4. every display template at expected brightness and viewing distance;
5. coexistence with device web UI/built-in apps;
6. firmware update and API compatibility handling;
7. a complete simulated workday with meetings, lunch, travel, and Obsidian export.

### 19.6 Manual scenario acceptance

- A meeting scheduled to end at 10:30 continues until 10:47; warning begins at 10:47 and overlay at 10:52.
- A meeting starting at 11:00 would cover a 11:05 break; warning starts at 10:50, break at 10:55, and minimum ends at 11:00.
- Starting the break on the Mac removes the overlay and starts screensaver; return is unavailable at 2:30 and succeeds at 12:00. Repeat through an accessory when one is installed.
- A 10:30 travel block warns at 10:25, forces `TIME TO GO` at 10:30, suppresses the 10:32 normal break, remains `AWAY` through the offsite meeting, and starts fresh on return.
- A forgotten 48-minute lunch becomes idle away and is easily reclassified to lunch without corrupting totals.

---

## 20. Milestones

### Parallel accessory spike — after hardware arrives

- Unbox/update the Bar.
- Capture device-hosted OpenAPI and capability/version information.
- Prove Wi-Fi discovery/authentication, text rendering, and chosen button event.
- Measure input/display latency and reboot behavior.

**Exit:** A command-line harness can render a revisioned state and reliably observe one physical press on the actual device. This does not gate the Mac milestones.

### Milestone 1 — Native shell and core loop

- Menu-bar app, settings, launch at login.
- Pure scheduler/state machine with virtual-clock tests.
- Clock in/out, focus countdown, warning, overlay, safety escape.
- SQLite session and interval persistence/recovery.

**Exit:** Mac-only flow completes a work/break cycle and survives restart.

### Milestone 2 — Optional BUSY accessory

- BUSY accessory plugin, reconnect, display templates, and input debounce.
- Accessory-originated start and return commands through the same state-machine path as Mac commands.
- Five-minute minimum, extended count-up, and early-return feedback.
- Failure fallback and stale-display treatment.

**Exit:** The remote start/return loop works reliably over Wi-Fi for a full day, and disconnecting the Bar does not alter the Mac flow.

### Milestone 3 — Calendar and live meetings

- EventKit onboarding, selection, classification, and change handling.
- Pre-meeting scheduling.
- Call activity provider, allowlist, confidence, and live test.
- Meeting overrun and post-call five-minute warning.

**Exit:** Required meeting scenarios pass with Calendar plus at least the user’s primary calling tools.

### Milestone 4 — Lunch, idle, travel, and location

- Lunch flows and calendar-derived prompts.
- Idle-away detection and return classification.
- Travel warning/overlay, offsite chains, home-return confirmation.
- Precedence and recovery tests.

**Exit:** A representative away-from-home day yields correct Bar status and interval history.

### Milestone 5 — History, Obsidian, and hardening

- Daily summary/history correction UI.
- Idempotent Obsidian export.
- Diagnostics and privacy controls.
- Accessibility, long-run, failure-injection, and hardware acceptance testing.

**Exit:** V1 acceptance scenarios pass, no state can trap the user, and a weeklong dogfood run produces trustworthy daily notes.

---

## 21. Open questions

### Must resolve with the physical Bar

1. Which physical input offers the best unambiguous press event, and can BreakBar receive it while owning a custom display?
2. Is an input event pushed over a stable stream, represented as state, or only accessible through polling?
3. Do firmware/API versions differ from published SDK examples, and how should capabilities be negotiated?
4. What happens to custom display ownership when the Bar reboots, a built-in app opens, or the web UI is used?
5. Is mDNS reliable enough for discovery, and is a device ID stable across Wi-Fi/firmware reset?
6. What authentication header/credential form is used by the shipping firmware over Wi-Fi?
7. What text layouts remain readable across the room on the 72×16 display?
8. Can the Bar provide a trustworthy LAN-local presence signal without cloud fallback?

### Product decisions suitable for dogfooding

1. Should the default target be exactly 55 minutes, or user-tuned after the first week?
2. Should a scheduled calendar meeting alone always show `MEETING`, or only after proximity/activity evidence?
3. Which browser-call heuristics are accurate enough for default enablement?
4. Should an explicit manual break be allowed to start from the Bar while in focus, and which gesture avoids accidental presses?
5. Should travel departure acknowledgement auto-clear when the Bar becomes unreachable, or require a Mac action to avoid network-failure false positives?
6. Should travel count toward “working” totals by default, or only appear as a separate clocked-in category?
7. How long may an unresolved idle interval remain before clock-out requires classification?
8. Should `BREAK_REQUIRED` make the family-facing state immediately interruptible, or remain `BUSY` until the break starts?
9. What is the minimum supported macOS version, particularly for process-level Core Audio call detection?
10. Is direct screensaver launch reliable across that support matrix, or should V1 offer display sleep/lock as alternative implementations?

---

## 22. Release acceptance criteria

V1 is ready when:

- the user can explicitly clock in/out and never receives enforcement while clocked out;
- when a display accessory is connected, it agrees with the Mac’s family-facing state within two seconds under normal conditions;
- normal focus produces a five-minute warning and full-screen overlay;
- one deliberate Mac or accessory command starts the normal break, and return to focus is accepted only after five minutes;
- screensaver launch is attempted after break start without becoming the source of break truth;
- meetings are planned from Calendar and can continue based on real call activity;
- an overdue meeting always receives a five-minute post-call warning;
- a feasible break is pulled before a meeting that would consume its deadline;
- lunch, idle away, travel, and offsite meetings are distinct and correctly summarized;
- travel produces its own warning and `TIME TO GO` overlay, suspends focus, stays `AWAY` through the offsite chain, and returns to a fresh interval;
- accessory loss never disables the Mac timer or traps the user;
- restart, sleep/wake, and duplicate device events do not corrupt interval history;
- SQLite totals match the interval ledger and Obsidian export can be regenerated without duplicating content;
- all permissions, stored data, and diagnostic signals are understandable and locally controllable;
- the Mac-only acceptance scenarios pass without an accessory;
- before the BUSY plugin ships, its hardware acceptance checklist passes on the actual device and supported firmware.

---

## 23. Implementation references and validation note

- [BUSY Bar development overview](https://docs.busy.app/bar/dev) — official overview of local HTTP control over USB/Wi-Fi, display control, official libraries, and firmware sources.
- [Official BUSY Python library](https://github.com/busy-app/busylib-py) — documents the USB address, Wi-Fi access, device discovery, front-display size, drawing/audio capabilities, and version compatibility concerns.
- [Official BUSY TypeScript library](https://github.com/busy-app/busylib-ts) — documents typed HTTP access and a real-time state stream.
- [Official BUSY firmware](https://github.com/busy-app/busybar-firmware) and [firmware releases](https://github.com/busy-app/busybar-firmware/releases) — source and release history; useful for diagnosing version-specific behavior.
- [Apple: Accessing the event store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store) — EventKit permission and sandbox requirements.
- [Apple: AudioHardwareProcess](https://developer.apple.com/documentation/coreaudio/audiohardwareprocess) — process identity and input/output-running signals for call evidence on supported systems.

Online documentation is design input, not the final device contract. At implementation time, record the Bar’s firmware and API versions and treat the unit’s own `/docs` or `/openapi.yaml` as authoritative. Any mismatch becomes a capability check or compatibility adapter, not an assumption scattered through product logic.
