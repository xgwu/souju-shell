#!/bin/bash
# 检查 iPhone 与这台 Mac 之间的 Wi-Fi 调试通道是否可用。
#
# 为什么需要它：
#   免费证书 7 天到期，靠 sideloadly-daemon 自动续签。但 daemon 要能"看见"设备 ——
#   只走 USB 的话，拔线就找不到了，到期那天必须插线重装一次。
#   Wi-Fi 通道建立后，只要手机和 Mac 在同一网络，daemon 就能自己续。
#
# 用法：
#   bash tools/check-wifi-sync.sh          # 插着线跑：确认 USB 与 Wi-Fi 两条路都在
#   bash tools/check-wifi-sync.sh --unplugged   # 拔线后跑：只剩 Wi-Fi 时能否看到设备

set -u

echo "=== 1/3 USB 通道 ==="
if system_profiler SPUSBDataType 2>/dev/null | grep -q "iPhone"; then
  echo "  ✓ 检测到 iPhone（USB 在线）"
else
  echo "  · 没有 iPhone 在 USB 上"
  echo "    —— 如果已经拔线，这是预期结果，看 2/3 和 3/3"
fi

echo ""
echo "=== 2/3 Bonjour 广播 _apple-mobdev2._tcp ==="
TMP=$(mktemp)
/usr/bin/dns-sd -B _apple-mobdev2._tcp local > "$TMP" 2>&1 &
DNSD_PID=$!
sleep 6
kill "$DNSD_PID" 2>/dev/null
wait "$DNSD_PID" 2>/dev/null

if grep -q "Add" "$TMP" 2>/dev/null; then
  echo "  ✓ 发现广播："
  grep "Add" "$TMP" | sed 's/^/    /'
else
  echo "  ✗ 没有广播 —— Wi-Fi 同步没开，或手机不在同一网络"
fi
rm -f "$TMP"

echo ""
echo "=== 3/3 Xcode 视角的设备列表 ==="
if [ -d /Applications/Xcode.app ]; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcrun xctrace list devices 2>/dev/null | grep -iE "iPhone|iPad|Network" | sed 's/^/  /'
else
  echo "  ✗ 没装 Xcode，跳过这一项"
fi

echo ""
echo "--- 判读 ---"
echo "  拔线后 3/3 仍能看到设备  → Wi-Fi 通道可用，7 天内会自动续签"
echo "  拔线后设备消失 / 无广播  → 目前只有 USB，到期必须插线重装"
echo ""
echo "  若不通，在 Finder 里勾上「通过 Wi-Fi 与此 iPhone 同步」："
echo "    Finder → 侧边栏点 iPhone → 通用 → 选项 → 勾选该项 → 应用"
