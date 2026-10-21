#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TASK_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/resolvescopes-native-video.XXXXXX")"
trap 'rm -rf "$TASK_TEMP"' EXIT
TASK_INPUT="${1:-$TASK_TEMP/test.hevc}"
if [ "$#" -eq 0 ]; then
  ffmpeg -v error -f lavfi -i testsrc2=size=320x180:rate=24 -frames:v 8 -pix_fmt yuv422p10le -c:v libx265 -x265-params keyint=1:repeat-headers=1:aud=1:log-level=error -f hevc "$TASK_INPUT"
fi
cp "$TASK_ROOT/Tests/NativeVideoPipelineTests.swift" "$TASK_TEMP/main.swift"
xcrun swiftc "$TASK_ROOT/iPadCompanion/ResolveScopesPad/NativeRemote/NativeVideoPipeline.swift" "$TASK_TEMP/main.swift" -o "$TASK_TEMP/check"
"$TASK_TEMP/check" "$TASK_INPUT"
