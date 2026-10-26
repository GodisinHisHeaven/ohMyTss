#!/usr/bin/env bash
# Real Apple SwiftData migration; only temporary, explicitly synthetic stores are touched.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'BLOCKED: this migration check requires macOS 14+ and Apple SwiftData.' >&2
    exit 2
fi
v2_root="$(cd "$(dirname "$0")/.." && pwd)"
v2_baseline=fdab778b6b51181bd76c3627b765da8af5ed6eef
v2_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ohmytss-v2-migration.XXXXXX")"
trap 'rm -rf "$v2_tmp"' EXIT
mkdir -p "$v2_tmp/legacy"
for v2_model in Workout DayAggregate UserThresholds AppState StravaAuth; do
    git -C "$v2_root" show "$v2_baseline:onMyTss/onMyTss/Models/$v2_model.swift" > "$v2_tmp/legacy/$v2_model.swift"
done
xcrun --sdk macosx swiftc --version
xcrun --sdk macosx swiftc -swift-version 5 -module-name onMyTss \
    -target "$(uname -m)-apple-macosx14.0" \
    "$v2_tmp/legacy/"*.swift "$v2_root/docs/v2/fixtures/LegacyStoreSeed.swift" \
    -o "$v2_tmp/seed"
"$v2_tmp/seed" "$v2_tmp/legacy.store"
xcrun --sdk macosx swiftc -swift-version 5 -module-name onMyTss \
    -target "$(uname -m)-apple-macosx14.0" \
    "$v2_root/onMyTss/onMyTss/Models/"*.swift \
    "$v2_root/onMyTss/onMyTss/Domain/"*.swift \
    "$v2_root/docs/v2/fixtures/V2MigrationProbe.swift" \
    -o "$v2_tmp/probe"
"$v2_tmp/probe" "$v2_tmp/legacy.store"
