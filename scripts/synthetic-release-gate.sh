#!/usr/bin/env bash
set -euo pipefail
[[ "${RUNNER_ENVIRONMENT:-}" == github-hosted && "${RUNNER_OS:-}" == macOS ]]
[[ "${RUNNER_TEMP:-}" == /Users/runner/work/* ]]
repo="$RUNNER_TEMP/gate-repository"
results="$RUNNER_TEMP/release-gate-results"
base=ce30fdea369ecde9f5c579586af0a3902897472d
head=4560edef02cdd1094b4f20acc0c6d12482a13005
[[ "$(git -C "$repo" rev-parse "$head^1")" == "$base" ]]
mkdir -p "$results" "$RUNNER_TEMP/release-gate-old" "$RUNNER_TEMP/release-gate-new"
git -C "$repo" archive "$base" | tar -x -C "$RUNNER_TEMP/release-gate-old"
git -C "$repo" archive "$head" | tar -x -C "$RUNNER_TEMP/release-gate-new"
# Alter only the old Debug seed fixture: keep all product code in the PR Release
# archive untouched, and make historical sensor/user data nontrivial.
python3 - "$RUNNER_TEMP/release-gate-old/onMyTss/onMyTss/Utilities/LaunchHistoryFixture.swift" <<'PYOLD'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
needle='            workout.sessionGroupID = workout.id\n            context.insert(workout)\n'
replacement='            var syntheticFeatures = WorkoutFeatures()\n            syntheticFeatures.end = start.addingTimeInterval(3600)\n            syntheticFeatures.heartRate = (0..<600).map { sample in\n                let from = start.addingTimeInterval(Double(sample) * 5)\n                return TimedValue(start: from, end: from.addingTimeInterval(5), value: 140)\n            }\n            workout.features = syntheticFeatures\n            if index == 0 {\n                workout.userTags = ["history-sentinel-tag"]\n                context.insert(StrengthSetRecord(sessionID: workout.id, exerciseID: "squat", reps: 8, weightKG: 42, rir: 1))\n                let observation = LocalObservation(regionRaw: "quads", sideRaw: "left", severity: 2,\n                                                   observedAt: start, sessionID: workout.id)\n                observation.note = "synthetic sentinel note"\n                context.insert(observation)\n            }\n            workout.sessionGroupID = workout.id\n            context.insert(workout)\n'
assert s.count(needle)==1
p.write_text(s.replace(needle,replacement))
PYOLD
git -C "$repo" show "$GITHUB_SHA:onMyTss/onMyTssUITests/ReleaseSavedHistoryGateTests.swift" > "$RUNNER_TEMP/release-gate-new/onMyTss/onMyTssUITests/ReleaseSavedHistoryGateTests.swift"
git -C "$repo" show "$GITHUB_SHA:onMyTss/onMyTssUITests/ReleaseBatchStrengthGateTests.swift" > "$RUNNER_TEMP/release-gate-new/onMyTss/onMyTssUITests/ReleaseBatchStrengthGateTests.swift"
git -C "$repo" show "$GITHUB_SHA:scripts/synthetic-release-db.py" > "$RUNNER_TEMP/synthetic-release-db.py"
git -C "$repo" show "$GITHUB_SHA:scripts/synthetic-release-install.py" > "$RUNNER_TEMP/synthetic-release-install.py"
for variant in old new; do
  mkdir -p "$RUNNER_TEMP/release-gate-$variant/onMyTss/Config"
  printf '%s\n' 'STRAVA_CLIENT_ID = 123456' 'STRAVA_CLIENT_SECRET = CI_SYNTHETIC_ONLY' > "$RUNNER_TEMP/release-gate-$variant/onMyTss/Config/Secrets.xcconfig"
done
# Prove the Release app's source is byte-identical to the PR head. Only a new
# UI-test source and ignored synthetic configuration are present in the copy.
python3 - "$RUNNER_TEMP/release-gate-new" "$repo" "$head" <<'PY'
import hashlib, subprocess, sys
from pathlib import Path
root=Path(sys.argv[1]); repo=sys.argv[2]; head=sys.argv[3]
paths=subprocess.check_output(['git','-C',repo,'ls-tree','-r','--name-only',head,'--','onMyTss/onMyTss','onMyTss/onMyTssWeeklyWidget'],text=True).splitlines()
assert paths
for path in paths:
    expected=subprocess.check_output(['git','-C',repo,'show',f'{head}:{path}'])
    actual=(root/path).read_bytes()
    assert hashlib.sha256(expected).digest()==hashlib.sha256(actual).digest(),path
print(f'Verified {len(paths)} tracked product files match PR head')
PY
arch="$(uname -m)"
[[ "$arch" == arm64 || "$arch" == x86_64 ]]
{
  printf 'diagnostic=%s\nhead=%s\nold=%s\n' "$GITHUB_SHA" "$head" "$base"
  sw_vers
  xcodebuild -version
  uname -m
} | tee "$results/environment.txt"
xcrun simctl list runtimes available --json > "$results/runtimes.json"
xcrun simctl list devicetypes --json > "$results/device-types.json"
xcrun simctl list devices available --json > "$results/devices.json"
python3 - "$results/runtimes.json" "$results/device-types.json" "$results/devices.json" "$arch" > "$results/selection.txt" <<'PY'
import json,re,sys
runtimes=json.load(open(sys.argv[1]))['runtimes']; types=json.load(open(sys.argv[2]))['devicetypes']; devices=json.load(open(sys.argv[3]))['devices']; arch=sys.argv[4]
byid={t['identifier']:t for t in types}; candidates=[]
for r in runtimes:
    rid=r.get('identifier',''); m=re.search(r'\.iOS-(\d+)-(\d+)$',rid)
    if not (r.get('isAvailable') and m and tuple(map(int,m.groups())) >= (26,1) and arch in r.get('supportedArchitectures',[])): continue
    supported={t['identifier']:t.get('name') for t in r.get('supportedDeviceTypes',[])}
    for device in devices.get(rid,[]):
        name=device.get('name',''); ident=device.get('deviceTypeIdentifier','')
        if device.get('isAvailable') and name.startswith('iPhone') and byid.get(ident,{}).get('name')==name and supported.get(ident)==name:
            candidates.append((tuple(map(int,m.groups())),name=='iPhone 17 Pro',name,rid,ident))
if not candidates: raise SystemExit('No supported iPhone runtime/device combination')
_,_,name,rid,ident=max(candidates)
print('Selected',name,rid,file=sys.stderr); print(rid,ident)
PY
read -r runtime device_type < "$results/selection.txt"
[[ -n "$runtime" && -n "$device_type" ]]
# The old main Debug app creates the synthetic upgraded store. The tested app
# and all production source paths come from the unmodified PR-head Release app.
xcodebuild build -project "$RUNNER_TEMP/release-gate-old/onMyTss/onMyTss.xcodeproj" \
  -scheme onMyTss -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$RUNNER_TEMP/release-gate-old-derived" -jobs 1 \
  CODE_SIGNING_ALLOWED=NO ARCHS="$arch" ONLY_ACTIVE_ARCH=YES > "$results/old-debug-build.log" 2>&1 || { tail -100 "$results/old-debug-build.log"; exit 1; }
xcodebuild build-for-testing -project "$RUNNER_TEMP/release-gate-new/onMyTss/onMyTss.xcodeproj" \
  -scheme onMyTss -configuration Release -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$RUNNER_TEMP/release-gate-new-derived" -jobs 1 \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES ARCHS="$arch" ONLY_ACTIVE_ARCH=YES > "$results/new-release-build.log" 2>&1 || { tail -100 "$results/new-release-build.log"; exit 1; }
udid=''
cleanup() {
  local original_status=$?
  if [[ "$udid" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    if [[ "$original_status" -ne 0 ]]; then
      printf 'failure_status=%s time=%s\n' "$original_status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$results/failure-stage.txt"
      xcrun simctl list devices --json > "$results/failure-devices.json" 2> "$results/failure-devices-error.txt" || true
      xcrun simctl get_app_container "$udid" mj6.onMyTss data > "$results/failure-container.txt" 2> "$results/failure-container-error.txt" || true
      { xcrun simctl spawn "$udid" /bin/ps -A -o pid=,comm= 2>/dev/null | awk '/onMyTss.app\/onMyTss/ {print}'; } > "$results/failure-process.txt" || true
    fi
    xcrun simctl shutdown "$udid" || true
    xcrun simctl delete "$udid" || true
  fi
}
trap cleanup EXIT
udid="$(xcrun simctl create "synthetic-release-gate-${GITHUB_RUN_ID}" "$device_type" "$runtime")"
[[ "$udid" =~ ^[0-9A-Fa-f-]{36}$ ]]
printf 'runtime=%s\ndevice_type=%s\nudid=%s\n' "$runtime" "$device_type" "$udid" | tee -a "$results/environment.txt"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
oldapp="$RUNNER_TEMP/release-gate-old-derived/Build/Products/Debug-iphonesimulator/onMyTss.app"
newapp="$RUNNER_TEMP/release-gate-new-derived/Build/Products/Release-iphonesimulator/onMyTss.app"
[[ -d "$oldapp" && -d "$newapp" ]]
bundle=mj6.onMyTss
# Inspect only our dedicated hosted simulator. Print the validated current data
# path on stdout; stage diagnostics go to stderr and the uploaded results.
observe_container() {
  local stage="$1" path state_file app_path
  [[ "$stage" =~ ^[a-z0-9_-]+$ ]]
  state_file="$results/device-$stage.json"
  printf 'stage=%s time=%s\n' "$stage" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$results/container-stages.log" >&2
  xcrun simctl list devices --json > "$state_file" || { echo 'Cannot read device state' >&2; return 1; }
  if ! python3 - "$state_file" "$udid" <<'PYDEVICE' 2>&1 | tee -a "$results/container-stages.log" >&2; then return 1; fi
import json, sys
obj=json.load(open(sys.argv[1],encoding='utf-8'))
rows=[d for group in obj['devices'].values() for d in group if d.get('udid')==sys.argv[2]]
if len(rows)!=1: raise SystemExit('Dedicated simulator missing or duplicated in device state')
d=rows[0]
print('device state:',d.get('state'),'available:',d.get('isAvailable'),flush=True)
if d.get('state')!='Booted' or not d.get('isAvailable'): raise SystemExit('Dedicated simulator is not booted/available')
PYDEVICE
  # This is diagnostic only. A failed or empty process listing is not treated
  # as proof the process is absent or present.
  { xcrun simctl spawn "$udid" /bin/ps -A -o pid=,comm= 2>/dev/null | awk '/onMyTss.app\/onMyTss/ {print}'; } \
    > "$results/app-process-$stage.txt" || true
  path="$(xcrun simctl get_app_container "$udid" "$bundle" data 2> "$results/container-$stage-error.txt")" || { echo 'Cannot resolve the bundle data container' >&2; return 1; }
  app_path="$(xcrun simctl get_app_container "$udid" "$bundle" app 2>> "$results/container-$stage-error.txt")" || { echo 'Cannot resolve the installed app bundle' >&2; return 1; }
  if ! python3 - "$path" "$app_path" "$udid" <<'PYCONTAINER' 2>&1 | tee -a "$results/container-stages.log" >&2; then return 1; fi
import os,re,sys
path,app,udid=sys.argv[1:]
root=f'/Users/runner/Library/Developer/CoreSimulator/Devices/{udid}/data/Containers/Data/Application'
pattern=re.compile(re.escape(root)+r'/[0-9A-Fa-f-]{36}$')
if not pattern.fullmatch(path): raise SystemExit('Data container not in the dedicated simulator')
expected_root=os.path.realpath(root)
actual=os.path.realpath(path)
if os.path.commonpath([expected_root, actual])!=expected_root: raise SystemExit('Data container escapes dedicated simulator')
app_root=f'/Users/runner/Library/Developer/CoreSimulator/Devices/{udid}/data/Containers/Bundle/Application'
app_pattern=re.compile(re.escape(app_root)+r'/[0-9A-Fa-f-]{36}/onMyTss\.app$')
if not app_pattern.fullmatch(app): raise SystemExit('App bundle not in the dedicated simulator')
if os.path.commonpath([os.path.realpath(app_root), os.path.realpath(app)])!=os.path.realpath(app_root):
    raise SystemExit('App bundle escapes dedicated simulator')
exists=os.path.isdir(path); default=os.path.isfile(os.path.join(path,'Library','Application Support','default.store'))
print(f'data_path={path} exists={exists} default_store_exists={default} app_bundle_exists={os.path.isdir(app)}',flush=True)
if exists: print('data_inode=',os.stat(path).st_ino,flush=True)
if not exists or os.path.islink(path) or not os.path.isdir(app): raise SystemExit('Data container or app bundle is missing')
PYCONTAINER
  printf '%s\n' "$path"
}
xcrun simctl install "$udid" "$oldapp"
container="$(observe_container old_installed)"
xcrun simctl launch --terminate-running-process "$udid" "$bundle" --v2-ui-tests --v2-large-history --v2-disk-history --v2-sync-fixture
container="$(observe_container old_launched)"
# Wait until the old app has durably committed exactly 1000 synthetic rows.
seed=''
for attempt in $(seq 1 600); do
  seed="$(python3 - "$container/tmp" <<'PY'
from pathlib import Path
import sqlite3,sys
for p in Path(sys.argv[1]).glob('ohmytss-ui-*.store'):
    try:
        d=sqlite3.connect(p.as_uri()+'?mode=ro',uri=True)
        if d.execute('select count(*) from ZWORKOUT').fetchone()[0]==1000 and d.execute('select count(*) from ZLOADESTIMATERECORD').fetchone()[0]>=1000:
            print(p); break
    except sqlite3.Error: pass
PY
)"
  [[ -n "$seed" ]] && break
  sleep 1
done
[[ "$seed" == "$container"/tmp/ohmytss-ui-*.store ]]
old_before="$(observe_container old_before_terminate)"
[[ "$old_before" == "$container" ]] || { echo 'Old container changed while seeding; refusing stale seed path' >&2; exit 1; }
xcrun simctl terminate "$udid" "$bundle" || { echo "Synthetic app termination failed; aborting before store access" >&2; exit 1; }
old_after="$(observe_container old_after_terminate)"
[[ "$old_after" == "$container" ]] || { echo 'Old container changed after termination; refusing stale seed path' >&2; exit 1; }
python3 "$RUNNER_TEMP/synthetic-release-db.py" backup "$seed" "$results/old-synthetic.store"
# Install the PR Release app over the same bundle, discover its default store
# by an initial clean launch, terminate it, then replace only this new simulator's
# app-local store with a SQLite-consistent backup from the old app.
xcrun simctl install "$udid" "$newapp"
release_installed="$(observe_container release_installed)"
[[ "$release_installed" == "$container" ]] || echo 'Release install changed data-container identity; seed remains in verified backup' >&2
xcrun simctl launch --terminate-running-process "$udid" "$bundle"
container="$(observe_container release_launched)"
default="$container/Library/Application Support/default.store"
for attempt in $(seq 1 120); do
  if [[ ! -d "$container" ]]; then
    echo 'Release data container disappeared while waiting for its default store' >&2
    observe_container release_disappeared_during_wait > /dev/null || true
    exit 1
  fi
  [[ -f "$default" ]] && break
  sleep 1
done
[[ -f "$default" ]]
release_before="$(observe_container release_before_terminate)"
[[ "$release_before" == "$container" ]] || { echo 'Release container changed before termination; refusing stale default path' >&2; exit 1; }
xcrun simctl terminate "$udid" "$bundle" || { echo "Synthetic app termination failed; aborting before store access" >&2; exit 1; }
container="$(observe_container release_after_terminate)"
[[ "$container" == "$release_before" ]] || echo 'Release data-container identity changed after termination; using validated current container' >&2
default="$container/Library/Application Support/default.store"
[[ -f "$default" ]] || { echo 'Current Release data container has no default store; refusing to create it' >&2; exit 1; }
python3 "$RUNNER_TEMP/synthetic-release-install.py" "$results/old-synthetic.store" "$default" "$container" "$results" "$RUNNER_TEMP/synthetic-release-db.py"
run="$results/release-ui"
xcodebuild test-without-building -project "$RUNNER_TEMP/release-gate-new/onMyTss/onMyTss.xcodeproj" \
  -scheme onMyTss -configuration Release -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$RUNNER_TEMP/release-gate-new-derived" -resultBundlePath "$run.xcresult" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:onMyTssUITests/ReleaseSavedHistoryGateTests/testReleaseUpgradeInterruptAndResume \
  CODE_SIGNING_ALLOWED=NO > "$run.log" 2>&1 || { tail -120 "$run.log"; exit 1; }
xcrun xcresulttool get test-results summary --path "$run.xcresult" > "$run-summary.json"
python3 - "$run-summary.json" "$run.log" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); log=open(sys.argv[2],errors='replace').read()
for key,expected in {'result':'Passed','totalTestCount':1,'passedTests':1,'failedTests':0,'skippedTests':0,'expectedFailures':0}.items():
    assert s.get(key)==expected,(key,s.get(key),expected)
assert 'RELEASE_GATE_UI_COMPLETE latestHR=180 firstInFlight=true secondInFlight=true' in log
print('UI test executed exactly once and observed both in-flight states')
PY
xcrun simctl terminate "$udid" "$bundle" || true
container="$(observe_container release_after_ui)"
default="$container/Library/Application Support/default.store"
[[ -f "$default" ]] || { echo 'Current Release data container has no default store after UI test' >&2; exit 1; }
python3 "$RUNNER_TEMP/synthetic-release-db.py" verify "$default" "$results/old-synthetic.store.baseline.json"
# Exercise changed intensity and batch-strength paths in the same unmodified Release app.
run="$results/release-changed-flows"
xcodebuild test-without-building -project "$RUNNER_TEMP/release-gate-new/onMyTss/onMyTss.xcodeproj" \
  -scheme onMyTss -configuration Release -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$RUNNER_TEMP/release-gate-new-derived" -resultBundlePath "$run.xcresult" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:onMyTssUITests/ReleaseSavedHistoryGateTests/testReleaseIntensityTransitions \
  -only-testing:onMyTssUITests/ReleaseBatchStrengthGateTests/testReleaseSavesTwentySetsInOneBatch \
  CODE_SIGNING_ALLOWED=NO > "$run.log" 2>&1 || { tail -160 "$run.log"; exit 1; }
xcrun xcresulttool get test-results summary --path "$run.xcresult" > "$run-summary.json"
python3 - "$run-summary.json" "$run.log" <<'PYFLOW'
import json,sys
s=json.load(open(sys.argv[1])); log=open(sys.argv[2],errors='replace').read()
for key,expected in {'result':'Passed','totalTestCount':2,'passedTests':2,'failedTests':0,'skippedTests':0,'expectedFailures':0}.items():
    assert s.get(key)==expected,(key,s.get(key),expected)
for marker in ('RELEASE_INTENSITY_COMPLETE','RELEASE_BATCH_STRENGTH_SUBMITTED count=20 session=synthetic-launch-0'):
    assert marker in log, marker
print('Release intensity transitions and 20-set batch tests each executed once')
PYFLOW
xcrun simctl terminate "$udid" "$bundle" || true
container="$(observe_container release_after_changed_flows)"
default="$container/Library/Application Support/default.store"
[[ -f "$default" ]] || { echo 'No default store after Release changed flows' >&2; exit 1; }
python3 "$RUNNER_TEMP/synthetic-release-db.py" verify-extended "$default" "$results/old-synthetic.store.baseline.json"
# Service-level latest-input, heartbeat and cancellation tests are distinct from UI.
run="$results/release-latest-input"
xcodebuild test-without-building -project "$RUNNER_TEMP/release-gate-new/onMyTss/onMyTss.xcodeproj" \
  -scheme onMyTss -configuration Release -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$RUNNER_TEMP/release-gate-new-derived" -resultBundlePath "$run.xcresult" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -only-testing:onMyTssTests/V2EstimateResponsivenessTests/testHeartRateChangeOnThousandDiskRecordsKeepsMainActorResponsiveAndRetainsHistory \
  -only-testing:onMyTssTests/V2TodaySummaryTests/testIntensityBackgroundRequestHonorsCancellation \
  -only-testing:onMyTssTests/PendingSyncRunnerTests/testQueuedObserverDeliveryRetriesCancelledPass \
  -only-testing:onMyTssTests/V2PersistenceTests/testBackfillAllowsMainActorCancellationAndResumesWithoutDuplicateSnapshots \
  CODE_SIGNING_ALLOWED=NO > "$run.log" 2>&1 || { tail -120 "$run.log"; exit 1; }
xcrun xcresulttool get test-results summary --path "$run.xcresult" > "$run-summary.json"
python3 - "$run-summary.json" "$run.log" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); log=open(sys.argv[2],errors='replace').read()
for key,expected in {'result':'Passed','totalTestCount':4,'passedTests':4,'failedTests':0,'skippedTests':0,'expectedFailures':0}.items():
    assert s.get(key)==expected,(key,s.get(key),expected)
for marker in ('HEART_RATE_DISK_REFRESH', 'testIntensityBackgroundRequestHonorsCancellation', 'testQueuedObserverDeliveryRetriesCancelledPass', 'testBackfillAllowsMainActorCancellationAndResumesWithoutDuplicateSnapshots'):
    assert marker in log, marker
print('Release latest-input, heartbeat and cancellation tests executed exactly once each')
PY
