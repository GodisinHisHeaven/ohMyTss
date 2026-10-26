# Launch history regression — 2026-10-26

Opening an already configured app synchronously called `refreshV2Estimates()` on
the main actor before finishing initialization. That enumerated every workout,
reloaded history and all estimate snapshots for each record, and recalculated
unchanged inputs on every launch.

A standalone optimized SwiftData benchmark compiled the production `V2Store`
with 1,000 synthetic workouts and a minimal threshold-store adapter. The baseline
took 48.412 seconds to calculate missing estimates and 53.453 seconds to revisit
the unchanged history. These measure the calculation, not iPhone launch time.
The fixed backfill check on the same populated database took 0.070 and 0.058 seconds.

The app now presents saved history first. Today cooperatively backfills missing
or older-model estimates, suspending between records so input and cancellation
can run. Each completed record is saved and reused after interruption. Imports,
edits and explicit recalculation retain their existing input-refresh behavior.
The prior-snapshot query fetches only the newest estimate for the target session.
Original workout rows, legacy TSS, model schemas and prior snapshots are retained.

A Release run with 1,000 past workouts and no estimates exposed a second cost:
each saved estimate rerendered Today, whose region-sort comparator repeatedly
scanned SwiftData history and decoded the same payloads. A three-second process
sample confirmed `prioritizedRegions` → `regionalEstimates` → `estimate(for:)`
on the main thread. `V2TodaySummary` now builds the active/recent lists, latest
estimates, region summaries and ranks once per render. It preserves independent
report sides, method grouping, current-day cardio and archived-session exclusion.
Today's live estimate query also selects only the recent input window it displays,
so saving estimates for older history does not continually change the home
screen's query results during backfill.

Regression coverage uses synthetic data only:

- `testLaunchWithLargeSavedHistoryOpensUsableTabs` creates an isolated in-memory
  history with 1,000 workouts and saved estimates, verifies Today opens without
  the all-history calculation, and switches Settings → Today.
- Backfill tests cover missing/old estimates, retaining current and historical
  snapshots, suppressed/deleted sessions, main-actor cancellation, and resuming
  without duplicate snapshots.
- Normal launch tests now require an actual Today or onboarding screen and a
  foreground app before recording their screenshot.
- A second large-history launch test starts without any cached estimates and
  navigates Settings → Today while backfill is eligible to run. Summary tests
  verify newest-snapshot selection, method separation and report priorities.

Xcode 27.1 / iPhone 17 Pro / iOS 26.4 targeted tests passed: 24 persistence tests
and five UI executions (including four launch configurations), zero failures.
Before the additional summary optimization, the full iOS 26.1 suite passed:
92 unique tests / 95 executions (83 unit,
12 UI executions), zero failures and zero skips. The Release simulator build
completed and its signature verified successfully.
After the final summary/query changes, 26 persistence/summary tests and all six
training UI flows passed on iOS 26.1. The two large-history flows were rerun after
removing an assertion that incorrectly included XCTest's automation handshake in
app initialization time; both passed (32.656 seconds for the two complete flows).
Main-actor responsiveness remains covered by the cancellation/resume test.
The final Release build also passed. Xcode Cloud delivery is tracked on the PR.

This confirms a main-thread launch-blocking defect. The reported physical-device
termination is not yet matched to a crash report: Organizer had no matching logs
and no physical iPhone was connected during the initial investigation. A clean
simulator launch is not proof that a particular TestFlight crash is resolved.
Apple describes the main-thread watchdog failure mode in
[Addressing watchdog terminations](https://developer.apple.com/documentation/xcode/addressing-watchdog-terminations).
