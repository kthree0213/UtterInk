#!/usr/bin/env bash
# 从 SwiftPM release 产物组装 FlowType.app，并生成可分发 DMG。
#
# 用法：
#   ./Scripts/package-dmg.sh
#   FLOWTYPE_VERSION=1.2.3 FLOWTYPE_BUILD=45 ./Scripts/package-dmg.sh
#
# 可选：签名（Developer ID Application / Apple Development）
#   export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   ./Scripts/package-dmg.sh
#
# 公证需 Apple 开发者账号：codesign 后 xcrun notarytool submit …，再 staple。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${FLOWTYPE_VERSION:-1.0.0}"
BUILD="${FLOWTYPE_BUILD:-1}"
BUNDLE_ID="${FLOWTYPE_BUNDLE_ID:-dev.flowtype.FlowType}"

case "$(uname -m)" in
  arm64) SWIFT_TRIPLE_SUBDIR="arm64-apple-macosx" ;;
  x86_64) SWIFT_TRIPLE_SUBDIR="x86_64-apple-macosx" ;;
  *)
    echo "error: 不支持的架构: $(uname -m)" >&2
    exit 1
    ;;
esac

REL="$ROOT/.build/$SWIFT_TRIPLE_SUBDIR/release"
PRODUCT="FlowType"
APP_NAME="${PRODUCT}.app"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME"
DMG_NAME="${PRODUCT}-${VERSION}.dmg"
DMG_PATH="$DIST/$DMG_NAME"
PATCH_SCRIPT="$ROOT/Scripts/patch-spm-bundle-accessors.sh"

echo "==> swift build -c release --product $PRODUCT (1/2，生成 resource 存根)"
swift build -c release --product "$PRODUCT"

echo "==> 修补 SPM 资源包路径（见 Scripts/patch-spm-bundle-accessors.sh）"
bash "$PATCH_SCRIPT" "$REL"

echo "==> swift build -c release --product $PRODUCT (2/2，使修补生效)"
swift build -c release --product "$PRODUCT"

if [[ ! -x "$REL/$PRODUCT" ]]; then
  echo "error: 找不到 release 可执行文件: $REL/$PRODUCT" >&2
  exit 1
fi

# 部分依赖的 .bundle 是扁平目录（无 Contents/Info.plist），codesign 前整理为 BNDL。
normalize_flat_spm_bundle() {
  local b="$1"
  local bid="$2"
  if [[ -f "$b/Contents/Info.plist" ]]; then
    return 0
  fi
  if [[ -f "$b/Info.plist" ]]; then
    return 0
  fi
  local tmp="${b}.norm.$$"
  mkdir -p "$tmp/Contents/Resources"
  shopt -s dotglob nullglob
  for item in "$b"/*; do
    [[ -e "$item" ]] || continue
    mv "$item" "$tmp/Contents/Resources/"
  done
  shopt -u dotglob nullglob
  cat > "$tmp/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleIdentifier</key>
	<string>${bid}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>CFBundleVersion</key>
	<string>1</string>
</dict>
</plist>
EOF
  rm -rf "$b"
  mv "$tmp" "$b"
}

echo "==> 组装 $APP_NAME"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$REL/$PRODUCT" "$APP/Contents/MacOS/"
chmod +x "$APP/Contents/MacOS/$PRODUCT"

shopt -s nullglob
for bundle in "$REL"/*.bundle; do
  name="$(basename "$bundle")"
  echo "    + $name"
  cp -R "$bundle" "$APP/Contents/MacOS/"
  dst="$APP/Contents/MacOS/$name"
  case "$name" in
    FlowType_FlowType.bundle)
      normalize_flat_spm_bundle "$dst" "${BUNDLE_ID}.flowtype-resources"
      ;;
    swift-transformers_Hub.bundle)
      normalize_flat_spm_bundle "$dst" "${BUNDLE_ID}.hub-resources"
      ;;
    swift-crypto_Crypto.bundle)
      normalize_flat_spm_bundle "$dst" "${BUNDLE_ID}.crypto-privacy"
      ;;
  esac
done
shopt -u nullglob

cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"

if [[ -d "$ROOT/Packaging/zh-Hans.lproj" ]]; then
  cp -R "$ROOT/Packaging/zh-Hans.lproj" "$APP/Contents/Resources/"
fi

# Finder / Dock 用 .icns；无则尝试从 iconset 生成（先跑 scripts/export_app_icon.py）
ICON_ICNS="$ROOT/dist/FlowTypeApp.icns"
ICON_ICONSET="$ROOT/dist/FlowTypeApp.iconset"
if [[ -f "$ICON_ICNS" ]]; then
  echo "    + FlowTypeApp.icns (from dist)"
  cp "$ICON_ICNS" "$APP/Contents/Resources/"
elif [[ -d "$ICON_ICONSET" ]] && command -v iconutil >/dev/null 2>&1; then
  echo "    + FlowTypeApp.icns (iconutil from dist/FlowTypeApp.iconset)"
  iconutil -c icns "$ICON_ICONSET" -o "$APP/Contents/Resources/FlowTypeApp.icns"
else
  echo "    ! 未找到 dist/FlowTypeApp.icns 或 iconset；Finder 可能显示白块图标。请执行: python3 scripts/export_app_icon.py"
fi

IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "==> codesign (identity: $IDENTITY)"
else
  echo "==> codesign (ad-hoc, 仅本机/测试；对外分发请设置 CODESIGN_IDENTITY)"
fi
shopt -s nullglob
for bundle in "$APP/Contents/MacOS"/*.bundle; do
  echo "    sign $(basename "$bundle")"
  codesign --force --sign "$IDENTITY" --options runtime "$bundle"
done
shopt -u nullglob
ENTITLEMENTS="$ROOT/Packaging/FlowType.entitlements"
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "error: 缺少 $ENTITLEMENTS（麦克风等 Hardened Runtime 能力）" >&2
  exit 1
fi
codesign --force --deep --sign "$IDENTITY" --options runtime --entitlements "$ENTITLEMENTS" "$APP"

echo "==> 生成 DMG: $DMG_PATH"
rm -f "$DMG_PATH"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/flowtype-dmg.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

cp -R "$APP" "$STAGE/"
ln -sf /Applications "$STAGE/Applications"

hdiutil create -volname "$PRODUCT" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG_PATH" >/dev/null

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "==> 对 DMG 签名（可选）"
  codesign --force --sign "$CODESIGN_IDENTITY" "$DMG_PATH" 2>/dev/null || true
fi

echo "完成: $DMG_PATH"
echo ""
echo "对外分发前建议："
echo "  1. 将 Packaging/Info.plist 中 CFBundleIdentifier / 版权改为你的正式标识。"
echo "  2. 使用 Developer ID Application 证书签名 app，notarytool 公证后再 staple。"
echo "  3. 本脚本会修改 .build/.../release 下生成的 resource_bundle_accessor.swift；"
echo "     平常开发用 swift build 不受影响；若遇资源包加载问题可 swift package clean 后重编。"
