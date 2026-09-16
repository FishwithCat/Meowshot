#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/.build/Meowshot.app"
mkdir -p "$APP/Contents/MacOS" .build/module-cache
IDENTITY="${CODE_SIGN_IDENTITY:--}"
if [[ ! -f "$APP/Contents/MacOS/Meowshot" || ! -f .build/signing-identity ||
      "$(cat .build/signing-identity)" != "$IDENTITY" ||
      Sources/Meowshot.swift -nt "$APP" || Info.plist -nt "$APP" || build.sh -nt "$APP" ]]; then
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -O -module-cache-path .build/module-cache Sources/Meowshot.swift -o "$APP/Contents/MacOS/Meowshot"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" "$APP"
printf '%s\n' "$IDENTITY" > .build/signing-identity
touch "$APP"
fi
echo "Built: $APP"
if [[ "${1:-}" == "--test" ]]; then
    "$APP/Contents/MacOS/Meowshot" --self-test
elif [[ "${1:-}" == "--run" ]]; then
    open "$APP"
fi
