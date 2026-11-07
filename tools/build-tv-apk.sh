#!/usr/bin/env bash
# 用 Android SDK 命令行工具直接打最小 WebView 壳 APK，不依赖 Gradle / Maven。
#
# 存在的理由：阶段 0 只需要验证「自签名 APK 能不能装进电视并跑起 WebView」。
# 上 Gradle 要拉 AGP 与一堆依赖，把「装不装得上」这个判断拖到十几分钟后才揭晓，
# 不值得。等安装链路验证通过，再在同一份 manifest / 源码上加 Gradle 工程。
#
# 依赖（由 docs/tv-feasibility.md §8 记录的安装步骤准备）：
#   ~/Library/Android/jdk17/home                 Temurin JDK 17
#   ~/Library/Android/sdk/platforms/android-34 android.jar
#   ~/Library/Android/sdk/build-tools/34.0.0   aapt2 / d8 / zipalign / apksigner
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TV="$ROOT/tv"
OUT="$TV/build"

: "${JAVA_HOME:=$HOME/Library/Android/jdk17/home}"
: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
export JAVA_HOME ANDROID_HOME

BT="$ANDROID_HOME/build-tools/34.0.0"
JAR="$ANDROID_HOME/platforms/android-34/android.jar"
KS_DIR="$HOME/.souju-tv"
KS="$KS_DIR/tv.jks"
KS_PASS="soujutv-debug"

for f in "$BT/aapt2" "$BT/d8" "$BT/zipalign" "$BT/apksigner" \
         "$JAR" "$JAVA_HOME/bin/javac" "$JAVA_HOME/bin/keytool"; do
  if [ ! -e "$f" ]; then
    echo "✗ 缺少：$f" >&2
    exit 1
  fi
done

echo "=== 生成启动图标（纯标准库，无额外依赖）==="
python3 "$ROOT/tools/make-tv-icon.py"

echo "=== 清理构建目录 ==="
rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex" "$OUT/gen"

echo "=== 1/6 aapt2 compile（res → 扁平归档）==="
"$BT/aapt2" compile --dir "$TV/res" -o "$OUT/res.zip"

echo "=== 2/6 aapt2 link（二进制 manifest + 资源 + assets）==="
"$BT/aapt2" link \
  -o "$OUT/base.apk" \
  -I "$JAR" \
  --manifest "$TV/AndroidManifest.xml" \
  -R "$OUT/res.zip" \
  -A "$TV/assets" \
  --min-sdk-version 21 \
  --target-sdk-version 30 \
  --auto-add-overlay \
  --java "$OUT/gen"

echo "=== 3/6 javac ==="
GEN_SOURCES="$(find "$OUT/gen" -name '*.java' 2>/dev/null || true)"
# shellcheck disable=SC2086
"$JAVA_HOME/bin/javac" -source 8 -target 8 -encoding UTF-8 -Xlint:-options \
  -classpath "$JAR" \
  -d "$OUT/classes" \
  "$TV/src/com/wuxiaogang/soujutv/MainActivity.java" $GEN_SOURCES

echo "=== 4/6 d8 → classes.dex ==="
# shellcheck disable=SC2046
"$BT/d8" --lib "$JAR" --min-api 21 --output "$OUT/dex" \
  $(find "$OUT/classes" -name '*.class')

echo "=== 5/6 合并 dex + zipalign ==="
cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT/dex" && zip -q "$OUT/unsigned.apk" classes.dex)
"$BT/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

echo "=== 6/6 自签名 ==="
# keystore 放在用户目录而不是 build/：覆盖安装要求签名不变，清理构建目录不能把它删掉。
if [ ! -f "$KS" ]; then
  mkdir -p "$KS_DIR"
  "$JAVA_HOME/bin/keytool" -genkeypair -noprompt \
    -keystore "$KS" -alias soujutv -keyalg RSA -keysize 2048 \
    -validity 10950 -storetype PKCS12 \
    -storepass "$KS_PASS" -keypass "$KS_PASS" \
    -dname "CN=SoujuTV Debug, OU=Dev, O=Personal, L=Shanghai, ST=Shanghai, C=CN"
  echo "  已生成自签名证书（30 年）：$KS"
fi

"$BT/apksigner" sign \
  --ks "$KS" --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
  --out "$OUT/souju-tv-debug.apk" "$OUT/aligned.apk"

echo
"$BT/apksigner" verify --verbose "$OUT/souju-tv-debug.apk" | head -8
echo
echo "✓ APK  $OUT/souju-tv-debug.apk  ($(du -h "$OUT/souju-tv-debug.apk" | cut -f1))"
echo "  安装 adb install -r $OUT/souju-tv-debug.apk"
echo "  取证 adb logcat -d -s SoujuTV"
