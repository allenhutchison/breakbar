# BreakBar

BreakBar is a Mac-first menu-bar countdown that makes regular breaks hard to ignore. It works without external hardware; optional accessories can mirror the current state and send the same typed commands as the Mac UI.

## Run the app

The current slice requires macOS 14 or newer and Swift 6.

```sh
make run
```

For a one-minute focus cycle, 15-second warning, and 20-second minimum break:

```sh
make demo
```

The app appears only in the menu bar, where its status item shows the live countdown. Clock in, let the countdown reach the warning window, and allow notifications when macOS asks. The warning posts one notification and plays a sound. At zero, start the break from the full-screen prompt and return after the minimum. Starting a break makes a best-effort request to launch the macOS screensaver.

Open **Settings** from the menu-bar menu to change the focus interval, warning duration, minimum break, and idle-away threshold. Each timing control accepts a two-digit minute value or can be adjusted with its adjacent arrows. Invalid values are clamped to the supported range, and normal-mode preferences persist across app restarts. Use **Restore timing defaults** to return to the standard 55-minute focus, 5-minute warning, 5-minute minimum break, and 10-minute idle threshold.

## Verify

```sh
make test
make build
```

The Makefile selects the installed Xcode beta because this machine’s currently selected standalone Command Line Tools contain a compiler/SDK mismatch. Override `DEVELOPER_DIR` when a stable matching Xcode is selected.

## Architecture

- `BreakBarCore` contains the deterministic state machine, policy, presentation model, and accessory protocol. It has no UI or hardware dependency.
- `BreakBarPersistence` owns the migration-capable SQLite session ledger and recoverable state snapshot. Timer transitions commit there before the UI publishes them.
- `BreakBarApp` is the always-available Mac presentation/input implementation.
- A future BUSY Bar target will conform to `BreakBarAccessory` after its shipping API has been validated.

Normal and demo runs use separate databases under BreakBar’s Application Support directory, so accelerated cycles never enter real work history. Existing `state.json` state is imported once when the normal SQLite database is first created and retained as a recovery artifact.

The broader product design is in [planning/BreakBar V1 Design.md](planning/BreakBar%20V1%20Design.md).
