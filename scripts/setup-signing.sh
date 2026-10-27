#!/bin/bash
set -euo pipefail

# 生成本地自签名代码签名证书并导入 login keychain（幂等，已存在则跳过）。
# 屏幕录制授权（TCC）按代码签名锚定：改用该证书签名后，跨重新构建保留授权。
# 用法：bash scripts/setup-signing.sh [证书CN]
CERT_CN="${1:-${MEOWSHOT_SIGNING_CN:-Meowshot Local Signing}}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
# 必须用 macOS 自带的 LibreSSL 导出 PKCS12：Homebrew OpenSSL 3.x 的产物会被 Security.framework 拒绝（MAC 校验失败）；
# 密码不能为空，空密码 PKCS12 同样无法导入。
OSSL=/usr/bin/openssl
[[ -x "$OSSL" ]] || OSSL=openssl

if security find-identity -v -p codesigning | grep -qF "\"$CERT_CN\""; then
  echo "keychain 已有 '$CERT_CN'，无需操作。"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -subj "/CN=$CERT_CN" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning"

PW="$(uuidgen)" # 临时密码，导入后即丢弃
"$OSSL" pkcs12 -export -out "$TMP/id.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:"$PW"

security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PW"

# 添加信任设置，使 find-identity -v 视其为有效身份（自签名证书默认标记 CSSMERR_TP_NOT_TRUSTED）
security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$TMP/cert.pem"

if ! security find-identity -v -p codesigning | grep -qF "\"$CERT_CN\""; then
  echo "证书导入失败，请检查 security import 输出。" >&2
  exit 1
fi

cat <<EOF
完成：'$CERT_CN'（有效期 10 年）已导入 login keychain。

后续：
  1. bash build.sh --run
  2. 在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」移除旧的 Meowshot 条目，
     用 + 添加当前 .build/Meowshot.app 并开启权限。
     此后用同一证书重新构建无需再授权。
EOF
