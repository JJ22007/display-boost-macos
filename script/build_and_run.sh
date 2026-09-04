#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="DisplayBoost"
BUNDLE_NAME="Display Boost.app"
BUNDLE_ID="local.jjxu.DisplayBoost"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$BUNDLE_NAME"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"

wait_for_exit() {
  local process_id="$1"
  local attempt
  for attempt in {1..50}; do
    if ! kill -0 "$process_id" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

terminate_existing() {
  local process_id
  local process_ids
  process_ids="$(pgrep -x "$APP_NAME" || true)"
  [[ -z "$process_ids" ]] && return 0

  while IFS= read -r process_id; do
    [[ -z "$process_id" ]] && continue
    kill -TERM "$process_id"
  done <<< "$process_ids"

  while IFS= read -r process_id; do
    [[ -z "$process_id" ]] && continue
    if ! wait_for_exit "$process_id"; then
      echo "DisplayBoost process $process_id did not restore and exit" >&2
      return 1
    fi
  done <<< "$process_ids"
}

find_bundle_pid() {
  local attempt
  local candidate
  local command
  for attempt in {1..50}; do
    while IFS= read -r candidate; do
      [[ -z "$candidate" ]] && continue
      command="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
      if [[ "$command" == "$APP_BINARY"* ]]; then
        echo "$candidate"
        return 0
      fi
    done < <(pgrep -x "$APP_NAME" || true)
    sleep 0.1
  done
  return 1
}

terminate_existing

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/Support/Info.plist" "$APP_CONTENTS/Info.plist"
chmod +x "$APP_BINARY"
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"

open_app() {
  /usr/bin/open "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    APP_PID="$(find_bundle_pid)"
    kill -TERM "$APP_PID"
    if ! wait_for_exit "$APP_PID"; then
      echo "verification failed: app did not exit after SIGTERM" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
