#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
open -a Xcode "$PROJECT_ROOT/ResolveScopesPad.xcodeproj"
