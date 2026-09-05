#!/usr/bin/env bash
set -euo pipefail

APP_NAME="DisplayBoost"
BUNDLE_NAME="Display Boost.app"
BUNDLE_ID="local.jjxu.DisplayBoost"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/outputs"
APP_BUNDLE="$OUTPUT_DIR/$BUNDLE_NAME"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"

"$ROOT_DIR/script/test_logic.sh"
cd "$ROOT_DIR"
# Both architectures are packaged; runtime display capability decides support.
swift build --scratch-path .build/universal-arm64 -c release --arch arm64
ARM_BINARY="$(swift build --scratch-path .build/universal-arm64 -c release --arch arm64 --show-bin-path)/$APP_NAME"
swift build --scratch-path .build/universal-x86_64 -c release --arch x86_64
INTEL_BINARY="$(swift build --scratch-path .build/universal-x86_64 -c release --arch x86_64 --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
lipo -create "$ARM_BINARY" "$INTEL_BINARY" -output "$APP_MACOS/$APP_NAME"
cp "$ROOT_DIR/Support/Info.plist" "$APP_CONTENTS/Info.plist"
chmod +x "$APP_MACOS/$APP_NAME"
SIGN_IDENTITY="${DISPLAYBOOST_SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_BUNDLE"
fi
plutil -lint "$APP_CONTENTS/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
lipo "$APP_MACOS/$APP_NAME" -verify_arch arm64 x86_64
ditto -c -k --keepParent "$APP_BUNDLE" "$OUTPUT_DIR/Display-Boost-universal.zip"

echo "$APP_BUNDLE"
