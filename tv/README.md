# 搜剧 AI 电视版 · 阶段 0 验证工程

一句话：**这是用来证明「自签名 APK 能装进雷鸟电视并跑起 WebView」的最小工程**，不是最终产品。
正式版会在这份 manifest / 源码上继续长，不推倒重来。

完整方案与实测数据见 `docs/tv-feasibility.md`、`docs/tv-webview-capabilities.json`。

## 目录

```
tv/
├── AndroidManifest.xml                     minSdk 21 / targetSdk 30 / 双 LAUNCHER category
├── res/values/strings.xml                  app_name = 搜剧TV
├── res/mipmap-mdpi/ic_launcher.png         192×192，由 tools/make-tv-icon.py 生成
├── assets/probe.html                       内置 WebView 能力探针页
├── src/com/wuxiaogang/soujutv/
│   └── MainActivity.java                   全屏 WebView + logcat 取证 + 按键记录
└── build/                                  构建产物（gitignore）
```

**为什么暂时不用 Gradle**：阶段 0 只想尽快知道「装不装得上」。上 Gradle 要先拉 AGP 与一堆依赖，
把结论拖到十几分钟后才揭晓。手工链路 `aapt2 → javac → d8 → zipalign → apksigner` 每次 2 秒，
且不引入任何 Maven 依赖。等进入阶段 1 再加 Gradle 工程。

## 构建与安装

前置（已装好，见 `docs/tv-feasibility.md` §8）：

| 组件 | 路径 |
|---|---|
| Temurin JDK 17.0.21+9 | `~/Library/Android/jdk17/home` |
| Android SDK | `~/Library/Android/sdk`（cmdline-tools 12.0 / platform-34 / build-tools 34.0.0） |
| 自签名证书 | `~/.souju-tv/tv.jks`（30 年，v1/v2/v3） |
| adb | `/usr/local/bin/adb` → SDK platform-tools |

```bash
# 一条命令完成「生成图标 → 编译 → dex → 对齐 → 签名」
bash tools/build-tv-apk.sh

# 装进电视（签名不变，可反复覆盖安装，数据不丢）
adb install -r tv/build/souju-tv-debug.apk
```

证书放在用户目录而不是 `build/`：清理构建目录不能把它一起删掉，否则覆盖安装会因签名不一致失败。

## 取证命令

App 把所有结论打进 logcat（TAG `SoujuTV`），不依赖截屏 —— 电视启用 `FLAG_SECURE` 时截图是全黑的。

```bash
# 启动（默认加载内置探针页 file:///android_asset/probe.html）
adb shell am start -n com.wuxiaogang.soujutv/.MainActivity
adb logcat -d -s SoujuTV

# 换页不用重编译：传 url extra
adb shell am force-stop com.wuxiaogang.soujutv
adb shell am start -n com.wuxiaogang.soujutv/.MainActivity --es url "https://souju.ai"
```

日志行含义：

| 前缀 | 内容 |
|---|---|
| `BOOT` | SDK、ABI、机型、**当前进程实际使用的 WebView 包与版本** |
| `UA` | 覆盖后的 UserAgent（系统浏览器原本伪造 iPad Safari 5.0.2） |
| `PAGE_FINISHED` / `PAGE_ERROR` | 页面加载结果 |
| `JS` | `probe.html` 回报的 JS / CSS / video 能力 JSON |
| `DOM` | 延时 5 秒抓的 DOM 摘要（title、innerText、节点数、图片数）—— 用来证明真的渲染了 |
| `KEY` | 遥控器按键是否到达 `dispatchKeyEvent` |
| `CONSOLE` | 页面 console 输出，含 JS 错误与 CSP 警告 |

## 实机结果（2026-11-07，鹤7 Pro 75R675C）

| 项 | 结果 |
|---|---|
| `adb install -r` | `Success`，489ms；两个 verifier 开关为 `null` 未拦截 |
| 桌面 | 「我的应用」共 10 项，搜剧TV 排第一位，橙色图标正常 |
| WebView | `com.android.webview / 83.0.4103.120`，与系统浏览器一致 |
| CSS 视口 | `1280 × 720 @ dpr 1.5` |
| 能力 | flex gap / aspect-ratio / `:has` / `:focus-visible` / `inset` 均不支持；`Array.at` 等 12 个 API 缺失 |
| **站点裸跑** | **完整渲染：988 节点 / 1836 字符 / 37 图 / 61 链接 / 52 按钮，logcat 零 JS 错误** |
| 线路跳转 | `souju.ai` → `bpz2.com` 自动跳转正常走完 |
| 遥控器 | DPAD 上/下/左/右、OK、BACK 六个键全部到达；BACK 目前直接退出 Activity |

**最大的意外是好消息**：不加任何 polyfill，站点首页在 Chromium 83 上就跑起来了。
静态扫描里那 3 个「未保护运行时 API」不在首屏初始化路径上。因此兼容层从「启动前置」
降级为「防御性补丁」，并入阶段 3。

截图同时确认：站点现在是桌面窄版布局、两侧大片留白、字号对电视过小 —— TV 版式是必需项，不是美化。

## 下一步（阶段 1 + 2）

1. 域名白名单 + `shouldOverrideUrlLoading` 全域名拦截（当前 `tvlog` 接口对所有 frame 暴露，仅调试用）
2. 桥：16 个方法路由 + 一次性令牌；能力如实上报 `supportsNativePlayer = false`
3. 线路 failover、错误页、返回键 `goBack` 而非直接退出
4. 原生 `dispatchKeyEvent` 接管 DPAD → JS 自建焦点引擎（候选集 + 轴向最近邻 + 滚动合并）
5. 加 Gradle 工程，接入后续 ExoPlayer / 手机扫码输入
