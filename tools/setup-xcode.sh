#!/bin/bash
# 安装 Xcode 14.2（macOS 12 Monterey 可用的最后一版）并完成所有后续配置。
# 用法：在「终端」里执行  bash ~/WorkBuddy/2026-11-06-11-31-15/souju-shell/tools/setup-xcode.sh
#
# 过程中只需要：
#   1) 输入 Apple ID（若已 export SOUJU_APPLE_ID 可直接回车）
#   2) 输入 Apple ID 密码（不回显，正常现象）
#   3) 输入 6 位双重认证验证码
#   4) 输一次 Mac 登录密码（sudo，用于选中 Xcode / 接受协议）

set -u

TARGET_VERSION="14.2"
# Apple ID 不再写死在脚本里（仓库已公开）。需要免输时先 export SOUJU_APPLE_ID=...
APPLE_ID_DEFAULT="${SOUJU_APPLE_ID:-}"
TOTAL_STEPS=6

step() { printf "\n\033[1;36m[%d/%d]\033[0m %s\n" "$1" "$TOTAL_STEPS" "$2"; }
ok()   { printf "      \033[1;32m✓\033[0m %s\n" "$1"; }
warn() { printf "      \033[1;33m!\033[0m %s\n" "$1"; }
die()  { printf "\n\033[1;31m✗ %s\033[0m\n" "$1"; exit 1; }

# ---------------------------------------------------------------- 0. 环境自检
step 1 "环境自检"
if [ "$(uname -m)" != "x86_64" ]; then warn "非 Intel 架构，本脚本按 x86_64 准备"; fi
FREE_GB=$(df -g / | awk 'NR==2 {print $4}')
ok "macOS $(sw_vers -productVersion)  可用空间 ${FREE_GB}GB"
if [ "$FREE_GB" -lt 45 ]; then
  die "可用空间不足 45GB（xip 7.8GB + 解压后约 30GB）。请先清理磁盘。"
fi
command -v xcodes >/dev/null 2>&1 || die "xcodes 未找到，请先确认 /usr/local/bin/xcodes 存在"
XVER=$(xcodes version 2>/dev/null)
ok "xcodes $XVER"
# 低于 1.6 的版本只会打老的 /appleauth/auth/signin，该端点已被 Apple 停用并返回 503
case "$XVER" in
  1.[0-5].*|1.[0-5]) die "xcodes $XVER 过旧（Apple 已停用其登录端点）。需 1.6 及以上，请联系我重新部署。" ;;
esac

# ------------------------------------------------------- 1. 若已装则直接跳过
step 2 "检查是否已安装"
EXISTING=$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)
if [ -n "$EXISTING" ]; then
  ok "已存在：$EXISTING，跳过下载"
  XCODE_APP="$EXISTING"
else
  # ------------------------------------------------------ 2. 下载 + 解压
  step 3 "下载并安装 Xcode ${TARGET_VERSION}（约 7.8GB，取决于网速，请耐心等待）"
  if [ -n "$APPLE_ID_DEFAULT" ]; then
    printf "      Apple ID 直接回车即用默认值：%s\n" "$APPLE_ID_DEFAULT"
  else
    printf "      请输入 Apple ID（想免输可先 export SOUJU_APPLE_ID=你的账号）\n"
  fi
  # --experimental-unxip: 解压提速 2~3 倍；--empty-trash: 装完删除 7.8GB 的 xip
  if ! xcodes install "$TARGET_VERSION" --select --experimental-unxip --empty-trash; then
    die "xcodes install 失败。若提示认证错误，请把终端里的报错发我，我换备用方案。"
  fi
  XCODE_APP=$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)
  [ -n "$XCODE_APP" ] || die "安装结束但 /Applications 下找不到 Xcode.app"
  ok "已安装：$XCODE_APP"
fi

# ---------------------------------------------------------- 3. 切换工具链
step 4 "切换到该 Xcode 并接受许可协议"
sudo xcode-select --switch "$XCODE_APP/Contents/Developer" || die "xcode-select 失败"
ok "xcode-select -> $XCODE_APP"
sudo xcodebuild -license accept 2>/dev/null && ok "许可协议已接受" || warn "license accept 返回非零（通常可忽略）"

# --------------------------------------------------- 4. 首次启动组件安装
step 5 "安装内置组件与 iOS 平台（会再下载 1~2GB，可能耗时较久）"
sudo xcodebuild -runFirstLaunch 2>&1 | tail -5
ok "首次启动组件完成"

# ------------------------------------------------------------ 5. 验证 SDK
step 6 "验证 SDK 与工具链"
echo "      --- xcodebuild ---"
xcodebuild -version 2>&1 | sed 's/^/      /'
echo "      --- 可用 SDK ---"
xcodebuild -showsdks 2>/dev/null | grep -i iphone | sed 's/^/      /'
echo "      --- 签名身份 ---"
security find-identity -v -p codesigning 2>/dev/null | tail -3 | sed 's/^/      /'

printf "\n\033[1;32m═══ 环境就绪 ═══\033[0m\n"
printf "Xcode: %s\n" "$XCODE_APP"
printf "下一步：回到对话告诉我“装好了”，我来编译工程。\n"
