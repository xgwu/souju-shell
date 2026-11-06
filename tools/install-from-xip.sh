#!/bin/bash
# 从已下载的 Xcode_14.2.xip 安装 Xcode 并完成全部配置。
# 用法：bash ~/WorkBuddy/2026-11-06-11-31-15/souju-shell/tools/install-from-xip.sh
#
# 前提：浏览器下载的 Xcode_14.2.xip 已在 ~/Downloads（或传入路径作为第一个参数）

set -u

TOTAL_STEPS=5
step() { printf "\n\033[1;36m[%d/%d]\033[0m %s\n" "$1" "$TOTAL_STEPS" "$2"; }
ok()   { printf "      \033[1;32m✓\033[0m %s\n" "$1"; }
warn() { printf "      \033[1;33m!\033[0m %s\n" "$1"; }
die()  { printf "\n\033[1;31m✗ %s\033[0m\n" "$1"; exit 1; }

# ------------------------------------------------------------ 定位 xip
step 1 "定位安装包"
XIP="${1:-}"
if [ -z "$XIP" ]; then
  # 优先精确名，其次任意 Xcode*.xip，最后任意 .xip
  XIP=$(ls -S ~/Downloads/Xcode_14.2*.xip 2>/dev/null | head -1)
  [ -z "$XIP" ] && XIP=$(ls -S ~/Downloads/Xcode*.xip 2>/dev/null | head -1)
  [ -z "$XIP" ] && XIP=$(ls -S ~/Downloads/*.xip 2>/dev/null | head -1)
fi
[ -n "$XIP" ] && [ -f "$XIP" ] || die "没找到 xip。请把下载好的 Xcode_14.2.xip 放到 ~/Downloads，或把路径作为参数传入。"

SIZE_BYTES=$(stat -f%z "$XIP")
SIZE_GB=$((SIZE_BYTES / 1073741824))
ok "$XIP"
ok "大小 $SIZE_GB GB"
if [ "$SIZE_BYTES" -lt 6000000000 ]; then
  die "文件只有 $SIZE_GB GB，Xcode 14.2 完整包应约 7.8GB —— 下载可能没完成。请等浏览器下完再跑。"
fi

# -------------------------------------------------------- 空间与完整性
step 2 "检查磁盘与包完整性"
FREE_GB=$(df -g "$(dirname "$XIP")" | awk 'NR==2 {print $4}')
ok "目标磁盘可用 ${FREE_GB}GB"
if [ "$FREE_GB" -lt 40 ]; then die "可用空间不足 40GB（解压后约 30GB），请先清理。"; fi

if xar -tf "$XIP" >/dev/null 2>&1; then
  ok "xar 结构可读"
else
  die "xip 文件损坏或下载不完整（xar 无法读取目录）。请重新下载。"
fi

# ---------------------------------------------------------------- 解压
step 3 "解压（约 30GB，需要几分钟到十几分钟）"
xattr -c "$XIP" 2>/dev/null
WORK_DIR="$(dirname "$XIP")"
BEFORE_APPS=$(ls -d /Applications/Xcode*.app 2>/dev/null | wc -l | tr -d ' ')
if ! xip --expand "$XIP"; then
  die "解压失败。若提示空间不足请清理磁盘；若提示 device full 或校验错误，请重新下载。"
fi
ok "解压完成"

# ------------------------------------------------------------ 移入 /Applications
step 4 "安装到 /Applications"
NEW_XCODE=""
for cand in ./Xcode.app "$WORK_DIR"/Xcode.app; do
  [ -d "$cand" ] && NEW_XCODE="$cand" && break
done
[ -n "$NEW_XCODE" ] || NEW_XCODE=$(ls -d ./Xcode*.app 2>/dev/null | head -1)
[ -n "$NEW_XCODE" ] || die "解压后没找到 Xcode.app，请检查 $(pwd) 和 $WORK_DIR"

BASE_NAME="Xcode.app"
if [ -e "/Applications/$BASE_NAME" ]; then
  BASE_NAME="Xcode-14.2.app"
  warn "/Applications/Xcode.app 已存在，本次安装为 /Applications/$BASE_NAME"
fi
sudo rm -rf "/Applications/$BASE_NAME"
sudo ditto "$NEW_XCODE" "/Applications/$BASE_NAME" || die "复制到 /Applications 失败"
XCODE_APP="/Applications/$BASE_NAME"
ok "已安装：$XCODE_APP"
rm -rf "$NEW_XCODE" 2>/dev/null

# ------------------------------------------------------- 工具链与组件
step 5 "切换工具链、接受协议、安装组件、验证"
sudo xcode-select --switch "$XCODE_APP/Contents/Developer" || die "xcode-select 失败"
ok "xcode-select -> $XCODE_APP"
sudo xcodebuild -license accept 2>/dev/null && ok "许可协议已接受" || warn "license accept 非零返回（通常可忽略）"
sudo xcodebuild -runFirstLaunch 2>&1 | tail -3

echo "      --- xcodebuild ---"
xcodebuild -version 2>&1 | sed 's/^/      /'
echo "      --- iOS SDK ---"
xcodebuild -showsdks 2>/dev/null | grep -i iphone | sed 's/^/      /'

printf "\n\033[1;32m═══ Xcode 就绪 ═══\033[0m\n"
printf "安装位置：%s\n" "$XCODE_APP"
printf "回到对话告诉我，我来编译工程。\n"
