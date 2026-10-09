#!/bin/sh
# Xcode Cloud supplies these values as secret workflow environment variables.
set +x
set -eu

case "${STRAVA_CLIENT_ID:-}" in
    ''|*[!0-9]*)
        echo "error: STRAVA_CLIENT_ID must be set to a numeric client ID in Xcode Cloud." >&2
        exit 1
        ;;
esac
case "${STRAVA_CLIENT_SECRET:-}" in
    ''|SET_ME|YOUR_STRAVA_CLIENT_SECRET|*[!A-Za-z0-9_-]*)
        echo "error: STRAVA_CLIENT_SECRET must be set to a valid secret in Xcode Cloud." >&2
        exit 1
        ;;
esac

# Use the checkout path because Xcode Cloud runs scripts from a temporary folder.
: "${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud must supply the repository path}"
config_dir="$CI_PRIMARY_REPOSITORY_PATH/onMyTss/Config"
umask 077
mkdir -p "$config_dir"
config_file="$config_dir/Secrets.xcconfig"
printf 'STRAVA_CLIENT_ID = %s\nSTRAVA_CLIENT_SECRET = %s\n' \
    "$STRAVA_CLIENT_ID" "$STRAVA_CLIENT_SECRET" > "$config_file"
chmod 600 "$config_file"
echo "Configured Strava build settings from Xcode Cloud environment variables."
