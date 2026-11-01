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
and its manual branch condition must clearly include main. It rejects a newer
matching run, an ambiguous newer run, reruns of a GitHub Actions attempt, and a
changed main SHA. Apple may omit the cancellation reason or provide free text;
the retry does not depend on that diagnostic and logs only a restricted enum-like
value, or `unavailable` otherwise. Concurrent retry dispatches are serialized.
It sends a single create request and never automatically retries an uncertain
response. The key is used only in the guarded retry and verification
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

# Starting current main using an older canceled run

If the current main SHA has no Cloud run and the automatic branch condition is
not available, `Start current main from historical Cloud run` can be dispatched
manually on protected `main` with an explicitly confirmed start and a canceled
main-branch run from an ancestor commit. The historical run is used only to
identify and validate the app, active main ref and its sole current Cloud
workflow; its build is not considered successful. A complete local checkout must
prove ancestry, and the current main SHA must remain unchanged. The workflow must
have the exact manual main condition and the required Build, iOS Test and Archive
configuration. The job does not change the Cloud workflow and does not restore
automatic push triggering.

Before the one POST, the job reads the complete Apple product build list twice.
It refuses an existing current-SHA run, a run with an unknown SHA, or a list in
which the historical run is not visible. It also requires this to be the only
GitHub dispatch of this dedicated workflow for the SHA, and forbids reruns.
This may conservatively block a second attempt even when the first stopped before
POST. GitHub dispatch history can also lag or be deleted, so it is not a durable
idempotency ledger. GitHub workflow concurrency serializes this repository's
recovery jobs, but Apple lists may lag and other clients are not locked out:
absence from those reads cannot guarantee that no other run exists or is being
created.

Any lost or unclear POST response, later lookup failure, or main race must be
investigated in Xcode Cloud. A returned run ID is retained in the log when known.
**Never blindly dispatch again**: the original request may have created a run,
including one not yet visible. The API starts a branch reference rather than an
immutable SHA; checking main before and after and inspecting the created run can
detect a race but cannot undo it. The job passes the created ID to the unchanged
TestFlight verifier, which still requires successful Build, Test, Archive,
distribution post-action and the intended internal group. The workflow API does
not expose post-action settings, so this preflight cannot verify those settings
or prove they remained unchanged. Only the real build verifies distribution.

# Configuring a manual main start condition

The `Configure Xcode Cloud manual main` workflow is manual-dispatch only and
runs from protected `main`. Supply a canceled main-branch run ID. Its
`apply_change` input defaults to false, which performs a read-only preflight.
For that read-only inspection, the run may instead use an ancestor of current
main if the exact checkout is complete, the ancestor check succeeds, and the app
has exactly one current Cloud workflow matching the run. Multiple workflows,
missing history, different repositories, or a changed main cause a refusal.
Git ancestry includes merged side-branch commits; it does not prove the commit
was on main's first-parent history, that its build succeeded, or that its old
post-action configuration is unchanged. A historical run is never accepted for
an update or to create a replacement build.
With explicit `true`, the workflow can add an exact `main` manual start condition
only for a canceled run at the current main SHA and when Apple explicitly returns
the existing manual condition as null. Missing or non-null conditions are rejected
for updates. Read-only preflight also accepts
existing non-null conditions after the identity and required-action checks. It
reports missing/null/non-null status and a conservative branch-coverage category:
`exact main`, `covers main but broader`, `does not cover main`, `not configured`,
or `unknown`. Unknown shapes and multiple patterns are not interpreted. It never
prints the condition's contents. Coverage describes the visible branch rule;
it does not establish before-and-after configuration equality, authorize a new
build, or prove that a build can reach TestFlight. The update request contains no
other field.

Read-only inspection also reports whether the automatic branch condition is
missing, null, configured or unrecognized; its source's conservative main
coverage; whether a file rule is missing, null, present or unrecognized; and the
auto-cancel state. It does not print patterns or file-rule contents. These fields
describe the current configuration only: they cannot establish why a specific push
did or did not create a build, nor prove the settings were unchanged by a prior
update. `configured` means only that an object was returned; its complete
structure and effectiveness are not established by this report.

Preflight checks the app, GitHub repository and Cloud branch, current main SHA,
workflow state, Build/Test/Archive action names, platforms and schemes, and the
required `Test - iOS` action's platform and test configuration. Test destinations
must have a documented kind; simulated destinations must identify their device
type and runtime. This checks visible structure and before-and-after equality,
not that a particular destination, scheme, or test plan actually ran successfully. The later build must meet the existing verification gate.
It reads the workflow again immediately before one PATCH, then reads it back and
compares all returned configuration attributes, relationship data, and included
resource attributes. The modification timestamp and the intended manual condition
are excluded from the post-update comparison. Missing key fields fail the check.
Configuration and retry workflows share a GitHub concurrency group. This does not
lock out App Store Connect, Xcode, or other clients: Apple does not document an
atomic conditional PATCH here, so another edit could race between the final read
and the update. The job never starts a build and does not automatically retry an
uncertain PATCH; inspect the actual Cloud configuration before any later action.
If a write returned but verification failed, the log reports only a fixed failure
stage and error type, without server-supplied values. The write may still have
applied; do not retry or start a build based on that failure alone.

Apple's workflow API does not expose the TestFlight post-action configuration or
its target groups. The sparse PATCH does not request changes to them, but readback
cannot establish that those hidden settings stayed unchanged. A later real build
must pass the existing TestFlight verification to confirm actual distribution to
the intended internal group. That result validates the build, not an invisible
before-and-after settings comparison. If the workflow restricts editing, Apple
requires an Admin or App Manager; do not assume the existing Developer API key
can edit it. A 403 is reported and must not trigger a permission change or retry.
