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

### Automated TestFlight verification

GitHub Actions runs **Verify TestFlight distribution** on each push to `main`.
It checks the exact push commit against Xcode Cloud and App Store Connect: a
successful cloud run with the required actions and the corresponding valid
build in the internal **close door** group. It only reads Apple's APIs; Xcode
Cloud's existing branch trigger creates and distributes the build. This check
does not create another build or require a browser login. Runs wait up to 90
minutes and do not cancel earlier commits when a new commit is pushed.

Configure the repository's Actions secrets with an App Store Connect API key
that can read this app, its Xcode Cloud data and internal TestFlight builds:
`ASC_ISSUER_ID`, `ASC_KEY_ID`, and `ASC_PRIVATE_KEY` (the complete `.p8` PEM
contents). Keep the key out of the repository and logs. The optional repository
variables `ASC_APP_ID` and `ASC_BETA_GROUP` override the defaults `6755509363`
and `close door`. A missing credential, insufficient access, ambiguous group,
or unknown result fails the check; a timeout also fails rather than reporting
distribution as complete. Configure secret access in the repository settings
and rotate or revoke the API key if it is exposed.

To retry after a delayed Xcode Cloud start or temporary API failure, run the
workflow using the `main` ref. An optional `commit_sha` selects a full 40-digit
commit reachable from that run's main commit; otherwise it checks the current
main commit. A new run only observes Apple state. Check its final output for
the matched commit, cloud run and TestFlight build. A green result confirms
internal TestFlight availability, not App Store review or public release.

The required cloud test and archive configuration above remains in Xcode Cloud;
this GitHub check observes it and does not replace those gates. The API check
establishes the resulting build and group state; it does not independently
establish which post-action or person added that build to the group, or prove
that a particular tester received an invitation or installed it.
The verifier does not distinguish Xcode Cloud workflows for the same main
commit or prove that Branch Changes started the run. It requires an action
named `Test - iOS`; if that action is renamed, verification returns unknown
until the verifier is updated.

Apple reference: [Writing custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts).
