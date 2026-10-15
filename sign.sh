#!/usr/bin/env bash
# Sign the app inside out, as notarization requires: Sparkle's helpers, the frameworks, then the app.
#   sign.sh IDENTITY APP [extra codesign options]
set -euo pipefail
identity="$1" app="$2"
shift 2
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for item in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle" \
            "$app/Contents/Frameworks/whisper.framework"; do
  codesign --force "$@" --sign "$identity" "$item"
done
codesign --force "$@" --entitlements "$here/entitlements.plist" --sign "$identity" "$app"
