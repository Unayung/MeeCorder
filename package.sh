#!/usr/bin/env bash
# Package MeeCorder for colleagues: signed with Developer ID, notarized by Apple, in a DMG that opens
# without Gatekeeper warnings. Run it in Terminal on the Mac (signing needs the unlocked login keychain).
#
# Once per Mac:
#   1. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#   2. xcrun notarytool store-credentials meet-recorder --apple-id <Apple ID> --team-id <team ID>
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$here/build/MeeCorder.app"
profile="${NOTARY_PROFILE:-meet-recorder}"

identity="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
[ -n "$identity" ] || { echo "No Developer ID Application certificate; see step 1 at the top of $0." >&2; exit 1; }

IDENTITY=- "$here/build.sh"
codesign --force --timestamp --options runtime --sign "$identity" "$app/Contents/Frameworks/whisper.framework"
codesign --force --timestamp --options runtime --entitlements "$here/entitlements.plist" --sign "$identity" "$app"

version="$(plutil -extract CFBundleShortVersionString raw "$here/Info.plist")"
dmg="$here/build/MeeCorder-$version.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/MeeCorder.app"
ln -s /Applications "$staging/Applications"  # Drag the app onto this to install.
hdiutil create -quiet -volname "MeeCorder" -srcfolder "$staging" -ov -format UDZO "$dmg"
codesign --timestamp --sign "$identity" "$dmg"

echo "==> Notarizing (a few minutes)"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
echo "Ready: $dmg"
