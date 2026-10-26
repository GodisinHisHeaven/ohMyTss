# Heart-rate save and code-quality review — 2026-10-26

Scope: the iOS startup, settings, estimate persistence and calculation paths,
Strava presentation callback, and release gates. Morning status and Strava
regression tests are included; the private backend is unchanged.

## Findings and changes

| Priority | Finding | Resolution |
| --- | --- | --- |
| P1 | Saving maximum heart rate synchronously recomputed the entire history on the main actor, repeatedly fetching and decoding the same records. | Capture immutable inputs, calculate on a separate actor, then save at most 50 estimates before yielding. Settings shows progress and navigation remains available. |
| P1 | A failure opening SwiftData terminated the process with `fatalError`. | Preserve the store and show a retry screen. An injected first-open failure now recovers through the actual UI. |
| P2 | Termination after saving a new threshold could leave some current-model snapshots using the old threshold; launch backfill skipped them. | Compare saved threshold inputs during backfill. A disk-reopen test verifies that only unfinished snapshots are appended and all old snapshots survive. |
| P2 | Xcode Cloud tests were optional, allowing Build 24 to distribute before its tests finished. | Changed Test - iOS to Required To Pass, reopened the workflow to verify persistence, and documented mandatory local and cloud release checks. |
| P2 | Strava's window callback explicitly opted out of the main actor while reading UIKit state. | Remove `nonisolated`, matching the installed Apple SDK's UI-actor protocol declaration. The token-decoding test also runs on its model's actor. |

Concurrency review: SwiftData models and contexts stay on the main actor. Only
Sendable values cross to the calculator. Calculations are serialized to bound
concurrent CPU and decoded-sample memory. Inputs are checked again after
calculation and before every save batch, so a newer threshold, edit or deletion
invalidates stale work. Concurrent refreshes check the newest stored input to
avoid duplicate snapshots. Cancellation preserves completed batches for resume.
Unchanged threshold saves do not alter the modification timestamp.

Historical payloads, workout rows, legacy TSS, schema names, bundle identifiers
and Keychain identifiers are preserved. Feature decoding is scoped to the
session being processed; prior running exposure retains only endpoints instead
of decoded samples for every workout at once.

## Validation

Xcode 27.1, Apple Swift 6.4; iPhone 17 Pro simulators. All history fixtures
contain synthetic data; no athlete data or credentials are in this report.

- Final Debug / iOS 26.1: 100 unique tests, 103 executions (88 unit and 15 UI),
  zero failures and zero skips. This includes native morning-account flows,
  Strava parsing/token recovery, training edits/deletions, large-history launch,
  maximum-heart-rate save and storage retry.
- Release with test access enabled / iOS 26.1: all 88 unit tests and the
  maximum-heart-rate UI flow passed. The UI app used its normal disk store,
  preloaded with 1,000 workouts containing 30 timed HR intervals each. The
  Release binary contains no `--v2-ui-tests` fixture flag. Database inspection
  afterward confirmed 1,000 workouts, 2,000 retained snapshots, every latest
  snapshot using 190 bpm and all 30 intervals, and SQLite integrity `ok`.
- The 1,000-workout disk responsiveness test changes 190 → 170 → 180 bpm while
  calculation is running and checks that 180 wins, original snapshot IDs remain,
  and repeating the refresh appends nothing. Final Debug measured 2.348 seconds
  with a 0.121-second maximum main-actor heartbeat gap; Release measured 3.341
  seconds with a 0.148-second maximum gap. These are complete refresh and
  scheduling measurements on this host, not frame-rate or physical-phone claims.
- `scripts/check_v2_migration.sh`: passed on Apple's SwiftData runtime; legacy
  rows, settings, relationships and new v2 writes survived the baseline upgrade.
- CI-configuration tests: 9 passed. `git diff --check`: passed. The final Release
  build and signature verification passed; reviewed source no longer emits the
  actor-isolation warnings addressed above.

- Normal Release with `ENABLE_TESTABILITY=NO` / iOS 26.4: the heart-rate-save
  UI flow passed against the normal persisted store. Post-test inspection again
  confirmed 1,000 workouts, 2,000 snapshots, every latest estimate using 190 bpm
  and 30 HR intervals, and SQLite integrity `ok`. This run does not use the
  DEBUG fixture. The full flow took 28.6 seconds including XCTest interaction;
  that is not the app's save latency.

Machine-readable counts and data checks are in
`heart-rate-quality-2026-10-26-summary.json`. Local result bundles are named
`ohmytss-quality-final-full.xcresult`,
`ohmytss-heart-rate-release-ios261.xcresult`, and
`ohmytss-heart-rate-release-normal-ios264.xcresult` under `/private/tmp`.

The first full run found a retry-button accessibility identifier inherited from
the error container. Removing that container identifier fixed the focused UI
test and both subsequent full runs. A cancellation test was also expanded from
30 to 300 records because 30 fit in one save batch and could legitimately finish
before cancellation. Neither failure was treated as a successful release check.

## Limits

Build 25 was blocked by the required cloud test action. iPhone SE and iPhone 16
Pro reported additional test-worker launch failures with zero tests executed:
`SBMainWorkspace` could not find `mj6.onMyTssUITests.xctrunner`. The observed
training, morning-account and launch suites had passed, but these runner errors
are not accepted as a successful release. The shared scheme now runs both test
bundles serially per destination, retaining all cases and the four recommended
iPhone destinations. The full suite using the shared scheme, without a
`-parallel-testing-enabled` command-line override, passed on iOS 26.1:
100 unique tests / 103 executions, zero failures and zero skips
(`ohmytss-serial-scheme-full.xcresult`). App and test source are unchanged from
the preceding validated Release runs. Cloud delivery must still verify the
new configuration before publication.

The reported physical-device freeze has no matching device trace available in
this session. Simulator tests and main-actor heartbeat measurements establish
the tested behavior, not a guarantee of zero dropped frames or zero crashes on
every phone. Live HealthKit authorization and live Strava account authorization
are not re-run by the synthetic regression suite.
