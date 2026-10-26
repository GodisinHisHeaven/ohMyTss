# Local Xcode validation — 2026-10-25

Subsequent body-map visual changes and their focused validation are recorded separately in [BODY_MAP_2026-10-25.md](BODY_MAP_2026-10-25.md). The complete-scheme results below apply to the source hashes recorded for this earlier run.

## Tested source and environment

- PR #18: https://github.com/GodisinHisHeaven/ohMyTss/pull/18
- Remote head: `8bb4973f6d7860ba4d5f7b54bb10c6e11c0bc26e`.
- Tested source: that head plus the changes on `codex/v2-xcode-validation`, captured before Git commit. Source hashes are in `local-xcode-2026-10-25-source.json`; these identify the exact tested tree independently of subsequent PR updates.
- Xcode 27.1 (`27A9275`), Apple Swift 6.4, iOS Simulator SDK 27.1; project retains Swift 5 language mode.
- Test destination: iPhone 17 Pro, iOS 26.4 (`23E244`), `F059EDD5-208C-459F-8B74-8041E362E1D7`.
- Existing local private build configuration was copied into the isolated worktree. No credentials are included in this report or the committed-source candidates.

## Results

| Check | Result |
| --- | --- |
| Complete Xcode scheme test | PASS; exit 0, `TEST SUCCEEDED` |
| Unit tests | 42 executions passed, including all 20 v2 persistence tests |
| UI tests | 9 executions passed: 3 v2 flows, 2 original tests, 4 launch configurations |
| xcresult unique test count | 48 passed, 0 failed, 0 skipped; 51 total executions including launch configurations |
| Shared production domain | 30 tests passed |
| Production Strava HTTP synthetic cases | 9 passed |
| Existing configuration tests | 4 passed |
| Baseline-to-current Apple SwiftData migration | PASS after final model changes |
| iOS in-place upgrade with synthetic records | PASS; legacy fields, relationships, settings, v2 estimates and a manually entered observation survived |
| Whitespace check | `git diff --check` passed |

The final XCTest summary is in `local-xcode-2026-10-25-summary.json`. The run completed at 10:47 America/Chicago.

## Problems found and fixed locally

1. `LocalObservation` and `StrengthSetRecord` read the persisted `recordedAt` property before all stored properties were initialized. Both timestamps now use the same local `Date` value.
2. The new HealthKit test's `DataStore` return type conflicted with `SwiftData.DataStore`; the type is now qualified as `onMyTss.DataStore`.
3. Apple Swift timed out when type-checking a domain test's compound numeric expression. Named, typed intermediate values preserve the same inputs and assertions.
4. The app's persisted `Workout.isDeleted` collided with `PersistentModel.isDeleted`. Three deletion regressions failed on iOS. The app marker is now `isTombstoned`, with `@Attribute(originalName: "isDeleted")` for migration. All consumers use the new marker. A new disk-reopen/resync test verifies the tombstone stays stored while the SwiftData object remains retained.
5. The strength UI test searched for a non-hittable text inside the actual button and could scroll past the target. It now targets the button and searches both scroll directions. V2 flow tests set portrait explicitly because the original launch-configuration tests leave the device in landscape. All original assertions remain; no tests were skipped.

The initial `8bb4973` head failed iOS compilation. These passing results apply to the fixed tree identified by the source hashes above.

## Migration and manual interaction evidence

The macOS migration script compiled the exact baseline models from `fdab778b6b51181bd76c3627b765da8af5ed6eef`, seeded a temporary synthetic store in one process, and opened it with the final production models in another process. The final probe passed.

For the iOS check, a separate temporary baseline checkout used the original model files and a local-only fixture hook derived from `LegacyStoreSeed.swift`. That hook inserted synthetic data inside the real app container and prevented automatic sync during seeding. It is not part of the production changes.

On `985C8DEF-3EDF-475A-BDE8-7C832EF7097B` (iPhone 17 Pro / iOS 26.4), the baseline app was terminated, its synthetic store backed up, and v2 installed with `simctl install` using the same bundle ID. No uninstall, erase, database deletion or restore occurred. Simulator installation rotated the container UUID while retaining its data. The final fixed build was then installed in place again.

Read-only SQLite checks after the final launch confirmed:

- `synthetic-legacy-migration`: TSS 73, duration 3600 seconds, original daily relationship.
- Daily TSS/CTL/ATL/TSB: 73 / 21 / 33 / -12.
- FTP 240, maximum heart rate 181, onboarding completed.
- A v2 estimate existed.
- A real UI entry for Front thighs / Left / Soreness / Mild (1) remained after the final upgrade and relaunch.

See `local-xcode-2026-10-25-upgrade.json`. The manual entry took 25.1 seconds including tool calls and inspection; it does not validate the 10–20 second human-use target.

## Reproduce and inspect

From the repository root:

```sh
xcodebuild -project onMyTss/onMyTss.xcodeproj -scheme onMyTss \
  -destination 'platform=iOS Simulator,id=F059EDD5-208C-459F-8B74-8041E362E1D7' \
  -derivedDataPath /private/tmp/ohmytss-v2-xcode-20261025/DerivedData \
  -resultBundlePath /private/tmp/ohmytss-v2-xcode-20261025/regression-new.xcresult \
  test -enableCodeCoverage YES -parallel-testing-enabled NO
bash scripts/check_v2_domain.sh
bash scripts/check_v2_migration.sh
```

Local raw artifacts are under `/private/tmp/ohmytss-v2-xcode-20261025/`:

- `regression-final.xcresult` and `regression-final.log`.
- `domain-final.log`, `migration-final.log`.
- `pre-upgrade-backup/` (synthetic records only).
- Earlier failed/interrupted run bundles remain for diagnosis. The interrupted orientation run is not counted as passing.

Xcode has the isolated project and final test report open. The original checkout's uncommitted project settings and configuration template were not changed.

## Remaining release validation

Real-device HealthKit permissions, quantity-series callbacks and actual imported records; real-account Strava authorization; VoiceOver and broader manual/offline flows; human recording-time measurement are still unverified. Synthetic adapter tests do not establish physiological accuracy. Existing compiler warnings (including Swift 6 isolation diagnostics under Swift 5 mode) remain outside this local testing fix.

The PR stays draft. No merge, Archive, Xcode Cloud or TestFlight action was performed during validation.
