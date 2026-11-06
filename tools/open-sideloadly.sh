#!/bin/bash
# 启动 Sideloadly，并把 Apple 域名钉到可用 IP 上。
#
#   bash tools/open-sideloadly.sh            # 推荐：走本机钉 IP 代理（默认）
#   bash tools/open-sideloadly.sh --direct   # 只用直连（DNS 运气好时可用）
#
# 为什么要这么绕：
#   gsa.apple.com 是 akadns 的 CNAME，会在一组 Apple IP 之间轮询，
#   其中有些地址已经下线（实测 17.32.194.2 的 443 是黑洞，SYN 无响应）。
#   Sideloadly 一旦解析到坏地址，界面就停在「Logging in ... 0%」不动 ——
#   因为它卡在 TCP 握手，还没到应用层，所以既不报错也不超时。
#
#   钉 IP 代理（tools/apple-pin-proxy.py）把 gsa.apple.com 固定到实测可用的地址，
#   Sideloadly 通过 HTTPS_PROXY 指过来，就完全不再依赖本机 DNS 的运气。
#
# 另外：macOS 的 `open -a` 会把当前 shell 的环境变量传给 App。
#   如果这个终端里带着别的代理（公司代理 / 沙箱代理），会覆盖掉我们的设置，
#   所以脚本会先清空，再按需设置。

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP=/Applications/Sideloadly.app
PORT=18990
MODE="${1:-}"

if [ ! -d "$APP" ]; then
  echo "✗ 没找到 $APP"
  echo "  下载：https://sideloadly.io/SideloadlySetup.dmg"
  exit 1
fi

# ---------- 1. 清掉继承来的代理，避免串味 ----------
CLEAN_ENV="env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy"

# ---------- 2. 关闭已在运行的实例 ----------
if pgrep -f "Sideloadly.app/Contents/MacOS/Sideloadly" >/dev/null 2>&1; then
  echo "· 关闭已在运行的 Sideloadly"
  osascript -e 'tell application "Sideloadly" to quit' >/dev/null 2>&1
  sleep 2
  pkill -f "Sideloadly.app/Contents/MacOS/Sideloadly" >/dev/null 2>&1
  sleep 1
fi

# ---------- 3. 直连模式 ----------
if [ "$MODE" = "--direct" ]; then
  echo "· 直连模式启动"
  $CLEAN_ENV /usr/bin/open -a "$APP"
  sleep 4
  echo "✓ 已启动。若登录卡 0%，说明这次解析到了坏 IP，改用：bash tools/open-sideloadly.sh"
  exit 0
fi

# ---------- 4. 钉 IP 代理模式 ----------
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "· 端口 $PORT 已有代理在跑，直接复用"
  PROXY_PID=""
else
  echo "· 启动钉 IP 代理（端口 $PORT）"
  python3 "$ROOT/tools/apple-pin-proxy.py" --port $PORT >/tmp/apple-pin-proxy.log 2>&1 &
  PROXY_PID=$!
  sleep 2
  if ! lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo "✗ 代理没起来，看日志：/tmp/apple-pin-proxy.log"
    exit 1
  fi
fi

echo "· 自检：经代理访问 Apple"
CODE=$(curl -x "http://127.0.0.1:$PORT" -sS -o /dev/null -w "%{http_code}" --max-time 12 https://gsa.apple.com/ 2>/dev/null)
if [ "$CODE" = "000" ]; then
  echo "✗ 经代理连不上 gsa.apple.com，看日志：/tmp/apple-pin-proxy.log"
  exit 1
fi
echo "  gsa.apple.com → HTTP $CODE"

echo "· 启动 Sideloadly（HTTPS_PROXY=http://127.0.0.1:$PORT）"
env -u HTTP_PROXY -u ALL_PROXY -u http_proxy -u all_proxy \
    HTTPS_PROXY="http://127.0.0.1:$PORT" https_proxy="http://127.0.0.1:$PORT" \
    /usr/bin/open -a "$APP"
sleep 4

if pgrep -f "Sideloadly.app/Contents/MacOS/Sideloadly" >/dev/null 2>&1; then
  echo "✓ Sideloadly 已启动"
else
  echo "✗ Sideloadly 没能启动"
  exit 1
fi

echo ""
echo "接下来在 Sideloadly 里："
echo "  1. 确认 iDevice 显示 Kennys iPhone"
echo "  2. Apple ID 填邮箱 → Start → 输密码"
echo "  3. 双重认证的 6 位码在 Mac 上输"
echo ""
echo "本窗口要一直开着（代理在里面）。装完关掉 Sideloadly 后按 Ctrl-C 结束。"
echo "代理日志：/tmp/apple-pin-proxy.log"

if [ -n "${PROXY_PID:-}" ]; then
  trap 'kill $PROXY_PID 2>/dev/null; echo; echo "代理已停止"; exit 0' INT TERM
  echo ""
  echo "--- 代理日志（实时）---"
  tail -f /tmp/apple-pin-proxy.log
fi
