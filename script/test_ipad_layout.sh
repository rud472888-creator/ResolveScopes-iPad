#!/bin/bash
set -euo pipefail
TASK_LAYOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TASK_LAYOUT_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/resolvescopes-layout.XXXXXX")"
trap 'rm -rf "$TASK_LAYOUT_TEMP"' EXIT
xcrun swiftc "$TASK_LAYOUT_ROOT/iPadCompanion/ResolveScopesPad/CompanionPanelLayout.swift" "$TASK_LAYOUT_ROOT/Tests/CompanionPanelLayoutChecks.swift" -o "$TASK_LAYOUT_TEMP/check"
"$TASK_LAYOUT_TEMP/check"
