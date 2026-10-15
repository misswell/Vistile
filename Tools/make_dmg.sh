#!/usr/bin/env bash
# 从已经装订好公证票据的 .app 造一个可拖到「应用程序」的镜像。
# 必须用在 stapler staple 之后：先造镜像、后装订 .app 的话，用户从镜像里拖出来的那份没有票据。
set -euo pipefail

app="${1:?用法: make_dmg.sh <Vistile.app> <输出目录> <版本>}"
out_dir="${2:?}"
version="${3:?}"

name="Vistile_${version}_macos_arm64.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

# ditto 而不是 cp -R：票据是随 bundle 的扩展属性走的，cp 会丢。
mkdir -p "$staging"
ditto "$app" "$staging/$(basename "$app")"
ln -s /Applications "$staging/Applications"

mkdir -p "$out_dir"
rm -f "$out_dir/$name"
hdiutil create -quiet -volname "Vistile ${version}" -srcfolder "$staging" -format UDZO "$out_dir/$name"
echo "$out_dir/$name"
