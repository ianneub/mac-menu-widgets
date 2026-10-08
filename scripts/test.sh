#!/bin/bash
# swift test with the Command Line Tools: Swift Testing's macro plugin is
# shipped but not on the default plugin path without Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib "$@"
