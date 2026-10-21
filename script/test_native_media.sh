#!/bin/bash
set -euo pipefail
TASK_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TASK_NATIVE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/resolvescopes-native-media.XXXXXX")"
trap 'rm -rf "$TASK_NATIVE_DIR"' EXIT
TASK_NATIVE_SOURCES=("$TASK_PROJECT_ROOT/iPadCompanion/ResolveScopesPad/NativeRemote/NativeMediaReceiver.swift" "$TASK_PROJECT_ROOT/Tests/NativeMediaTests.swift")
if [ "${1:-}" = "--typecheck-ios" ]; then
  TASK_NATIVE_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  xcrun swiftc -target arm64-apple-ios16.0 -sdk "$TASK_NATIVE_SDK" -parse-as-library -typecheck "${TASK_NATIVE_SOURCES[@]}"
  echo 'PASS iOS16 arm64 native SRTP/RTP/HEVC typecheck'
else
  xcrun swiftc -O "${TASK_NATIVE_SOURCES[@]}" -o "$TASK_NATIVE_DIR/NativeMediaTests"
  "$TASK_NATIVE_DIR/NativeMediaTests"
fi
