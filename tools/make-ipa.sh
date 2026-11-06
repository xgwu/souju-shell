#!/bin/bash
# 把已编译的 .app 打成 ipa，供 AltStore / SideStore 用你自己的 Apple ID 重签安装。
#   bash tools/make-ipa.sh
# 产物：dist/SoujuShell.ipa
#
# 注意：本脚本只做「ad-hoc 签名 + 打包」，不做真正的开发者签名 ——
# 那需要你的 Apple ID 与证书，由 SideStore/AltStore 在设备上完成。

set -eu
cd "$(dirname "$0")/.." || exit 1

APP="build/Build/Products/Debug-iphoneos/SoujuShell.app"
OUT_DIR="dist"
IPA="$OUT_DIR/SoujuShell.ipa"

[ -d "$APP" ] || { echo "✗ 找不到 $APP，先跑 bash tools/build.sh"; exit 1; }

echo "=== 1/4 清理旧产物 ==="
rm -rf "$OUT_DIR/Payload" "$IPA"
mkdir -p "$OUT_DIR/Payload"

echo "=== 2/4 复制 .app ==="
cp -R "$APP" "$OUT_DIR/Payload/"
TARGET="$OUT_DIR/Payload/SoujuShell.app"

echo "=== 3/4 ad-hoc 签名 ==="
# 先清掉可能残留的签名，再整体重签。ipa 侧载工具会用它们自己的证书覆盖这一层。
codesign --force --sign - --timestamp=none "$TARGET" 2>&1 | sed 's/^/  /' || true
codesign -dv "$TARGET" 2>&1 | grep -E "Signature|Identifier" | sed 's/^/  /' || true

echo "=== 4/4 打包 ==="
( cd "$OUT_DIR" && zip -qry "SoujuShell.ipa" Payload )
rm -rf "$OUT_DIR/Payload"

SIZE=$(du -h "$IPA" | cut -f1)
echo ""
echo "✓ 产物：$IPA  ($SIZE)"
echo "--- 包内结构 ---"
unzip -l "$IPA" | grep -E "Payload/.*(Info.plist|SoujuShell|Assets.car)" | sed 's/^/  /'
echo ""
echo "安装方式："
echo "  Sideloadly（本机已装 /Applications/Sideloadly.app，支持 iOS 7–27+）"
echo "    open -a Sideloadly  →  拖入上面的 ipa  →  填 Apple ID  →  Start"
echo "    免费账号 7 天，勾上 Auto Refresh 由后台 daemon 自动续签"
echo ""
echo "  注意：Xcode ⌘R 这条路在本机不可用 —— macOS 12.7.6 + Xcode 14.2 的真机调试"
echo "        只支持到 iOS 16.2，插 iOS 17+ 设备会报 device not supported。"
echo ""
echo "  详阅 docs/install-iphone.md（含「为什么永久签名不存在」与故障排查）"
