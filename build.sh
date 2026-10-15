#!/usr/bin/env bash
# Build "Meet Recorder.app" into build/, and with --install copy it to ~/Applications.
#
# Needs whisper.cpp's Apple build and the Silero voice activity model in vendor/ (kept out of Git):
#   gh release download b5454 -R ggml-org/whisper.cpp -p '*xcframework.zip' -D vendor && unzip -q -d vendor vendor/*.zip
#   curl -fL --http1.1 -o vendor/ggml-silero-v6.2.0.bin \
#     https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$here/build/Meet Recorder.app"
frameworks="$here/vendor/build-apple/whisper.xcframework/macos-arm64_x86_64"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
cp "$here/Info.plist" "$app/Contents/Info.plist"
cp "$here/vendor/ggml-silero-v6.2.0.bin" "$app/Contents/Resources/"
# Assets.car for macOS 26 and later, AppIcon.icns for older ones.
xcrun actool "$here/Icon/AppIcon.icon" --compile "$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon --output-partial-info-plist /dev/null >/dev/null
ditto "$frameworks/whisper.framework" "$app/Contents/Frameworks/whisper.framework"
xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 \
  -F "$frameworks" -framework whisper -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$app/Contents/MacOS/MeetRecorder" "$here"/Sources/*.swift

# A stable signing identity keeps the privacy grants across rebuilds; ad-hoc signing would lose them.
# Over SSH the login keychain is locked: IDENTITY=- signs ad-hoc instead.
identity="${IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${identity:--}" "$app/Contents/Frameworks/whisper.framework"
codesign --force --sign "${identity:--}" "$app"
echo "Built $app"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Meet Recorder.app"
  ditto "$app" "$HOME/Applications/Meet Recorder.app"
  echo "Installed ~/Applications/Meet Recorder.app"
fi
