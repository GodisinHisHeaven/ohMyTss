#!/usr/bin/env bash
set -euo pipefail
[[ "${RUNNER_ENVIRONMENT:-}" == github-hosted && "${RUNNER_OS:-}" == macOS ]]
[[ "${RUNNER_TEMP:-}" == /Users/runner/work/* ]]
repo="$RUNNER_TEMP/perf-repository"
results="$RUNNER_TEMP/perf-results"
head=4560edef02cdd1094b4f20acc0c6d12482a13005
base=ce30fdea369ecde9f5c579586af0a3902897472d
[[ "$(git -C "$repo" rev-parse "$head^1")" == "$base" ]]
mkdir -p "$results" "$RUNNER_TEMP/perf-A" "$RUNNER_TEMP/perf-B"
for variant in A B; do
  git -C "$repo" archive "$head" | tar -x -C "$RUNNER_TEMP/perf-$variant"
  git -C "$repo" show "$GITHUB_SHA:onMyTss/onMyTssTests/SingleRecalculatePerformanceDiagnostics.swift" > "$RUNNER_TEMP/perf-$variant/onMyTss/onMyTssTests/SingleRecalculatePerformanceDiagnostics.swift"
  mkdir -p "$RUNNER_TEMP/perf-$variant/onMyTss/Config"
  printf '%s\n' 'STRAVA_CLIENT_ID = 123456' 'STRAVA_CLIENT_SECRET = CI_SYNTHETIC_ONLY' > "$RUNNER_TEMP/perf-$variant/onMyTss/Config/Secrets.xcconfig"
done
git -C "$repo" show "$base:onMyTss/onMyTss/Services/V2EstimateBatch.swift" > "$RUNNER_TEMP/perf-A/onMyTss/onMyTss/Services/V2EstimateBatch.swift"
# Only the tested source file may differ between the two complete archives.
python3 - "$RUNNER_TEMP/perf-A" "$RUNNER_TEMP/perf-B" <<'PY'
from pathlib import Path
import hashlib, sys
a, b = map(Path, sys.argv[1:])
expected = 'onMyTss/onMyTss/Services/V2EstimateBatch.swift'
def manifest(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}
x, y = manifest(a), manifest(b)
assert x.keys() == y.keys(), 'Archive file inventories differ'
changed = [name for name in x if x[name] != y[name]]
assert changed == [expected], f'Unexpected archive differences: {changed}'
print('Only source difference:', expected, x[expected], y[expected])
PY
{
  printf 'diagnostic=%s\nhead=%s\nbaseline=%s\n' "$GITHUB_SHA" "$head" "$base"
  sw_vers
  xcodebuild -version
  uname -m
} | tee "$results/environment.txt"
arch="$(uname -m)"
[[ "$arch" == arm64 || "$arch" == x86_64 ]]
xcrun simctl list runtimes available --json > "$results/runtimes.json"
xcrun simctl list devicetypes --json > "$results/device-types.json"
xcrun simctl list devices available --json > "$results/devices.json"
python3 - "$results/runtimes.json" "$results/device-types.json" "$results/devices.json" "$arch" > "$results/selection.txt" <<'PYCODE'
import json, re, sys
runtimes=json.load(open(sys.argv[1], encoding='utf-8'))['runtimes']
types=json.load(open(sys.argv[2], encoding='utf-8'))['devicetypes']
devices=json.load(open(sys.argv[3], encoding='utf-8'))['devices']
arch=sys.argv[4]
type_by_id={t['identifier']:t for t in types if t.get('identifier') and t.get('name')}
choices=[]
for r in runtimes:
    runtime_id=r.get('identifier','')
    match=re.search(r'\.iOS-(\d+)-(\d+)$',runtime_id)
    if not (r.get('isAvailable') and match and tuple(map(int,match.groups())) >= (26,1)):
        continue
    if arch not in r.get('supportedArchitectures',[]):
        continue
    supported={t['identifier']:t.get('name') for t in r.get('supportedDeviceTypes',[]) if t.get('identifier')}
    for existing in devices.get(runtime_id,[]):
        name=existing.get('name','')
        type_id=existing.get('deviceTypeIdentifier','')
        device_type=type_by_id.get(type_id,{})
        if (existing.get('isAvailable') and name.startswith('iPhone')
                and device_type.get('name') == name and supported.get(type_id) == name):
            choices.append((tuple(map(int,match.groups())), name == 'iPhone 17 Pro', name, runtime_id, type_id))
if not choices:
    raise SystemExit(f'No available iPhone with matching device type and {arch} runtime support')
_, _, name, runtime_id, type_id=max(choices)
print(f'Selected existing compatible device type {name} for {runtime_id} ({arch})',file=sys.stderr)
print(runtime_id,type_id)
PYCODE
read -r runtime device_type < "$results/selection.txt"
[[ -n "$runtime" && -n "$device_type" ]]
# Compile without booting a device. Each variant uses its own derived data.
for variant in A B; do
  xcodebuild build-for-testing -project "$RUNNER_TEMP/perf-$variant/onMyTss/onMyTss.xcodeproj" \
    -scheme onMyTss -configuration Release -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$RUNNER_TEMP/perf-derived-$variant" -jobs 1 \
    CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES ARCHS="$arch" ONLY_ACTIVE_ARCH=YES \
    > "$results/build-$variant.log" 2>&1 || { tail -100 "$results/build-$variant.log"; exit 1; }
done
udid=''
cleanup() {
  if [[ "$udid" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    xcrun simctl shutdown "$udid" || true
    xcrun simctl delete "$udid" || true
  fi
}
trap cleanup EXIT
udid="$(xcrun simctl create "synthetic-performance-${GITHUB_RUN_ID}" "$device_type" "$runtime")"
[[ "$udid" =~ ^[0-9A-Fa-f-]{36}$ ]]
printf 'runtime=%s\ndevice_type=%s\nudid=%s\n' "$runtime" "$device_type" "$udid" | tee -a "$results/environment.txt"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
index=0
for variant in A B B A A B B A; do
  index=$((index + 1))
  run="$results/$index-$variant"
  xcodebuild test-without-building -project "$RUNNER_TEMP/perf-$variant/onMyTss/onMyTss.xcodeproj" \
    -scheme onMyTss -configuration Release -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$RUNNER_TEMP/perf-derived-$variant" -resultBundlePath "$run.xcresult" \
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
    -only-testing:onMyTssTests/SingleRecalculatePerformanceDiagnostics/testRecalculateThousandDiskRunsPreservesPersonalData \
    -only-testing:onMyTssTests/V2PersistenceTests/testSingleSessionRecalculationMatchesFullHistoryAcrossRunningWindow \
    -only-testing:onMyTssTests/V2PersistenceTests/testSingleSessionRecalculationHandlesNoPriorRunsAndInactiveTargets \
    -only-testing:onMyTssTests/V2PersistenceTests/testSingleSessionGarminAliasesMatchFullHistoryWithoutDuplicateVersion \
    CODE_SIGNING_ALLOWED=NO > "$run.log" 2>&1 || { tail -100 "$run.log"; exit 1; }
  xcrun xcresulttool get test-results summary --path "$run.xcresult" > "$run-summary.json"
  python3 - "$run-summary.json" <<'PY'
import json, sys
s=json.load(open(sys.argv[1],encoding='utf-8'))
expected={'result':'Passed','totalTestCount':4,'passedTests':4,'failedTests':0,'skippedTests':0,'expectedFailures':0}
for key, value in expected.items():
    if s.get(key) != value: raise SystemExit(f'{key}: expected {value!r}, got {s.get(key)!r}')
PY
done
python3 - "$results" <<'PY'
from pathlib import Path
import json, re, sys
root=Path(sys.argv[1]); rows=[]
pattern=re.compile(r'SINGLE_RECALCULATE synthetic_workouts=1001 history_samples=600 payload_bytes=(\d+) elapsed_seconds=([\d.eE+-]+) max_main_gap_seconds=([\d.eE+-]+) ticks=(\d+) input_sha256=([a-f0-9]{64}) output_sha256=([a-f0-9]{64})')
for i, v in enumerate('ABBAABBA',1):
    found=pattern.findall((root/f'{i}-{v}.log').read_text(errors='replace'))
    if len(found)!=1: raise SystemExit(f'{i}-{v}: expected one metric, found {len(found)}')
    payload,elapsed,gap,ticks,ih,oh=found[0]
    rows.append(dict(round=i,variant=v,payload_bytes=int(payload),elapsed_seconds=float(elapsed),max_main_gap_seconds=float(gap),ticks=int(ticks),input_sha256=ih,output_sha256=oh))
if len({(r['payload_bytes'],r['input_sha256'],r['output_sha256']) for r in rows})!=1:
    raise SystemExit('Synthetic input/output fingerprints differ across A/B rounds')
(root/'metrics.json').write_text(json.dumps(rows, indent=2)+'\n')
print(json.dumps(rows, indent=2))
PY
