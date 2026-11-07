# 搜剧 AI 电视版 · 阶段 1+2 工程

**当前状态**：正式 WebView 壳 + 遥控器焦点引擎，已装进雷鸟鹤7 Pro 75R675C 实机验证。
自签名证书 30 年有效，装一次永久可用，没有 iOS 版那套 7 天续签。

完整方案与实测数据：`docs/tv-feasibility.md`、`docs/tv-webview-capabilities.json`。

## 目录

```
tv/
├── AndroidManifest.xml                  minSdk 21 / targetSdk 30 / 双 LAUNCHER category
├── res/values/strings.xml               app_name = 搜剧TV
├── res/mipmap-mdpi/ic_launcher.png      192×192，由 tools/make-tv-icon.py 生成
├── assets/
│   ├── bridge.js                        documentStart 注入：RPC 桥 + 环境标记 + 3 个 polyfill
│   ├── focus.js                         焦点引擎：候选集 / 轴向最近邻 / 滚动 / 高亮
│   ├── focus.css                        焦点环样式（Chrome 83 基线）
│   ├── error.html                       两条线路全挂时的错误页
│   ├── probe.html                       阶段 0 能力探针（保留）
│   └── security-probe.html              桥令牌隔离验证页
├── src/com/wuxiaogang/soujutv/
│   ├── MainActivity.java                宿主、按键路由、全屏、failover 编排
│   ├── ShellConfig.java                 线路、可信 host、UA、常量
│   ├── NativeBridge.java                RPC 路由 + 令牌校验 + 能力上报
│   ├── TvWebViewClient.java             导航边界、注入挂钩、失败上报
│   ├── TvChromeClient.java              全屏回调、控制台、进度兜底
│   ├── TvFocusEngine.java               注入器 + 按键映射 + 自检
│   └── BridgeLog.java                   logcat + 落盘双写
└── build/                               构建产物（gitignore）
```

**仍然不用 Gradle**：7 个 Java 类、零第三方依赖，`aapt2 → javac → d8 → zipalign → apksigner`
两秒出 44KB APK，改一行立刻装机实测。等阶段 5 引入 media3 / ExoPlayer 再切 Gradle。

## 构建与安装

前置（已装好，见 `docs/tv-feasibility.md` §8）：

| 组件 | 路径 |
|---|---|
| Temurin JDK 17.0.21+9 | `~/Library/Android/jdk17/home` |
| Android SDK | `~/Library/Android/sdk`（cmdline-tools 12.0 / platform-34 / build-tools 34.0.0） |
| 自签名证书 | `~/.souju-tv/tv.jks`（30 年，v1/v2/v3） |
| adb | `/usr/local/bin/adb` → SDK platform-tools |

```bash
bash tools/build-tv-apk.sh                 # 生成图标 → 编译 → dex → 对齐 → 签名
adb install -r tv/build/souju-tv-debug.apk # 覆盖安装，签名不变、数据不丢
```

证书放用户目录而不是 `build/`：清理构建目录不能把它一起删掉，否则覆盖安装会因签名不一致失败。

## 遥控器按键

| 键 | 行为 |
|---|---|
| 上 / 下 / 左 / 右 | 焦点引擎按轴向最近邻移动，橙色焦点环跟随 |
| OK / Enter | `click()` 当前焦点；输入框上按下暂不操作（等阶段 4 手机扫码输入） |
| 返回 | 优先回退到站内历史；没有站内历史时，2 秒内连按两次退出 |
| 菜单 | 切到下一条线路并重载（也是人工 failover 入口） |

全屏视频（`onShowCustomView`）期间**按键完整交回系统**，不注入焦点引擎，避免和播放条抢事件。

## 调试参数

```bash
PKG=com.wuxiaogang.soujutv/.MainActivity

# 指定起始 URL（支持 file:///android_asset/ 本地页）
adb shell am start -n $PKG --es url "https://souju.ai"

# 临时换线路（逗号分隔，第一条失败自动 failover 到下一条）
adb shell am start -n $PKG --es domains "https://souju.ai,https://hctd4.com"

# 新增可信 host（站点换了中转域时用，不必重编译）
adb shell am start -n $PKG --es trusted "new-domain.com,another.com"

# 桥令牌隔离验证：应看到 3 条 REJECT、无 capabilities 回包
adb shell am start -n $PKG --es url "file:///android_asset/security-probe.html"
```

## 取证

App 把所有结论打进 logcat（TAG `SoujuTV`），同时落盘到
`/storage/emulated/0/Android/data/com.wuxiaogang.soujutv/files/bridge.log`。
不依赖截屏 —— 电视启用 `FLAG_SECURE` 时截图全黑。

