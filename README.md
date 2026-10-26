# ohMyTss

An iOS training-load app with a private backend for morning status SMS.

The iOS app reads Apple Health and optional Strava activities. Existing backend
accounts receive a morning status text after opting in. The backend runs only
morning status and consent replies; chat, training plans, activity summaries,
other reminders, and signup are paused. Current-day wellness data, the local
06:00–10:30 window, and daily idempotency still govern delivery.

Open **Settings → Morning Status** and enter the phone number linked to your
morning texts. Verify it once with an SMS code to view today's wellness and SMS state,
change the delivery time zone, or unsubscribe. These controls and the feature's
privacy information stay inside the app. No email or password is needed; the
app session is stored in the device Keychain. Disconnecting does not unsubscribe.
Resubscription continues through the existing SMS `START` consent flow.
This feature does not upload Apple Health data or send a text when refreshed.

## Today and History

Today shows the current day's saved training-readiness estimate, followed by
muscle RPE for today and the previous six calendar days. Tap a muscle, choose
an effort band, and adjust by one point if needed. Left/right ratings and dates
remain separate. Missing effort stays unrated; opening this screen does not
recalculate the full training history.

History contains a readiness or training-load trend and up to six recent
workouts. Each workout row shows its category; tap it for details. Older
activities remain available through **Today → More → All activities**, and
existing discomfort reports through **Today → More → Discomfort reports**.

See the [RPE and readiness contract](docs/v2/MODEL.md) and
[UI research and validation](docs/v2/evidence/RPE_DASHBOARD_2026-10-26.md).

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

```sh
python3 -B -m unittest discover -s onMyTss/ci_scripts/tests -v
xcodebuild test -project onMyTss/onMyTss.xcodeproj -scheme onMyTss \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:onMyTssTests
```

Run `python -m scripts.verify` from the private `backend` checkout for its smoke
suites. Production changes must pass those checks and the deployed `/health`
and `/health/db` checks. Keep `submodule.backend.update = none`; initialize the
backend explicitly only in an authorized development checkout.
