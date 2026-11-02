#!/usr/bin/env bash
set -euo pipefail
[[ "${RUNNER_ENVIRONMENT:-}" == github-hosted && "${RUNNER_OS:-}" == macOS ]]
[[ "${RUNNER_TEMP:-}" == /Users/runner/work/* ]]
repo="$RUNNER_TEMP/gate-repository"
results="$RUNNER_TEMP/release-gate-results"
base=ce30fdea369ecde9f5c579586af0a3902897472d
head=7b94aa6184d29bb5b55ba7d6d04a7fba824b8c57
[[ "$(git -C "$repo" rev-parse "$head~4")" == "$base" ]]
mkdir -p "$results" "$RUNNER_TEMP/release-gate-old" "$RUNNER_TEMP/release-gate-new" "$RUNNER_TEMP/single-full"
git -C "$repo" archive "$base" | tar -x -C "$RUNNER_TEMP/release-gate-old"
git -C "$repo" archive "$head" | tar -x -C "$RUNNER_TEMP/release-gate-new"
git -C "$repo" archive "$head" | tar -x -C "$RUNNER_TEMP/single-full"
# Alter only the old Debug seed fixture: keep all product code in the PR Release
# archive untouched, and make historical sensor/user data nontrivial.
python3 - "$RUNNER_TEMP/release-gate-old/onMyTss/onMyTss/Utilities/LaunchHistoryFixture.swift" <<'PYOLD'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
state_needle='\n        context.insert(UserThresholds(hasCompletedOnboarding: true))\n'
state_replacement=state_needle+'        let oldState = AppState()\n        oldState.localWorkoutRepairVersion = 1\n        context.insert(oldState)\n'
assert s.count(state_needle)==1
s=s.replace(state_needle,state_replacement)
start_needle='            let start = now.addingTimeInterval(-Double(index + 1) * 86400)\n'
start_replacement='            let dayIndex = (20...22).contains(index) ? 20 : index\n            let start = now.addingTimeInterval(-Double(dayIndex + 1) * 86400)\n'
assert s.count(start_needle)==1
s=s.replace(start_needle,start_replacement)
needle='            workout.sessionGroupID = workout.id\n            context.insert(workout)\n'
replacement='''            var syntheticFeatures = WorkoutFeatures()
            syntheticFeatures.end = start.addingTimeInterval((index == 21 || index == 22) ? 4200 : 3600)
            syntheticFeatures.heartRate = (0..<600).map { sample in
                let from = start.addingTimeInterval(Double(sample) * 5)
                return TimedValue(start: from, end: from.addingTimeInterval(5), value: 140)
            }
            workout.features = syntheticFeatures
            workout.sessionGroupID = workout.id
            if index == 20 {
                workout.workoutType = "Cycling"
                workout.distance = 25000
                workout.sourceBundleIdentifier = "com.garmin.connect.mobile"
            } else if index == 21 {
                workout.workoutType = "Ride"
                workout.source = WorkoutSource.strava.rawValue
                workout.duration = 3606
                workout.distance = 25020
                workout.userTags = ["synthetic-strava-tag"]
            } else if index == 22 {
                workout.workoutType = "Cycling"
                workout.duration = 4200
                workout.distance = 25020
                workout.sourceBundleIdentifier = "com.strava.stravaride"
                workout.deviceManufacturer = "Garmin"
                workout.userTags = ["synthetic-mirror-tag"]
                workout.sessionGroupID = "synthetic-launch-21"
                workout.linkedSessionID = "synthetic-launch-21"
                workout.isSuppressed = true
            }
            if index == 0 {
                workout.userTags = ["history-sentinel-tag"]
                context.insert(StrengthSetRecord(sessionID: workout.id, exerciseID: "squat", reps: 8, weightKG: 42, rir: 1))
                let observation = LocalObservation(regionRaw: "quads", sideRaw: "left", severity: 2,
                                                   observedAt: start, sessionID: workout.id)
                observation.note = "synthetic sentinel note"
                context.insert(observation)
            }
            context.insert(workout)
'''
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
mkdir -p "$RUNNER_TEMP/single-full/onMyTss/Config"
printf '%s\n' 'STRAVA_CLIENT_ID = 123456' 'STRAVA_CLIENT_SECRET = CI_SYNTHETIC_ONLY' > "$RUNNER_TEMP/single-full/onMyTss/Config/Secrets.xcconfig"
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
python3 - "$results/devices.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))['devices']
booted=[x['udid'] for devices in d.values() for x in devices if x.get('state')=='Booted']
if booted: raise SystemExit(f'Expected an isolated runner with no booted simulator; found {booted}')
print('Verified no simulator was booted before the dedicated run')
PY
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
  local cleanup_status=0
  if [[ "$udid" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    if [[ "$original_status" -ne 0 ]]; then
      printf 'failure_status=%s time=%s\n' "$original_status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$results/failure-stage.txt"
      xcrun simctl list devices --json > "$results/failure-devices.json" 2> "$results/failure-devices-error.txt" || true
      xcrun simctl get_app_container "$udid" mj6.onMyTss data > "$results/failure-container.txt" 2> "$results/failure-container-error.txt" || true
      { xcrun simctl spawn "$udid" /bin/ps -A -o pid=,comm= 2>/dev/null | awk '/onMyTss.app\/onMyTss/ {print}'; } > "$results/failure-process.txt" || true
    fi
    xcrun simctl shutdown "$udid" || true
    xcrun simctl delete "$udid" || cleanup_status=1
    if ! xcrun simctl list devices --json | python3 -c '
import json,sys
expected,log=sys.argv[1:]
data=json.load(sys.stdin)["devices"]
rows=[x for group in data.values() for x in group]
booted=[x["udid"] for x in rows if x.get("state")=="Booted"]
retained=any(x.get("udid")==expected for x in rows)
with open(log,"a",encoding="utf-8") as f:
    print("cleanup booted",len(booted),"dedicated_retained",retained,file=f)
if booted or retained: raise SystemExit("Simulator cleanup was incomplete")
print("Verified no simulator remains booted and the dedicated simulator was removed")
' "$udid" "$results/simulator-guard.log"; then cleanup_status=1; fi
  fi
  if [[ "$original_status" -eq 0 && "$cleanup_status" -ne 0 ]]; then
    trap - EXIT
    exit 1
  fi
}
trap cleanup EXIT
udid="$(xcrun simctl create "synthetic-release-gate-${GITHUB_RUN_ID}" "$device_type" "$runtime")"
[[ "$udid" =~ ^[0-9A-Fa-f-]{36}$ ]]
printf 'runtime=%s\ndevice_type=%s\nudid=%s\n' "$runtime" "$device_type" "$udid" | tee -a "$results/environment.txt"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
assert_one_simulator() {
  xcrun simctl list devices --json | python3 -c '
import datetime,json,sys
expected, log = sys.argv[1:]
data = json.load(sys.stdin)["devices"]
booted = sorted(x["udid"] for devices in data.values() for x in devices if x.get("state") == "Booted")
with open(log, "a", encoding="utf-8") as f:
    print(datetime.datetime.now(datetime.timezone.utc).isoformat(), "booted", len(booted), "selected", booted == [expected], file=f)
if booted != [expected]:
    print(f"Expected only {expected} to be booted, found {booted}", file=sys.stderr)
    raise SystemExit(1)
' "$udid" "$results/simulator-guard.log"
}
run_one_simulator() {
  local child status=0
  "$@" &
  child=$!
  while kill -0 "$child" 2>/dev/null; do
    if ! assert_one_simulator; then
      kill -TERM "$child" 2>/dev/null || true
      wait "$child" || true
      return 1
    fi
    sleep 5
  done
  wait "$child" || status=$?
  assert_one_simulator || return 1
  return "$status"
}
assert_one_simulator
run="$results/full-ios"
run_one_simulator xcodebuild test -project "$RUNNER_TEMP/single-full/onMyTss/onMyTss.xcodeproj" \
  -scheme onMyTss -configuration Debug -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$RUNNER_TEMP/single-full-derived" -resultBundlePath "$run.xcresult" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -maximum-parallel-testing-workers 1 -enableCodeCoverage YES -jobs 1 \
  CODE_SIGNING_ALLOWED=NO > "$run.log" 2>&1 || { tail -160 "$run.log"; exit 1; }
xcrun xcresulttool get test-results summary --path "$run.xcresult" > "$run-summary.json"
python3 - "$run-summary.json" <<'PYFULL'
import json,sys
s=json.load(open(sys.argv[1]))
for key,expected in {'result':'Passed','totalTestCount':359,'passedTests':359,'failedTests':0,'skippedTests':0,'expectedFailures':0}.items():
    assert s.get(key)==expected,(key,s.get(key),expected)
print('Full single-simulator iOS suite: 359 passed, 0 failed, 0 skipped')
PYFULL
assert_one_simulator
# This is a newly created hosted simulator and the installed app/data are
# exclusively from the synthetic full-suite run above.
if xcrun simctl get_app_container "$udid" mj6.onMyTss app >/dev/null 2>&1; then
  xcrun simctl uninstall "$udid" mj6.onMyTss
fi
assert_one_simulator
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
run_one_simulator xcodebuild test-without-building -project "$RUNNER_TEMP/release-gate-new/onMyTss/onMyTss.xcodeproj" \
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
run_one_simulator xcodebuild test-without-building -project "$RUNNER_TEMP/release-gate-new/onMyTss/onMyTss.xcodeproj" \
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
for marker in ('RELEASE_INTENSITY_COMPLETE','RELEASE_BATCH_STRENGTH_SUBMITTED count=20 session=synthetic-launch-0', 'RELEASE_DETAIL_HISTORY_VISIBLE'):
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
run_one_simulator xcodebuild test-without-building -project "$RUNNER_TEMP/release-gate-new/onMyTss/onMyTss.xcodeproj" \
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
