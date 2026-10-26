#!/bin/sh
# Validate resolved build settings without printing credentials.
set +x
set -eu

severity=warning
if [ "${CONFIGURATION:-}" = Release ]; then
    severity=error
fi

invalid=0
report_invalid() {
    printf '%s: %s is missing or invalid. Set it in Config/Secrets.xcconfig or the build settings.\n' "$severity" "$1" >&2
    invalid=1
}

case "${STRAVA_CLIENT_ID:-}" in
    ''|*[!0-9]*) report_invalid STRAVA_CLIENT_ID ;;
esac
case "${STRAVA_CLIENT_SECRET:-}" in
    ''|SET_ME|YOUR_STRAVA_CLIENT_SECRET|*[!A-Za-z0-9_-]*) report_invalid STRAVA_CLIENT_SECRET ;;
esac

if [ "$invalid" -eq 1 ] && [ "$severity" = error ]; then
    exit 1
fi
