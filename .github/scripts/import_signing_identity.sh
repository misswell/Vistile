#!/usr/bin/env bash
# CI 专用：把仓库 secrets 里的 Developer ID 证书装进一次性钥匙串，并真试签一个文件。
# 通过 GITHUB_ENV 交出 SIGNING_KEYCHAIN / SIGNING_IDENTITY，工作流结束时删除钥匙串。
set -euo pipefail

: "${DEVELOPER_ID_P12_BASE64:?缺少 APPLE_DEVELOPER_ID_P12_BASE64}"
: "${DEVELOPER_ID_P12_PASSWORD:?缺少 APPLE_DEVELOPER_ID_P12_PASSWORD}"

KEYCHAIN_PATH="${RUNNER_TEMP:-$(mktemp -d)}/vistile-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
P12_PATH="$(dirname "$KEYCHAIN_PATH")/developer-id.p12"

# 只导入这一个身份：登录钥匙串里如果还有别的证书，写死身份名会让换证书变成改工作流。
printf '%s' "${DEVELOPER_ID_P12_BASE64}" | base64 -D >"${P12_PATH}"
security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security set-keychain-settings -lut 21600 "${KEYCHAIN_PATH}"
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security list-keychains -d user -s "${KEYCHAIN_PATH}"
security default-keychain -d user -s "${KEYCHAIN_PATH}"
security import "${P12_PATH}" -k "${KEYCHAIN_PATH}" -P "${DEVELOPER_ID_P12_PASSWORD}" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
rm -f "${P12_PATH}"

IDENTITY="$(security find-identity -v -p codesigning "${KEYCHAIN_PATH}" \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
[ -n "${IDENTITY}" ] || {
  echo "钥匙串里没有 Developer ID Application 证书；导入结果：" >&2
  security find-identity -v -p codesigning "${KEYCHAIN_PATH}" >&2
  echo "Apple Development / Apple Distribution 不能用于公证，必须是 Developer ID Application。" >&2
  exit 1
}

cp /usr/bin/true "${RUNNER_TEMP:-/tmp}/signing-probe"
codesign --force --options runtime --timestamp --sign "${IDENTITY}" "${RUNNER_TEMP:-/tmp}/signing-probe"
codesign --verify --strict "${RUNNER_TEMP:-/tmp}/signing-probe"

echo "SIGNING_KEYCHAIN=${KEYCHAIN_PATH}" >>"${GITHUB_ENV}"
echo "SIGNING_IDENTITY=${IDENTITY}" >>"${GITHUB_ENV}"
echo "==> 可用签名身份：${IDENTITY}"
