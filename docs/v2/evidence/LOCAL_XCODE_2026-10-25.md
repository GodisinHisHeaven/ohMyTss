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

## Strava 与 main 整合验证

2026-10-25（America/Chicago）。本节为上述历史记录之后的验证，生产源码为 `584b0bcdc23d30dd69528a51d27ca55c4ea04ad8`，包含 main `5979a5b` 与 PR #18。

TestFlight 0.0.5（19）在真实 iPhone 上完成 Strava 登录返回、显示已连接账号、手动同步和 History 查看。首次授权的自动同步没有刷新设置页 Last Sync，已补充成功刷新和失败保留旧时间的回归。系统短名称与显示名称均设为 `ohMyTss`。真实账号与健康数据截图仅保存在本地，不进入公开仓库。这里的 Build 19 实测不代表本 PR 尚未发布的二进制已实测。

合并前修复远端审查的 Walking/Walk 重复贡献、查询失败时生理/睡眠字段丢失、本地删除后历史评分及 ramp rate 过期问题。新回归覆盖重复同步、独立失败与成功空结果、本地删除后的跨日依赖重算。

首次 iOS 26.4 并行运行有一项人体图 UI 失败，后续中止；另一轮卡在模拟器启动 App，空白模拟器又停在系统 CoreLocation 迁移。切换已安装的 iOS 26.1 后，完整执行产生 23 个对象释放崩溃、51 个通过测试，没有跳过。崩溃堆栈指向 `TaskLocal::StopLookupScope`、`swift_task_deinitOnExecutorImpl` 和三个类的析构，对应 [Swift #88036](https://github.com/swiftlang/swift/issues/88036)。在 DataStore、V2Store、WorkoutAggregator 中显式声明空的 nonisolated deinit 后，保留原同步测试重新全量执行。

```sh
xcodebuild -project onMyTss/onMyTss.xcodeproj -scheme onMyTss \
  -destination 'platform=iOS Simulator,id=ED6ECAFC-AAAA-489B-A43C-44A9DFA45DE2' \
  -derivedDataPath /private/tmp/ohmytss-strava-v2-derived \
  -resultBundlePath /private/tmp/ohmytss-strava-ios261-reviewed.xcresult \
  -parallel-testing-enabled NO test -enableCodeCoverage YES
bash scripts/check_v2_domain.sh
bash scripts/check_v2_migration.sh
```

最终结果：Xcode 27.1 / iPhone 17 Pro / iOS 26.1，77 项唯一测试全部通过，80 次执行（70 单元 + 10 UI），0 失败、0 跳过。30 个领域测试、9 个生产 Strava 合成 HTTP 场景、9 个配置测试通过。当前模型的真实 Apple SwiftData 基线迁移保留旧行、设置和关系，v2 写入成功。

本地证据：`/private/tmp/ohmytss-strava-ios261-reviewed.xcresult`、`ohmytss-strava-ios261-reviewed.log`、`ohmytss-strava-ios261-reviewed-summary.json`、`ohmytss-strava-reviewed-domain.log`、`ohmytss-strava-v2-migration.log`。修复前失败结果保留于 `ohmytss-strava-ios261-final.xcresult`，不计作通过。云端 main 构建及新 TestFlight 包在合并后单独核对；完整 VoiceOver、真人记录计时和新增 HealthKit 类型采样仍未完成全部人工验证。
