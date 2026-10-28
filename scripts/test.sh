#!/bin/sh
# Runs the tests. With only the Command Line Tools (no Xcode), Swift Testing
# lives outside the default search paths, so point the compiler and loader at it.
set -eu
cd "$(dirname "$0")/.."

dev="$(xcode-select -p)/Library/Developer"
if [ -d "$dev/Frameworks/Testing.framework" ]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$dev/Frameworks" \
        -Xlinker -rpath -Xlinker "$dev/Frameworks" \
        -Xlinker -rpath -Xlinker "$dev/usr/lib" \
        "$@"
fi
exec swift test "$@"
