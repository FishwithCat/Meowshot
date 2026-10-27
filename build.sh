#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/.build/Meowshot.app"
mkdir -p "$APP/Contents/MacOS" .build/module-cache
PREFERRED_IDENTITY="${MEOWSHOT_SIGNING_IDENTITY:-Meowshot Local Signing}"
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$CODE_SIGN_IDENTITY"
elif security find-identity -v -p codesigning | grep -qF "\"$PREFERRED_IDENTITY\""; then
    IDENTITY="$PREFERRED_IDENTITY"
else
    IDENTITY="-"
    echo "提示: keychain 无 '$PREFERRED_IDENTITY'，使用 ad-hoc 签名。运行 bash scripts/setup-signing.sh 生成本地签名证书后，重新构建可保留屏幕录制授权。" >&2
fi
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
