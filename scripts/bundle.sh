#!/bin/bash
# Builds Voxlocal.app from the Swift package and signs it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Voxlocal.app
IDENTITY="Voxlocal Dev"

swift build -c release --product Voxlocal
BIN="$(swift build -c release --show-bin-path)/Voxlocal"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Voxlocal"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# A stable identity keeps macOS permission grants across rebuilds (see scripts/make-signing-cert.sh).
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "note: \"$IDENTITY\" not found; signing ad-hoc. Permissions will need re-granting after each rebuild."
    codesign --force --sign - "$APP"
fi
echo "Built $APP"
