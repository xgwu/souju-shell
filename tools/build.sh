#!/bin/bash
# 编译 SoujuShell 工程。
#   bash tools/build.sh            无签名编译（验证代码能否通过，产出未签名的 .app）
#   bash tools/build.sh --sign     带签名编译（需要先在 Xcode 里配好 Personal Team）
#   bash tools/build.sh --archive  打包 archive（用于导出 ipa）

set -u
cd "$(dirname "$0")/.." || exit 1

MODE="nosign"
for arg in "$@"; do
  case "$arg" in
    --sign)    MODE="sign" ;;
    --archive) MODE="archive" ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
  esac
done

XCODE_DEV="/Applications/Xcode.app/Contents/Developer"
if [ ! -d "$XCODE_DEV" ]; then
  echo "✗ 找不到 $XCODE_DEV"
  exit 1
fi
export DEVELOPER_DIR="$XCODE_DEV"

echo "=== Xcode ==="
xcodebuild -version 2>&1 | sed 's/^/  /'
echo "=== SDK ==="
xcodebuild -showsdks 2>/dev/null | grep -i "iphoneos" | sed 's/^/  /'
echo ""

COMMON=(
  -project SoujuShell.xcodeproj
  -scheme SoujuShell
  -sdk iphoneos
  -destination 'generic/platform=iOS'
  -derivedDataPath build
)

case "$MODE" in
  nosign)
    echo "=== 无签名编译 ==="
    xcodebuild "${COMMON[@]}" -configuration Debug \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
      build 2>&1 | tee /tmp/build.log | \
      grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED|Compiling|Linking" | tail -40
    ;;
  sign)
    echo "=== 带签名编译（Debug）==="
    xcodebuild "${COMMON[@]}" -configuration Debug -allowProvisioningUpdates \
      build 2>&1 | tee /tmp/build.log | \
      grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED" | tail -40
    ;;
  archive)
    echo "=== Archive（Release）==="
    xcodebuild "${COMMON[@]}" -configuration Release -allowProvisioningUpdates \
      -archivePath build/SoujuShell.xcarchive archive 2>&1 | tee /tmp/build.log | \
      grep -E "error:|warning:|ARCHIVE SUCCEEDED|ARCHIVE FAILED" | tail -40
    ;;
esac

STATUS=${PIPESTATUS[0]}
echo ""
if [ "$MODE" = "archive" ]; then
  APP="build/SoujuShell.xcarchive/Products/Applications/SoujuShell.app"
else
  APP="build/Build/Products/Debug-iphoneos/SoujuShell.app"
fi

if [ -d "$APP" ]; then
  echo "✓ 产物：$APP"
  echo "--- 结构 ---"
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist" 2>/dev/null | sed 's/^/  BundleID: /'
  /usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$APP/Info.plist" 2>/dev/null | sed 's/^/  MinOS:    /'
  echo "  大小: $(du -sh "$APP" | cut -f1)"
  echo "--- 签名 ---"
  codesign -dv "$APP" 2>&1 | head -4 | sed 's/^/  /'
else
  echo "✗ 未产出 .app，完整日志见 /tmp/build.log"
  echo "--- 最后的错误 ---"
  grep -E "error:" /tmp/build.log 2>/dev/null | head -20
  exit 1
fi
