#!/bin/zsh
set -eu
root="${0:A:h:h}"
task_tmp=$(mktemp -d -t native-session-test)
trap 'rm -rf "$task_tmp"' EXIT
python3 - "$root" "$task_tmp" <<'PY'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:]);s=(root/'SessionVendor.js').read_text();hook=(root/'Tests/session-hook.js').read_text()
needle="  post({type:'ready'});"
assert s.count(needle)==1
(out/'SessionVendor.js').write_text(s.replace(needle,hook+'\n'+needle))
(out/'SessionBootstrap.js').write_text((root/'SessionBootstrap.js').read_text())
(out/'main.swift').write_text((root/'RemoteSession.swift').read_text()+'\n'+(root/'Tests/session-main.swift').read_text())
PY
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc "$task_tmp/main.swift" -o "$task_tmp/run"
"$task_tmp/run" "$task_tmp"
