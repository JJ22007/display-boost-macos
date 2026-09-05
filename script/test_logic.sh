#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BINARY="$ROOT_DIR/.build/displayboost-logic-tests"

mkdir -p "$ROOT_DIR/.build"
swiftc \
  "$ROOT_DIR/Sources/DisplayBoost/Models/BacklightObservation.swift" \
  "$ROOT_DIR/Sources/DisplayBoost/Models/BoostLevel.swift" \
  "$ROOT_DIR/Sources/DisplayBoost/Models/BrightnessKeyStep.swift" \
  "$ROOT_DIR/Sources/DisplayBoost/Models/BrightnessMediaKeyEvent.swift" \
  "$ROOT_DIR/Sources/DisplayBoost/Models/ColorProfileIdentity.swift" \
  "$ROOT_DIR/Tests/LogicTests/main.swift" \
  -o "$TEST_BINARY"
"$TEST_BINARY"
