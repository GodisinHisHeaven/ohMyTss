# Xcode Cloud

The `Workflow` workflow builds `onMyTss/onMyTss.xcodeproj` with the shared
`onMyTss` scheme. Its Branch Changes condition matches `main` and any changed
file, so merging a pull request into `main` starts a build automatically.

The archive uses **TestFlight (Internal Testing Only)** and the post-action
sends it to the existing **close door** internal testing group.

The **Test - iOS** action must be **Required To Pass**. This was corrected on
2026-10-26 after Build 24's optional test action allowed distribution before
testing finished. Keep this requirement enabled when editing or recreating the
workflow. Local full-suite and Release checks are also required before merging
a release change; see the repository's release gates in `AGENTS.md`.

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

After a merge, confirm the Xcode Cloud build shows **Branch Changes** as its
start condition and matches the merge commit. Confirm Build, Test, Archive,
and the TestFlight post-action succeed, then check the same build number is
available to the internal testing group in App Store Connect.

Apple reference: [Writing custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts).
