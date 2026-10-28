# Repository Guidelines

## Project Structure & Module Organization
- Product spelling is `ohMyTss`; use `ohmytss` in new machine identifiers. Preserve the existing `onMyTss` Xcode project/scheme, App Store bundle ID, and Keychain keys for compatibility.
- `backend` is the private `ohmytss-backend` submodule, formerly CoachOTA. Its repository owns deployment, cron, secrets, and migrations; do not copy its source into this public repository or duplicate cron. Read `backend/AGENTS.md` before backend edits.
- Only morning status SMS and consent replies are active in the backend. Native phone-verified morning signup is allowed; keep web coaching signup, chat, plans and other alerts paused. Preserve data, local morning windows, separate summary/SMS opt-in, and idempotency.
- Morning texts use only consented App summaries. Do not restore Intervals sync or an Intervals fallback; retain historical records without using them for delivery.
- App code lives in `onMyTss/onMyTss` with feature folders: `Models` (SwiftData entities and DTOs), `Services` (HealthKit, Strava, BodyBattery computation engines), `Utilities` (helpers), `ViewModels`, and `Views` (subfolders for Today, History, Settings, Onboarding, Shared components). Assets are in `Assets.xcassets`. Put local Strava credentials in the ignored `onMyTss/Config/Secrets.xcconfig`; `StravaConfig.swift` is the tracked loader.
- Tests sit in `onMyTss/onMyTssTests` (unit/logic) and `onMyTss/onMyTssUITests` (launch/flow). The Xcode project is `onMyTss/onMyTss.xcodeproj`.

## Build, Test, and Development Commands
- Open in Xcode: `xed onMyTss/onMyTss.xcodeproj` (or open the workspace directly in Xcode and target the `onMyTss` scheme).
- Quick checks: `python3 scripts/test.py quick`.
- Complete iOS simulator tests: `python3 scripts/test.py full --destination 'platform=iOS Simulator,id=SIMULATOR_UDID'`.
- Automated release checks and remaining manual gates: `python3 scripts/test.py release --destination 'platform=iOS Simulator,id=SIMULATOR_UDID'`.
- Select an available simulator that meets the test targets' deployment requirements. Test results are written to the output directory printed by the runner; `--output-dir` sets an explicit location. Simulator checks do not replace real-device HealthKit/Strava validation.

## Coding Style & Naming Conventions
- Swift 5/SwiftUI defaults: 4-space indentation, `PascalCase` types, `camelCase` properties/functions, `SCREAMING_SNAKE_CASE` constants. Keep views `struct` + `View`, mark classes `final` when possible.
- Place domain models in `Models`, cross-cutting utilities in `Utilities`, and keep services pure (no view code). Prefer dependency injection so services can be mocked in tests.
- Keep functions small and composable; document non-obvious algorithms (e.g., BodyBattery or load calculations) with short comments.

## Testing Guidelines
- Favor deterministic tests in `onMyTssTests`; name as `testFeature_behavior` for clarity. Use mocks for HealthKit/Strava to avoid network or device-state coupling.
- UI smoke tests live in `onMyTssUITests`; keep launch tests lightweight and avoid blocking permission alerts in automation.
- Aim for coverage on calculation paths (BodyBatteryEngine, LoadCalculator, TSSCalculator) and persistence (DataStore). Add regression tests when fixing bugs.

## Release Gates
- Before every TestFlight or production release, review the final diff and run the complete unit/UI suite in real Xcode. Required tests must pass; a successful compile alone is insufficient.
- Exercise the optimized Release app, including cold launch, saved-history upgrade, maximum-heart-rate save, navigation during recalculation, and the changed user flows. Use a persisted synthetic history of at least 1,000 workouts for history-related changes. Verify cancellation/restart, latest-input correctness, and retention of user data and previous estimates.
- Run `scripts/check_v2_migration.sh` for persistence changes and record the simulator/device, OS, configuration, test counts, responsiveness measurements, and any unverified physical-device behavior in the PR. Inspect failures and crash/hang evidence; do not infer smooth rendering from a passing launch test.
- Xcode Cloud's **Test - iOS** action must remain **Required To Pass**. Do not publish with failed, skipped required, or unfinished tests. After merging to `main`, verify that exact commit's Build, Test, Archive, and TestFlight post-action before claiming delivery.

## Commit & Pull Request Guidelines
- Follow the repo’s history pattern: short, capitalized, imperative summaries (e.g., "Fix HealthKit permission flow", "Performance: Parallelize data fetching"). Keep to ~50 characters when possible.
- PRs should include: what changed and why, testing done (simulator device/OS, commands), any screenshots for UI tweaks, and links to issues/notes. Call out configuration steps (e.g., Strava keys) or migration needs.

## Security & Configuration Tips
- `StravaConfig.swift` is a tracked loader; never put credentials in it. Keep values in the ignored `onMyTss/Config/Secrets.xcconfig` or Xcode Cloud environment variables.
- Both Strava components use callback domain `coach-ota.fly.dev`; iOS uses `ohmytss://coach-ota.fly.dev/strava/callback`. See README for the complete identity contract.
- Treat HealthKit data carefully; avoid logging sensitive values and sanitize debug prints before release builds.
