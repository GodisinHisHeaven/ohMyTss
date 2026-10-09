# Xcode Cloud

The `Workflow` workflow builds `onMyTss/onMyTss.xcodeproj` with the shared
`onMyTss` scheme. Its Branch Changes condition matches `main` and any changed
file, so merging a pull request into `main` starts a build automatically.

The archive uses **TestFlight (Internal Testing Only)** and the post-action
sends it to the existing **close door** internal testing group.

## Strava configuration

Keep `STRAVA_CLIENT_ID` and `STRAVA_CLIENT_SECRET` configured as secret shared
environment variables in Xcode Cloud. The executable `ci_post_clone.sh`, next
to the Xcode project, validates them and creates the ignored
`Config/Secrets.xcconfig` before Xcode reads the project. Values are never
printed by this script. Both Debug and Release already reference this file.

For a local build, create `onMyTss/Config/Secrets.xcconfig` with your own values:

```xcconfig
STRAVA_CLIENT_ID = <numeric client ID>
STRAVA_CLIENT_SECRET = <client secret>
```

Do not commit that file or put credentials in the shared scheme. The app reads
the generated Info.plist values when launched outside Xcode, including TestFlight.

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
