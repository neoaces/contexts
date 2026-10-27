#!/bin/sh
# Builds a release binary and wraps it in build/Contexts.app.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
app=build/Contexts.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Contexts" "$app/Contents/MacOS/Contexts"
cp Resources/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp -R Vendor/SwiftMath/Sources/SwiftMath/mathFonts.bundle "$app/Contents/Resources/"
codesign --force --sign - "$app"
echo "Built $app"
