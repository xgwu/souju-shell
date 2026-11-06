#!/bin/bash
# 检查 iPhone 是否被这台 Mac 正确识别与信任。
#   bash tools/check-device.sh
# 用于排查「Sideloadly 里看不到设备」「设置里没有开发者模式」这类问题。

set -u
echo "=== 1/3 USB 总线 ==="
USB=$(system_profiler SPUSBDataType 2>/dev/null | grep -iE "iPhone|iPad" | head -4)
if [ -n "$USB" ]; then
  echo "$USB" | sed 's/^/  ✓ /'
else
  echo "  ✗ 没有找到 iPhone/iPad"
  echo "    · 换一根「能传数据」的线（很多原装线只有供电）"
  echo "    · 直接插 Mac 的 USB 口，不要经过 hub / 扩展坞"
  echo "    · 插好后手机上应弹「要信任此电脑吗」"
fi

echo ""
echo "=== 2/3 设备通信通道 ==="
if pgrep -x usbmuxd >/dev/null 2>&1; then
  echo "  ✓ usbmuxd 在运行"
else
  echo "  ✗ usbmuxd 未运行（重启 Mac 或 killall usbmuxd 后系统会自动重拉）"
fi

echo ""
echo "=== 3/3 Xcode 视角的设备列表 ==="
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DEVS=$(xcrun xctrace list devices 2>/dev/null | sed -n '/^== Devices ==/,/^== Simulators ==/p' | grep -vE "^==|^$|MacBook|iMac|Mac mini|Mac Pro|Mac Studio")
if [ -n "$DEVS" ]; then
  echo "$DEVS" | sed 's/^/  ✓ /'
else
  echo "  ✗ Xcode 没有看到任何 iOS 设备"
fi

echo ""
echo "--- 判读 ---"
echo "  USB 有、Xcode 没有  → 线或口的问题，或手机没点「信任」"
echo "  都看不到            → 线/口/驱动问题，先解决这个再谈开发者模式"
echo "  都看得到但没有开发者模式 → 在 iPhone 上「设置 → 隐私与安全性」滑到最底部；"
echo "                              仍没有则重启 iPhone 再看（选项在首次配对后、重启一次才出现）"
