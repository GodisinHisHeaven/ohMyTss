# HealthKit adapter review (2026-10-25)

The following Apple references were fetched from Apple's documentation JSON endpoint during implementation (HTTP success). This verifies API declarations, not iOS compilation or runtime behavior:

- [Quantity series query initializer](https://developer.apple.com/documentation/healthkit/hkquantityseriessamplequery/init(quantitytype:predicate:quantityhandler:)): callback supplies `HKQuantity?`, `DateInterval?`, `HKQuantitySample?`, `done`, and `Error?`. The production adapter reads each measurement interval; it does not spread a merged parent sample's average across an entire recording.
- [Quantity sample count](https://developer.apple.com/documentation/healthkit/hkquantitysample/count): parent samples may contain multiple measurements. The legacy sample-array adapter excludes count > 1 because it cannot recover those measurements. The production adapter uses the series query above.
- [Swimming stroke style](https://developer.apple.com/documentation/healthkit/hkswimmingstrokestyle) and [raw-value initializer](https://developer.apple.com/documentation/healthkit/hkswimmingstrokestyle/init(rawvalue:)): metadata is interpreted via enum cases, never assumed numeric case ordering.
- [Workout route query](https://developer.apple.com/documentation/healthkit/hkworkoutroutequery/init(route:datahandler:)): batches are accumulated until the terminal callback, with one continuation completion even if an error occurs.

## Implemented behavior

- Quantity-series reads prefer samples associated with the workout. Empty association results permit a date-range fallback restricted to the workout's `HKSource`. Provenance explicitly says when association is uncertain or samples are unreadable.
- `failedChannels` and `unavailableChannels` preserve the distinction between query failure, no readable results and an observed zero. Machine IDs are `heartRate`, `power`, `cadence`, `speed`, `terrain`; human explanations stay in `provenance`.
- Heart rate, cycling power, cycling cadence, and running speed preserve timestamped support. Pause/resume and motion pause/resume events become explicit excluded intervals. Unknown pauses are not invented.
- Route-derived features retain elevation/grade only, never latitude/longitude. Accuracy filters, a five-point median altitude and a 15 m grade baseline reduce noise; gaps over 30 s reset support. Sparse/absent routes remain unknown.
- Swimming lap/segment or workout metadata is retained as coarse stroke segments. Absent stroke or equipment remains unknown; manual equipment tags belong to the activity detail flow.
- Traditional and functional strength map to `Strength`. Missing cycling FTP never suppresses runs, swims, strength, or cycling history.
- `fetchWorkoutChanges` returns explicit deletion UUIDs and an anchor. Empty readable results are not deletion evidence. The caller must persist additions/deletions before committing the anchor.
- Source failure is isolated: usable HealthKit data can still import when Strava is offline, and usable Strava data can still import when HealthKit is unavailable. Imported source aliases are retained for persistence while the visible list deduplicates.
- Power TSS is integrated using observed duration and 30 elapsed second NP windows. Legacy HR-TSS integrates interval intensity; its assumptions are named. V2 Cardio Load uses a separate domain method.

## Checks executed

```
/workspace/toolchains/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/swiftc -frontend -parse \
  onMyTss/onMyTss/Services/HealthKitManager.swift \
  onMyTss/onMyTss/Services/WorkoutAggregator.swift \
  onMyTss/onMyTss/Services/TSSCalculator.swift \
  onMyTss/onMyTssTests/HealthKitImportV2Tests.swift
```

Result: exit 0 (syntax parsing only; no Apple framework type checking).

`git diff --check`: no whitespace errors at this checkpoint.

`HealthKitImportV2Tests.swift` adds synthetic converter behavior checks for missing FTP, pause-aware observed TSS, sensor failure, duplicate-source retention and HR intensity integration. These tests require an iOS SDK and have **not run** in this Linux environment. Real quantity series, permission-denied/empty results, route reads, and HealthKit tombstones still require device/simulator integration validation. Synthetic tests do not establish physiological accuracy.

## Strava unavailable-source reconciliation follow-up

A complete successful activity listing now identifies locally known Strava source IDs missing within the exact epoch-second request boundaries. Each missing source is verified with `GET /activities/{id}`. Only HTTP 404 produces `latestDeletedStravaIDs`; HTTP 200 reimports the detail (including a corrected date outside the requested window). HTTP 401/403/429, offline transport errors, partial pagination and invalid responses retain local source data. Verification stops after a failed detail request to avoid repeated rate-limit or authorization failures.

A 404 is **source unavailability under the current authorization**, not proof that the user physically deleted the activity. The app removes that source's contribution and retains personal sets/observations. Empty list results alone never cause deletion. Sources outside the normal refresh window require a broader synchronization to observe deletion; this implementation does not install a webhook or server.

`StravaSourceAvailabilityTests.swift` adds synthetic HTTP status mapping and production-aggregator checks for successful listing + missing detail, corrected dates, exact-window exclusions, failed listing and permission failure. These are iOS tests and remain unexecuted here. Syntax parsing of StravaAPI, WorkoutAggregator and the new tests returned exit 0; this is not Apple-framework type checking.

The HTTP-only portion was subsequently **compiled and executed on Linux against the exact production `StravaAPI.swift` and `StravaConfig.swift`**, with FoundationNetworking (not an Apple framework substitute):

```sh
swiftc -swift-version 5 -parse-as-library \
  onMyTss/onMyTss/Services/StravaConfig.swift \
  onMyTss/onMyTss/Services/StravaAPI.swift \
  scripts/VerifyStravaHTTP.swift -o /tmp/ohmytss-verify-strava-http
/tmp/ohmytss-verify-strava-http
```

Result: exit 0; 9 synthetic cases passed (200, 404, 401, 403, 429, 500, offline, invalid JSON, mismatched activity ID). Output: `docs/v2/evidence/strava-http.txt`. HTTP responses are supplied through URLProtocol; no real account or health data is used. SwiftData reconciliation and iOS adapter tests remain blocked until executed with the Apple toolchain.
