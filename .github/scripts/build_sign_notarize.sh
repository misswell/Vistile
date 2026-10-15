#!/usr/bin/env bash
# 构建 → Developer ID 签名（hardened runtime + timestamp）→ 公证并装订 .app →
# 用带票据的 .app 出镜像 → 签名镜像 → 公证并装订镜像 → 挂载复核。
#
# 两种自检模式，各自的边界都写死在产物里，别当成发布：
#   SKIP_NOTARIZE=1  本机用现成证书跑完构建、签名、出镜像与全部断言，只跳过 notarytool。
#                    能证明「除了公证之外都通」，不能证明公证过。
#   SKIP_SIGNING=1   干净 runner 上没有 secrets 时用它：只构建 + 出未签名镜像，
#                    证明 runner 的工具链能编过这个项目（本机永远撞不到这类缺口）。
#                    产物没有签名也没有票据，release 任务不会因为它而发布。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

: "${RELEASE_TAG:?需要 RELEASE_TAG，例如 v0.1.1}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"
SKIP_SIGNING="${SKIP_SIGNING:-0}"
if [ "$SKIP_SIGNING" != 1 ]; then
  : "${SIGNING_IDENTITY:?需要 SIGNING_IDENTITY（先跑 import_signing_identity.sh），或 SKIP_SIGNING=1}"
fi

work="$(mktemp -d)"
mnt="$(mktemp -d)"
trap 'rm -rf "$work" "$mnt"' EXIT

# 公证两条路线任取其一，缺哪项报哪项，不静默跳过。
api_key_ready=1
for v in APPLE_API_KEY_BASE64 APPLE_API_KEY_ID APPLE_API_ISSUER; do
  [ -n "${!v:-}" ] || api_key_ready=0
done
apple_id_ready=1
for v in APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD; do
  [ -n "${!v:-}" ] || apple_id_ready=0
done
if [ "$api_key_ready" = 0 ] && [ "$apple_id_ready" = 0 ] \
   && [ "$SKIP_NOTARIZE" != 1 ] && [ "$SKIP_SIGNING" != 1 ]; then
  {
    echo "缺少公证凭据，二选一："
    echo "  APPLE_API_KEY_BASE64 + APPLE_API_KEY_ID + APPLE_API_ISSUER"
    echo "  APPLE_ID + APPLE_TEAM_ID + APPLE_APP_SPECIFIC_PASSWORD"
  } >&2
  exit 1
fi

log() { echo "==> $*"; }

log "构建 Release（构建阶段不签名，签名统一在这里做）"
# 显式锁 arm64：Release 配置的 ARCHS 是 x86_64+arm64，-destination 里的 arch 并不压制它。
# 发一个从没在 Intel 上打开过的通用包，和说明里「Intel 未提供、未验证」自相矛盾。
xcodebuild -project Vistile.xcodeproj -scheme Vistile -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build >/dev/null

app="build/Build/Products/Release/Vistile.app"
[ -d "$app" ] || { echo "找不到 $app" >&2; exit 1; }

# 只签 bundle 的前提是没有嵌套代码；哪天引入了 framework 或 XPC，这个断言会先拦住。
nested="$(find "$app/Contents" -maxdepth 2 \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.dylib' \) -print)"
[ -z "$nested" ] || { echo "出现嵌套代码，需要逐个签名：$nested" >&2; exit 1; }

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
if [ "$SKIP_SIGNING" = 1 ]; then
  # 自检用的标签（v9.9.9-dryrun 这类）故意允许对不上版本号：它只证明 runner 能编，不发布。
  log "未签名自检（SKIP_SIGNING=1）：跳过标签比对、签名与公证，产物不发"
