#!/usr/bin/env bash
# Open a real Build 26 SwiftData store with the additive muscle-RPE schema.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'BLOCKED: this migration check requires Apple SwiftData.' >&2
    exit 2
fi
rpe_root="$(cd "$(dirname "$0")/.." && pwd)"
rpe_baseline=c5c598787432a1836c41d5ddfe912cefb7b044b9
rpe_tmp="$(mktemp -d "/private/tmp/ohmytss-rpe-migration.XXXXXX")"
trap 'rm -rf "$rpe_tmp"' EXIT
mkdir -p "$rpe_tmp/legacy"
while IFS= read -r rpe_file; do
    git -C "$rpe_root" show "$rpe_baseline:$rpe_file" > "$rpe_tmp/legacy/$(basename "$rpe_file")"
done < <(git -C "$rpe_root" ls-tree -r --name-only "$rpe_baseline" \
    onMyTss/onMyTss/Models onMyTss/onMyTss/Domain | rg '\.swift$')
xcrun --sdk macosx swiftc -swift-version 5 -module-name onMyTss -D RPE_LEGACY_SEED \
    -target "$(uname -m)-apple-macosx14.0" "$rpe_tmp/legacy/"*.swift \
    "$rpe_root/docs/v2/fixtures/RPEMigrationProbe.swift" -o "$rpe_tmp/seed"
"$rpe_tmp/seed" "$rpe_tmp/synthetic.store"
xcrun --sdk macosx swiftc -swift-version 5 -module-name onMyTss \
    -target "$(uname -m)-apple-macosx14.0" \
    "$rpe_root/onMyTss/onMyTss/Models/"*.swift "$rpe_root/onMyTss/onMyTss/Domain/"*.swift \
    "$rpe_root/docs/v2/fixtures/RPEMigrationProbe.swift" -o "$rpe_tmp/probe"
"$rpe_tmp/probe" "$rpe_tmp/synthetic.store"
