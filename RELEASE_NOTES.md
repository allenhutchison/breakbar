# BreakBar 0.10.0

BreakBar 0.10.0 focuses on automatic break reminders and leaving on time for events that require travel, with fewer controls to manage during the day.

## Highlights

- Break reminders start automatically when you are active at your Mac. Returning after enough time away starts a fresh focus cycle, while short absences preserve the countdown. Pause reminders whenever you need to; an explicit pause survives restarting the app.
- Calendar changes no longer leave deleted or shortened meetings suppressing breaks until their original end. BreakBar refreshes every 15 seconds and after wake or activation, alongside calendar change notifications. An overdue break receives a full warning after the meeting ends; an ongoing detected call still suppresses interruption.
- Use **5 more minutes** once per focus cycle when a required break appears. The extra-time option stays used across restarts and becomes available again after a fresh focus cycle begins.
- Clock-in/out, time categorization, activity reporting, and the Obsidian integration have been removed. Settings no longer includes history export or deletion controls. Calendar-aware meeting and travel reminders remain available.

## Privacy

BreakBar saves its current timer and settings locally for restart recovery and no longer records new activity history. History from earlier versions is preserved locally, and existing Markdown notes are untouched. BreakBar reads selected calendars without editing events or storing calendar titles, and call detection never records microphone audio. There is no analytics or cloud account.

## Requirements

- macOS 14 or later
- Apple Silicon Mac
