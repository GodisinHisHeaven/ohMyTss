# ohMyTss

An iOS training-load app with a private backend for morning status SMS.

The iOS app reads Apple Health and optional Strava activities. Users can enable
morning texts using only a verified US phone number. The backend runs only
morning status and consent replies; chat, training plans, activity summaries,
other reminders, and web coaching signup are paused. Current-day data, the local
06:00–10:30 window, and daily idempotency still govern delivery.

Open **Settings → Morning Status** and enter your phone number.
Verify it once with an SMS code to view today's summary and SMS state,
change the delivery time zone, or unsubscribe. These controls and the feature's
privacy information stay inside the app. No email or password is needed; the
app session is stored in the device Keychain. Disconnecting does not unsubscribe.
Verification alone does not subscribe or upload training data. **Enable Morning
Texts** separately consents to share the latest readiness score, sleep duration
and seven-day training minutes. The private service stores only the latest
summary; raw HealthKit samples, routes and muscle notes stay on the device.
Open and sync the app in the morning: uploads run in the foreground after local
calculation, and iOS does not guarantee fresh data while the app is closed.
All morning texts use app data. Existing subscribers connect their app summary
with separate consent; Intervals sync and morning reads are disabled. Opted-out numbers must use SMS `START` before re-enabling. Refreshing
status or uploading a summary never sends an immediate morning text.

## Today and History

Today shows the current day's saved training-readiness estimate, followed by
muscle load for today and the previous six calendar days. Saved runs, rides,
swims, walks and recorded strength exercises supply a starting grade without
requiring manual RPE. Tap a muscle to adjust its effort band and fine-tune RPE.
Left/right ratings and dates remain separate. Activities without known muscle
participation stay unrated. Opening this screen does not recalculate the full
training history or write automatic grades as user ratings.

History contains a readiness or training-load trend and up to six recent
workouts. Each workout row shows its category; tap it for details. Older
activities remain available through **Today → More → All activities**, and
existing discomfort reports through **Today → More → Discomfort reports**.

See the [RPE and readiness contract](docs/v2/MODEL.md) and
[UI research and validation](docs/v2/evidence/RPE_DASHBOARD_2026-10-26.md).

The interface combines native Liquid Glass controls with Swiss-style typography,
aligned sections and a restrained light/dark palette. `SwissStyle` owns shared
surfaces and actions; content remains on quiet, readable backgrounds. Custom
glass controls use opaque alternatives with Reduce Transparency or Increase
Contrast, and older systems use standard materials. The muscle map uses muted
colors with grade names and dates; numeric RPE controls appear when editing.

## Repository layout

- `onMyTss/`: iOS app, Xcode project, tests, and Xcode Cloud scripts.
- `backend`: private `ohmytss-backend` Git submodule. Its own repository retains
  deployment, cron, secrets, and database migrations. Access is required to
  initialize it; iOS source and local builds do not depend on it.
- `docs/`: public product and privacy pages.

Clone the iOS source normally. For backend development, initialize the pinned
private checkout with `git submodule update --init --checkout backend`, then
follow its README. Automatic submodule updates are disabled so iOS-only clones
and Xcode Cloud do not need backend repository access. Do not duplicate its
scheduled jobs in this repository.

## Naming and compatibility

Use `ohMyTss` for product text and `ohmytss` for new machine identifiers. The
private backend repository and health service identifier are `ohmytss-backend`.
The iOS URL scheme is `ohmytss`.

The Xcode project/scheme/module path `onMyTss`, App Store bundle ID
`mj6.onMyTss`, existing Keychain keys, and the previous URL scheme remain for
installed-app and Xcode Cloud compatibility. The existing Fly app and hostname
`coach-ota.fly.dev`, database, SMS sender, and delivery idempotency keys also
remain stable. These are compatibility identifiers, not product names.

## Strava

One existing Strava API application is shared by both components:

| Setting | Value |
|---|---|
| Application name | `ohMyTss` |
| Client ID | `167899` |
| Website | `https://coach-ota.fly.dev` |
| Authorization callback domain | `coach-ota.fly.dev` |
| iOS redirect URI | `ohmytss://coach-ota.fly.dev/strava/callback` |
| Backend redirect URI | `https://coach-ota.fly.dev/account/strava/callback` |

The callback-domain field is a hostname without a scheme or path. The
`onmytss.com` callback was unrelated to the deployed service and is no longer
used. Strava credentials stay in ignored local configuration, Xcode Cloud
environment variables, and the existing backend secret store.

See [Xcode Cloud configuration](onMyTss/ci_scripts/README.md) for builds and
secret injection. Do not print credentials or include them in shared schemes.

## Verification

Pull requests run the `quick` and `full` checks in GitHub Actions. Run focused
local checks when investigating a failure or device-specific change; a second
local full-suite run is not required when CI has tested the same code:

```sh
python3 scripts/test.py quick
python3 scripts/test.py full --destination 'platform=iOS Simulator,id=SIMULATOR_UDID'
python3 scripts/test.py release --destination 'platform=iOS Simulator,id=SIMULATOR_UDID'
```

`quick` checks the shared Swift domain and CI scripts. `full` also runs the
complete iOS unit and UI suite in Xcode. Choose an available simulator that
meets the test targets' deployment requirements. `release` adds Release and
migration checks for changes that need them. Confirm the merged commit, the
signed archive, and the internal TestFlight build before calling a release
complete. A compile or simulator test alone does not establish release readiness.

The runner writes a summary, individual logs, and Xcode result bundles to its
output directory; use `--output-dir` to choose where to keep them. Do not put
credentials or personal HealthKit data in test artifacts. The runner redacts
known Strava values in its text logs, but Xcode result bundles are not redacted;
use synthetic test data and review bundles before sharing. See
[Apple platform checks](docs/v2/MACOS_CHECKS.md) for the upgrade and manual
validation procedures. The PR workflow tests changes but does not distribute an app.
After the workflow is pushed and both checks have run successfully, configure the
repository's branch rules to require `Quick checks` and `iOS unit and UI tests`
before merging; the workflow file alone does not enforce that policy.

For a direct internal TestFlight release:

1. After the PR checks pass and the PR is merged, run `gh workflow run pr-tests.yml --ref main` once and wait for both checks to pass.
2. From a clean checkout of that exact `main` commit, run `python3 scripts/release_preflight.py`. It checks the current commit, the latest required GitHub checks, and the local Strava build configuration without starting a simulator.
3. Archive that commit once with the next build number and upload it for internal testing. Record the commit and archive together.
4. Run `gh workflow run direct-testflight.yml --ref main -f version=0.0.6 -f build=BUILD_NUMBER` and check the result.

The direct verifier uses the existing App Store Connect API secrets and does not
use Xcode Cloud or a browser session. Apple build metadata does not prove the
archive's Git commit; the verifier checks distribution, not archive provenance.
The preflight is a point-in-time check; repeat it if main or its checks change
before upload. The Strava check covers configuration format, not live OAuth.
Archiving and uploading still require a configured local signing identity and
Xcode account or supported App Store Connect API authentication.

Run `python -m scripts.verify` from the private `backend` checkout for its smoke
suites. Production changes must pass those checks and the deployed `/health`
and `/health/db` checks. Keep `submodule.backend.update = none`; initialize the
backend explicitly only in an authorized development checkout.
