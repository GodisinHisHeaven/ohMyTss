# Repository Guidelines

## Project Structure & Module Organization
- App code lives in `onMyTss/onMyTss` with feature folders: `Models` (SwiftData entities and DTOs), `Services` (HealthKit, Strava, BodyBattery computation engines), `Utilities` (helpers), `ViewModels`, and `Views` (subfolders for Today, History, Settings, Onboarding, Shared components). Assets are in `Assets.xcassets`. Strava credentials use `Services/StravaConfig.swift.template` (copy to `StravaConfig.swift`, keep secrets local).
- Tests sit in `onMyTss/onMyTssTests` (unit/logic) and `onMyTss/onMyTssUITests` (launch/flow). The Xcode project is `onMyTss/onMyTss.xcodeproj`.

## Build, Test, and Development Commands
- Open in Xcode: `xed onMyTss/onMyTss.xcodeproj` (or open the workspace directly in Xcode and target the `onMyTss` scheme).
- Build (CI/local): `xcodebuild -scheme onMyTss -destination "platform=iOS Simulator,name=iPhone 15" clean build`.
- Unit/UI tests: `xcodebuild test -scheme onMyTss -destination "platform=iOS Simulator,name=iPhone 15" -enableCodeCoverage YES`.
- Run from Xcode with an iOS 17+ simulator; ensure HealthKit/Strava permissions are granted when prompted.

## Coding Style & Naming Conventions
- Swift 5/SwiftUI defaults: 4-space indentation, `PascalCase` types, `camelCase` properties/functions, `SCREAMING_SNAKE_CASE` constants. Keep views `struct` + `View`, mark classes `final` when possible.
- Place domain models in `Models`, cross-cutting utilities in `Utilities`, and keep services pure (no view code). Prefer dependency injection so services can be mocked in tests.
- Keep functions small and composable; document non-obvious algorithms (e.g., BodyBattery or load calculations) with short comments.

## Testing Guidelines
- Favor deterministic tests in `onMyTssTests`; name as `testFeature_behavior` for clarity. Use mocks for HealthKit/Strava to avoid network or device-state coupling.
- UI smoke tests live in `onMyTssUITests`; keep launch tests lightweight and avoid blocking permission alerts in automation.
- Aim for coverage on calculation paths (BodyBatteryEngine, LoadCalculator, TSSCalculator) and persistence (DataStore). Add regression tests when fixing bugs.

## Commit & Pull Request Guidelines
- Follow the repo’s history pattern: short, capitalized, imperative summaries (e.g., "Fix HealthKit permission flow", "Performance: Parallelize data fetching"). Keep to ~50 characters when possible.
- PRs should include: what changed and why, testing done (simulator device/OS, commands), any screenshots for UI tweaks, and links to issues/notes. Call out configuration steps (e.g., Strava keys) or migration needs.

## Security & Configuration Tips
- Never commit `StravaConfig.swift` or real credentials; keep them in local untracked files. Confirm `.gitignore` is honored before pushing.
- Treat HealthKit data carefully; avoid logging sensitive values and sanitize debug prints before release builds.
