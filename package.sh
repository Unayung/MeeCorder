#!/usr/bin/env bash
# Package MeeCorder for colleagues: signed with Developer ID, notarized by Apple, in a DMG that opens
# without Gatekeeper warnings. Run it in Terminal on the Mac (signing needs the unlocked login keychain).
#
# Once per Mac:
#   1. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#   2. xcrun notarytool store-credentials meet-recorder --apple-id <Apple ID> --team-id <team ID>
#   3. vendor/Sparkle/bin/generate_keys, and put the public key it prints in Info.plist as SUPublicEDKey.
#      The private key stays in this Mac's keychain and signs every update: back it up.
#
# Afterwards upload the DMG to a GitHub release named v<version>, then commit and push appcast.xml:
# installed copies read it to find the update.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$here/build/MeeCorder.app"
profile="${NOTARY_PROFILE:-meet-recorder}"

identity="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
[ -n "$identity" ] || { echo "No Developer ID Application certificate; see step 1 at the top of $0." >&2; exit 1; }

IDENTITY=- "$here/build.sh"
"$here/sign.sh" "$identity" "$app" --timestamp --options runtime

version="$(plutil -extract CFBundleShortVersionString raw "$here/Info.plist")"
build="$(plutil -extract CFBundleVersion raw "$here/Info.plist")"
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

# Sparkle compares sparkle:version with CFBundleVersion, and checks the EdDSA signature before installing.
signature="$("$here/vendor/Sparkle/bin/sign_update" "$dmg")"
cat > "$here/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MeeCorder</title>
    <item>
      <title>MeeCorder $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <link>https://github.com/Unayung/MeeCorder/releases/tag/v$version</link>
      <enclosure url="https://github.com/Unayung/MeeCorder/releases/download/v$version/MeeCorder-$version.dmg"
                 type="application/octet-stream" $signature/>
    </item>
  </channel>
</rss>
XML
echo "Ready: $dmg (appcast.xml updated)"