else
  [ "v${version}" = "${RELEASE_TAG}" ] || {
    echo "标签 ${RELEASE_TAG} 对不上产物里的 ${version}" >&2; exit 1; }

  log "签名 $app"
  codesign --force --options runtime --timestamp \
    --entitlements Support/Vistile-release.entitlements --sign "$SIGNING_IDENTITY" "$app"
  codesign --verify --deep --strict --verbose=2 "$app"

  # 用变量接收再匹配：`cmd | grep -q` 在 pipefail 下会因为 grep 提前关闭管道拿到 SIGPIPE，
  # 把「检查通过」误判成失败。
  info="$(codesign -dv --verbose=4 "$app" 2>&1)"
  ent="$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert xml1 -o - -)"
  case "$info" in
    *'flags=0x10000'*) ;;
    *) echo "产物没有 hardened runtime：$info" >&2; exit 1 ;;
  esac
  case "$ent" in
    *'app-sandbox'* ) ;;
    *) echo "签名里丢了 entitlements" >&2; exit 1 ;;
  esac
  # get-task-allow 留在签名里就不会被公证接受，所以验签名的结果，而不是验 entitlements 文件。
  case "$ent" in
    *'get-task-allow'* ) echo "签名里仍带 com.apple.security.get-task-allow，公证会拒" >&2; exit 1 ;;
  esac
fi

notarize() {
  if [ "$api_key_ready" = 1 ]; then
    key_file="$(mktemp -d)/AuthKey.p8"; chmod 600 "$key_file"
    printf '%s' "$APPLE_API_KEY_BASE64" | base64 -D >"$key_file"
    xcrun notarytool submit "$1" --key "$key_file" \
      --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" --wait
    rm -f "$key_file"
  else
    xcrun notarytool submit "$1" --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
  fi
}

if [ "$SKIP_NOTARIZE" = 1 ] || [ "$SKIP_SIGNING" = 1 ]; then
  log "跳过公证与装订（自检模式）：产物没有公证票据"
else
  log "公证并装订 .app（镜像必须从带票据的 .app 造）"
  app_zip="$work/Vistile_${RELEASE_TAG}_notarization.zip"
  ditto -c -k --keepParent "$app" "$app_zip"
  notarize "$app_zip"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
fi

log "制作镜像"
mkdir -p release
dmg="$(bash Tools/make_dmg.sh "$app" release "$RELEASE_TAG" | tail -1)"
archs="$(lipo -archs "$app/Contents/MacOS/Vistile")"
[ "$archs" = "arm64" ] || { echo "产物架构是 ${archs}，说明只写了 arm64" >&2; exit 1; }
if [ "$SKIP_SIGNING" != 1 ]; then
  log "签名镜像"
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$dmg"
  codesign --verify --verbose=2 "$dmg"
else
  log "自检模式结束（未签名、未公证）：$dmg"
  exit 0
fi

if [ "$SKIP_NOTARIZE" = 1 ]; then
  log "自检模式结束（已签名、未公证）：$dmg"
  exit 0
fi

notarize "$dmg"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"

log "验收"
spctl -a -vvv -t exec "$app"
# 只看 dmg 自己的票据发现不了「先造镜像、后装订 .app」：那时用户拖出来的是没票据的副本。
hdiutil attach -readonly -nobrowse -mountpoint "$mnt" "$dmg" >/dev/null
xcrun stapler validate "$mnt/Vistile.app"
spctl -a -vvv -t exec "$mnt/Vistile.app"
case "$(codesign -dv --verbose=4 "$mnt/Vistile.app" 2>&1)" in
  *'flags=0x10000'*) ;;
  *) echo "镜像里的 app 没有 hardened runtime" >&2; exit 1 ;;
esac
archs="$(lipo -archs "$mnt/Vistile.app/Contents/MacOS/Vistile")"
[ "$archs" = "arm64" ] || { echo "产物架构是 ${archs}，说明只写了 arm64" >&2; exit 1; }
hdiutil detach "$mnt" >/dev/null
log "产物：$(ls -lh release/ | tail -n +2 | tr -s ' ')"