```bash
adb logcat -c
adb shell input keyevent 224              # 唤醒，电视进 Dreaming 时截屏全黑
adb shell am start -n com.wuxiaogang.soujutv/.MainActivity
sleep 18
adb logcat -d -s SoujuTV
adb pull /storage/emulated/0/Android/data/com.wuxiaogang.soujutv/files/bridge.log
```

| 前缀 | 含义 |
|---|---|
| `BOOT` | SDK / ABI / 机型 / **当前进程实际 WebView 版本** / 日志路径 |
| `LINES` `LOAD_LINE` `FAILOVER_TRIGGER` | 线路选择与切换 |
| `TOKEN_ROTATED` `UNTRUSTED` `REJECT` | 桥令牌生命周期与拒绝记录 |
| `INJECT` | 三层脚本注入（start / progress15 / finish） |
| `← / →` | 桥的上行调用与下行回包 |
| `VERIFY` | 自检：CSS 是否注入、焦点环颜色、3 个 polyfill 是否生效 |
| `STATE` `DOM` | 焦点状态、DOM 摘要（证明页面真的渲染了） |
| `UP/DOWN/LEFT/RIGHT/OK` | 每次按键的 from→to 坐标、候选数、焦点环计算样式 |
| `BACK` `SHOW_CUSTOM_VIEW` | 返回键与全屏回调 |

## 安全边界

`@JavascriptInterface`（`window.SoujuTvNative`）对 WebView 里**所有 frame** 暴露，
实测在 `file://` 页面上也是 `typeof nativeObject === "object"`。两道校验必须同时成立：

1. `TvWebViewClient` 拦掉非 http(s) 导航和子 frame 的越界跳转；
2. **只有可信 host 的主 frame 才下发会话令牌**，`NativeBridge.post(json, token)` 校验通过才执行路由。

「导航白名单」与「桥白名单」刻意分开：站点是域名轮换架构，顶层导航必须宽松，
否则中转域一换就打不开；真正的权限边界是令牌。不可信页面能拿到 Java 对象，但拿不到令牌，
也拿不到 `window.H5ShellNativeBridge`（只在可信文档注入）。

实测（`security-probe.html`）：伪造令牌 / 空令牌 / 猜测令牌三次调用**全部 REJECT**，
且无 `app.getCapabilities` 回包。

## 实机验证（2026-11-07，鹤7 Pro 75R675C / 192.168.0.4:5555）

| 项 | 结果 |
|---|---|
| 安装 | `Success` 319–469ms；v1/v2/v3 签名全通过 |
| WebView / 视口 | `com.android.webview / 83.0.4103.120`，`1280×720 @ dpr 1.5` |
| **桥** | 站点主动调用 `app.getSystemInsets` / `app.getCapabilities`，`bridge:true`，无一次令牌误拒 |
| **能力上报** | `platform:"android"`、`supportsNativePlayer:false` → 站点回落 H5 播放器 |
| **自检** | `cssInjected:true`、焦点环 `rgb(255,138,61)`、3 个 polyfill 全部生效 |
| **焦点遍历** | 连续右键 y = 16→16→19，向下 x 偏移 26–27px，**无斜跳**；83 个候选 |
| **焦点环** | inline `!important` 覆盖站点高特异性 `:focus` 规则，实测截图清晰可见 |
| **failover** | 首条 `ERR_UNSAFE_PORT` → `FAILOVER_TRIGGER` → 600ms 后切第二条线路成功 |
| **令牌隔离** | 不可信页面 3 次调用全 REJECT，桥对象为 `undefined` |
| 返回 / 菜单 | BACK 跳过失败页历史、单次不退出；MENU 切线路生效 |
| JS 错误 / 崩溃 | 无 |

## 已知限制（阶段 3+ 解决）

1. **版式仍是桌面窄栏**：截图实测左侧栏 200px、海报和文字对 2.5m 观看距离过小。TV 皮肤是可用性前提，不是美化。
2. **搜索框无法输入**：电视没有键盘，语音键被系统助手占用。阶段 4 接手机扫码输入。
3. **H5 播放器控件为触摸设计**：遥控器点不到进度条；阶段 5 上 ExoPlayer。
4. **站点改版无预警**：`shell.reportHealth` 协议位已留好，皮肤锚点自检待阶段 3 接入。
5. `auth.getState` / `auth.restoreSession` 回 `NOT_IMPL` 是**刻意的**：站点靠 `capabilities.actions`
   里有没有 `auth.*` 判断原生登录态同步是否支持，不报即回退 web 登录态。

## 下一步

阶段 3：TV 版式皮肤（1280×720 坐标系、左侧竖导航、6 列网格、24 CSS px 字号下限）
+ 兼容层接入 + 皮肤锚点自检。注意 Chrome 83 五个失效 CSS 特性（flex gap / aspect-ratio /
`:has` / `:focus-visible` / `inset`）必须避开。
