# Xcode Cloud (optional legacy workflow)

The `Workflow` workflow builds `onMyTss/onMyTss.xcodeproj` with the shared
`onMyTss` scheme. Check its current settings before use; direct TestFlight
uploads do not require this workflow.

The archive uses **TestFlight (Internal Testing Only)** and the post-action
sends it to the existing **close door** internal testing group.

The **Test - iOS** action must be **Required To Pass**. This was corrected on
2026-10-26 after Build 24's optional test action allowed distribution before
testing finished. Keep this requirement enabled when editing or recreating the
workflow. Run the required full suite in CI or locally and exercise affected
Release flows; see the repository's release gates in `AGENTS.md`.

Test bundles run serially on each destination. Keep every test enabled and the
recommended iPhone destinations selected. Build 25 encountered parallel worker
startup failures (`SBMainWorkspace` reported an unknown test-runner application
identifier) despite completed test suites. Serial execution avoids extra
parallel worker launches; it does not reduce test or device coverage.

## Strava configuration

The shared Strava application is named `ohMyTss`, client ID `167899`. Its
callback domain is `coach-ota.fly.dev`; the iOS redirect URI is
`ohmytss://coach-ota.fly.dev/strava/callback`. The backend uses HTTPS on the
same host. Do not configure `onmytss.com` as the callback domain.

Keep `STRAVA_CLIENT_ID` and `STRAVA_CLIENT_SECRET` configured as secret shared
environment variables in Xcode Cloud. The executable `ci_post_clone.sh`, next
to the Xcode project, validates them and creates the ignored
`Config/Secrets.xcconfig` before Xcode reads the project. Values are never
printed by this script. Both Debug and Release already reference this file.

For a local build, copy `onMyTss/Config/Secrets.xcconfig.template` to
`onMyTss/Config/Secrets.xcconfig` and replace the placeholders with your own values:

```xcconfig
STRAVA_CLIENT_ID = <numeric client ID>
STRAVA_CLIENT_SECRET = <client secret>
```

Do not commit that file or put credentials in the shared scheme. The app reads
the generated Info.plist values when launched outside Xcode, including TestFlight.

The app target also runs `validate_strava_credentials.sh` on every build.
Missing, placeholder, or malformed values produce warnings in Debug and stop
Release builds. This phase never prints credential values. Command-line build
settings can override the local file; the file must still exist because the
project references it.

## Verification

Run the configuration regression tests from the repository root:

```sh
python3 -B -m unittest discover -s onMyTss/ci_scripts/tests -v
```

### Direct TestFlight verification

After uploading an internal-only archive, dispatch **Verify direct TestFlight
distribution** on `main` with its marketing version and build number. The job
uses read-only App Store Connect requests, waits for Apple processing, and
checks that the build is valid and available to the **close door** internal
group. It does not start Xcode Cloud or require a browser session.

Configure the repository's Actions secrets with an App Store Connect API key
that can read this app and its internal TestFlight builds:
`ASC_ISSUER_ID`, `ASC_KEY_ID`, and `ASC_PRIVATE_KEY` (the complete `.p8` PEM
contents). Keep the key out of the repository and logs. The optional repository
variables `ASC_APP_ID` and `ASC_BETA_GROUP` override the defaults `6755509363`
and `close door`. A missing credential, insufficient access, ambiguous group,
or unknown result fails the check; a timeout also fails rather than reporting
distribution as complete. Configure secret access in the repository settings
and rotate or revoke the API key if it is exposed.

For example:

```sh
gh workflow run direct-testflight.yml --ref main -f version=0.0.6 -f build=44
```

A green result confirms internal group availability, not App Store review or
installation on a particular device. Apple build metadata does not prove the
archive's source commit, so record the tested merge SHA and archive provenance
separately. The older **Verify TestFlight distribution** workflow remains
available only for explicit Xcode Cloud recovery and does not run on pushes.

Apple reference: [Writing custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts).
