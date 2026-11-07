#!/usr/bin/env bash
# 用 Android SDK 命令行工具直接打 TV APK，不依赖 Gradle / Maven。
#
# 阶段 0 用它验证「装不装得上」；阶段 1+2 继续沿用 —— 电视端目前只有 7 个 Java 类，
# 没有第三方依赖，手工链路 2 秒出包、改一行就能装机实测，比等 AGP 同步快得多。
# 等 B 阶段引入 media3 / ExoPlayer 时再切 Gradle。
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

echo "=== 3/6 javac（tv/src 下全部 Java 源 + aapt2 生成的 R.java）==="
GEN_SOURCES="$(find "$OUT/gen" -name '*.java' 2>/dev/null || true)"
SOURCE_FILES="$(find "$TV/src" -name '*.java' | sort)"
echo "  $(echo "$SOURCE_FILES" | wc -l | tr -d ' ') 个源文件"
# shellcheck disable=SC2086
"$JAVA_HOME/bin/javac" -source 8 -target 8 -encoding UTF-8 -Xlint:-options \
  -classpath "$JAR" \
  -d "$OUT/classes" \
  $SOURCE_FILES $GEN_SOURCES

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
