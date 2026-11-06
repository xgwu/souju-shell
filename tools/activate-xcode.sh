#!/bin/bash
# 激活已解压的 Xcode 14.2。需要 sudo（接受许可协议 + 安装组件是 root 操作）。
#   bash tools/activate-xcode.sh
# 只需成功跑一次，之后 tools/build.sh 就能正常编译。

set -u

XCODE_APP="/Applications/Xcode.app"
XCODE_DEV="$XCODE_APP/Contents/Developer"

step() { printf "\n\033[1m[%s]\033[0m %s\n" "$1" "$2"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
die()  { printf "  \033[31m✗\033[0m %s\n" "$1"; exit 1; }

step 1/5 "检查 Xcode.app"
[ -d "$XCODE_DEV" ] || die "找不到 $XCODE_DEV，Xcode 未正确解压"
ok "Xcode.app 就位"

# 归档解压可能残留隔离属性，清掉避免被 Gatekeeper 拦
xattr -cr "$XCODE_APP" 2>/dev/null
ok "已清理隔离属性"

step 2/5 "接受许可协议（需要输入你的 Mac 登录密码）"
sudo "$XCODE_DEV/usr/bin/xcodebuild" -license accept || die "接受许可失败"
ok "许可已接受"

step 3/5 "切换全局工具链到 Xcode 14.2"
sudo xcode-select --switch "$XCODE_DEV" || die "xcode-select 切换失败"
ok "$(xcode-select -p)"

step 4/5 "安装首次启动组件（可能需要几分钟）"
sudo "$XCODE_DEV/usr/bin/xcodebuild" -runFirstLaunch || die "首次启动初始化失败"
ok "组件安装完成"

step 5/5 "验证"
printf "  version: "; "$XCODE_DEV/usr/bin/xcodebuild" -version 2>&1 | tr '\n' ' '; echo ""
printf "  iOS SDK:\n"
"$XCODE_DEV/usr/bin/xcodebuild" -showsdks 2>/dev/null | grep -i "iphoneos\|iphonesimulator" | sed 's/^/    /'

echo ""
echo "✓ 完成。现在可以直接编译："
echo "    bash $(cd "$(dirname "$0")" && pwd)/build.sh"
