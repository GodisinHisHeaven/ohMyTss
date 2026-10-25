#!/usr/bin/env bash
# Runs exact app domain/API sources on Swift, without replacing Apple frameworks.
set -euo pipefail
v2_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$v2_root"
swift test
v2_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ohmytss-v2-http.XXXXXX")"
trap 'rm -rf "$v2_tmp"' EXIT
swiftc -swift-version 5 -parse-as-library \
  onMyTss/onMyTss/Services/StravaConfig.swift \
  onMyTss/onMyTss/Services/StravaAPI.swift scripts/VerifyStravaHTTP.swift \
  -o "$v2_tmp/verify-http"
"$v2_tmp/verify-http"
python3 -B -m unittest discover -s onMyTss/ci_scripts/tests -v
