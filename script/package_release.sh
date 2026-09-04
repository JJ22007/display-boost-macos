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
swift build -c release
BUILD_BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_MACOS/$APP_NAME"
cp "$ROOT_DIR/Support/Info.plist" "$APP_CONTENTS/Info.plist"
chmod +x "$APP_MACOS/$APP_NAME"
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
plutil -lint "$APP_CONTENTS/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "$APP_BUNDLE"
