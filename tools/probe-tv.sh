#!/bin/bash
# 探测雷鸟电视的 ADB 环境，重点取 WebView 内核版本。
# 用法: bash tools/probe-tv.sh [电视IP]    默认 192.168.0.4
# 电视 IP 可通过 mDNS 自动发现（见脚本末尾注释）。

set -u
TV_IP="${1:-192.168.0.4}"
PORT=5555
ADB="$(command -v adb || true)"
if [ -z "$ADB" ]; then
  echo "✗ 找不到 adb，请先安装 android-platform-tools"
  exit 1
fi

"$ADB" connect "$TV_IP:$PORT" >/dev/null 2>&1

echo "=== 等待电视授权（最多 90 秒）==="
echo "若一直是 unauthorized，请在电视上点「允许 USB 调试」，并勾选「一律允许」。"
STATE=""
for i in $(seq 1 30); do
  LINE=$("$ADB" devices 2>/dev/null | grep "$TV_IP:$PORT" | head -1)
  STATE=$(echo "$LINE" | awk '{print $2}')
  if [ "$STATE" = "device" ]; then
    echo "✓ 已授权（第 ${i} 次检查）"
    break
  fi
  printf "."
  sleep 3
done
echo
if [ "$STATE" != "device" ]; then
  echo "✗ 仍未授权，当前状态：${STATE:-未发现设备}"
  "$ADB" devices -l
  exit 2
fi

sh() { "$ADB" shell "$@" 2>/dev/null | tr -d '\r'; }

echo
echo "=== 1/6 设备身份 ==="
for k in ro.product.model ro.product.manufacturer ro.product.name \
         ro.build.version.release ro.build.version.sdk ro.build.display.id \
         ro.product.cpu.abi ro.product.cpu.abilist ro.hardware; do
  printf "%-30s %s\n" "$k" "$(sh getprop "$k")"
done

echo
echo "=== 2/6 显示参数 ==="
sh wm size
sh wm density

echo
echo "=== 3/6 WebView 内核（最关键）==="
sh dumpsys webviewupdate | grep -iE "current webview|webview package|fallback" | head -8
echo "--- 已安装的 WebView 包 ---"
sh pm list packages | grep -i webview | head -8
echo "--- 各包版本 ---"
for p in com.android.webview com.google.android.webview com.android.chrome; do
  V=$(sh dumpsys package "$p" | grep -m1 versionName | tr -d ' ')
  [ -n "$V" ] && printf "%-32s %s\n" "$p" "$V"
done
echo "--- 内核 User-Agent（在 WebView 里等价于 Chromium 版本）---"
sh getprop webview.chromium.version 2>/dev/null | grep -v '^$' || echo "(该属性未暴露，以上述包版本为准)"

echo
echo "=== 4/6 内存 ==="
sh dumpsys meminfo | head -8

echo
echo "=== 5/6 安装校验开关（决定 adb install 是否被拦）==="
sh settings get global verifier_verify_adb_installs
sh settings get global package_verifier_enable

echo
echo "=== 6/6 桌面与已有第三方应用 ==="
sh cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER 2>/dev/null | tail -3
sh pm list packages -3 | head -15

echo
echo "完成。请把以上输出回传，以便确定 WebView 是否 >= 80。"

# 附：无需手工查 IP 的发现方法（本机实测有效）
#   dns-sd -B _adb._tcp local.                       → 找到实例名
#   dns-sd -L <实例名> _adb._tcp local.              → 得到 Android.local.:5555
#   dscacheutil -q host -a name Android.local       → 得到 IP
