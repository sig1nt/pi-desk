#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Recent CLT releases ship Swift Testing but SwiftPM may omit its framework/rpaths.
# Keep this workaround out of the application target and do not change xcode-select.
developer="$(xcode-select -p)"
frameworks="$developer/Library/Developer/Frameworks"
if [[ "$developer" == */CommandLineTools && -d "$frameworks/Testing.framework" ]]; then
  exec swift test --disable-xctest \
    -Xswiftc "-F$frameworks" \
    -Xlinker -rpath -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$developer/Library/Developer/usr/lib" "$@"
fi
exec swift test --disable-xctest "$@"
