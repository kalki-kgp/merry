#!/usr/bin/env bash
# Runs the test suite. Swift Testing ships with the Command Line Tools but is
# not on the default search paths without Xcode, so the paths are passed here.
set -euo pipefail
cd "$(dirname "$0")/.."
clt=/Library/Developer/CommandLineTools
flags=()
if [ ! -d /Applications/Xcode.app ] && [ -d "$clt/Library/Developer/Frameworks/Testing.framework" ]; then
  fw="$clt/Library/Developer/Frameworks"
  flags=(-Xswiftc -F -Xswiftc "$fw" -Xlinker -F -Xlinker "$fw" -Xlinker -rpath -Xlinker "$fw"
         -Xswiftc -plugin-path -Xswiftc "$clt/usr/lib/swift/host/plugins/testing")
fi
exec swift test "${flags[@]}" "$@"
