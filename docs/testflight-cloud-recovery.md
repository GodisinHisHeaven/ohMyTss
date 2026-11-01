# Recovering a canceled Xcode Cloud run

The TestFlight verification workflow uses only reads on main pushes and ordinary
manual verification runs. It checks the exact commit, required Build, iOS Test and
Archive actions, TestFlight post-action, and internal group. A canceled build is
a failure, not evidence of a completed release.

To attempt one replacement run, first identify the canceled Xcode Cloud run ID
for the **current** main commit. Dispatch `Verify TestFlight distribution` on
`main`, set `retry_canceled_cloud_run` to true and supply `canceled_run_id`.
Leave `commit_sha` blank or set it to the current main SHA. Older commits cannot
be retried by this mechanism. Dispatching does not change the Cloud workflow,
its tests or its distribution settings. The original verification still runs
after the retry has been created and its commit checked. Verification waits for
the new run ID to appear in Apple's list before deciding; it still checks the
newest exact-main run and applies all existing success requirements.

The retry requires the canceled run to belong to the configured app, its Cloud
workflow and GitHub repository, and the main branch; the workflow must be enabled
and its manual branch condition must clearly include main. It rejects missing
cancellation reasons that are missing, empty, too long, or contain control
characters; it also rejects a newer matching run, an ambiguous newer run,
reruns of a GitHub Actions attempt, and a changed main SHA. Apple may provide a
natural-language reason: the retry can accept it but only logs a restricted
enum-like value, or `unavailable` when the reason does not match that format. Concurrent retry dispatches are
serialized. It sends a single create request and never automatically retries an
uncertain response. The key is used only in the guarded retry and verification
steps; credentials and tokens must not be printed or copied to logs.

Apple starts a branch reference rather than an immutable commit. A main update
can race with creation: the script checks main before and after, then verifies
the new run's actual SHA, but cannot undo an already-created run. Apple may also
delay making a newly created run visible in subsequent list requests. If the POST
response is lost or any post-creation check fails, **do not dispatch another retry**
until the outcome has been established in Xcode Cloud. Serialization only covers
overlapping workflow runs; it cannot prevent a duplicate across separate dispatches
when Apple's list is stale. A created run does not by itself prove that tests
passed or that TestFlight distribution completed.
