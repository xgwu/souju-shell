# 搜剧 AI 电视版 · 阶段 1~3 工程

**当前状态**：`0.3.0` / build 3 —— 正式 WebView 壳 + 遥控器焦点引擎 + **TV 版式皮肤**，
已装进雷鸟鹤7 Pro 75R675C 实机验证。自签名证书 30 年有效，装一次永久可用，
没有 iOS 版那套 7 天续签。

首屏实机截图：`docs/tv-stage3-home.png`。完整方案与实测数据：
`docs/tv-feasibility.md`、`docs/tv-webview-capabilities.json`。

## 目录

```
tv/
├── AndroidManifest.xml                  minSdk 21 / targetSdk 30 / 双 LAUNCHER category
├── res/values/strings.xml               app_name = 搜剧TV
├── res/mipmap-mdpi/ic_launcher.png      192×192，由 tools/make-tv-icon.py 生成
├── assets/
│   ├── bridge.js                        documentStart 注入：RPC 桥 + 环境标记 + 3 个 polyfill
│   ├── focus.js                         焦点引擎：候选集 / 轴向最近邻 / refind / 宽元素特例 / 高亮
│   ├── focus.css                        焦点环样式（Chrome 83 基线）
│   ├── tv-skin.css                      TV 版式：1200px 全宽 / 6 列网格 / 深色令牌 / 今晚首选
│   └── tv-skin.js                       data-* 标记 / 首屏排序 / 今晚首选卡 / 锚点自检
│   ├── error.html                       两条线路全挂时的错误页
│   ├── probe.html                       阶段 0 能力探针（保留）
│   └── security-probe.html              桥令牌隔离验证页
├── src/com/wuxiaogang/soujutv/
│   ├── MainActivity.java                宿主、按键路由、全屏、failover 编排
│   ├── ShellConfig.java                 线路、可信 host、UA、常量
│   ├── NativeBridge.java                RPC 路由 + 令牌校验 + 能力上报
│   ├── TvWebViewClient.java             导航边界、注入挂钩、失败上报
│   ├── TvChromeClient.java              全屏回调、控制台、进度兜底
│   ├── TvFocusEngine.java               注入器 + 按键映射 + 皮肤注入 + VERIFY 自检
│   └── BridgeLog.java                   logcat + 落盘双写
└── build/                               构建产物（gitignore）
```

开发期工具（都在 `tools/`）：`tv-skin-preview.py` 通过 CDP 把本地皮肤注入
正在运行的 WebView 并截图，**改 CSS 不用重装**；`tv-cdp.py` 是通用的实机 JS 执行 /
几何量取工具（纯标准库 WebSocket 客户端，Chrome 83 只回整数 id）。

**仍然不用 Gradle**：7 个 Java 类、零第三方依赖，`aapt2 → javac → d8 → zipalign → apksigner`
两秒出 52KB APK，改一行立刻装机实测。等阶段 5 引入 media3 / ExoPlayer 再切 Gradle。

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

# 关闭 TV 皮肤做 A/B 对比（不重装、不清数据；去掉该参数即恢复）
adb shell am force-stop com.wuxiaogang.soujutv
adb shell am start -n $PKG --es tvskin off

# 改 CSS 不重装：把本地 tv-skin.css/js 注入正在运行的 WebView，出截图 + 几何报告
python3 tools/tv-skin-preview.py --out /tmp/tv-skin-preview.png
python3 tools/tv-skin-preview.py --off          # 恢复原始版式（仅当前页面）
python3 tools/tv-cdp.py --expr "document.title" --screenshot /tmp/tv.png
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
| `VERIFY` | 自检：CSS 注入、焦点环颜色、3 个 polyfill、`skinCss/skinMarker/skinState/gridColumns/overflowX` |
| `HEALTH_OK` `HEALTH_MISSING` | 皮肤锚点自检结果；缺失时弹一次 Toast 告警（6 秒宽限 + 连续两次一致签名，避免启动期假警） |
| `STATE` `DOM` | 焦点状态、DOM 摘要、`skinState`（含 `columns` / `missing` / `tonight` / 字号） |
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

### 阶段 3 追加验证（2026-11-07 13:23，鹤7 Pro 75R675C）

| 项 | 结果 |
|---|---|
| 构建 / 安装 | `0.3.0` / 52KB，v1+v2+v3 通过，`adb install -r` 518–684ms |
| **6 列网格** | `gridTemplateColumns` 6 × `190px`，卡片 `190×287`（`padding-bottom:150%` 做 2:3，避开 83 不支持的 `aspect-ratio`） |
| **无横向溢出** | `scrollWidth=1280`、`overflowX:false`；feed rail / 追剧日历全部从横滑改成网格或 wrap |
| **字号** | 输入 26px / 导航 26px / 热词 19px / 卡片标题 20px / 徽章 16px（原 11–16px） |
| **今晚首选** | 1200×148 宽幅卡，首屏可见、焦点可达，数据取自首张 feed 卡 |
| **锚点自检** | `HEALTH_OK checked=13 columns=6 missing=''`，启动期零假警报 |
| **VERIFY** | `skinCss:true / skinMarker:on / skinState.missing:[] / gridColumns:6` |
| **焦点连续性** | 连续 8 次 DOWN 全部 `moved`（首页→搜索→今晚首选→第 2~5 行海报），零 `initial` |
| 首屏截图 | `docs/tv-stage3-home.png`（App 自注入皮肤后滚回顶部） |

三个实机踩坑都写进代码注释了：站点用 `--movie-sidebar-width!important` 决定主内容
padding（必须在 `html` 上写 inline `!important` 覆盖）；`tonight()` 不幂等会被自己的
MutationObserver 触发成 220ms 死循环；1.2k 宽卡按中心点算侧向偏移会被焦点引擎跳过。

## 已知限制（阶段 4+ 解决）

1. **搜索框无法输入**：电视没有键盘，语音键被系统助手占用。阶段 4 接手机扫码输入。
2. **H5 播放器控件为触摸设计**：遥控器点不到进度条；阶段 5 上 ExoPlayer。
3. **TV 端暂无账号登录 / 扫码 / 分享入口**：阶段 3 隐藏了站点的用户信息侧栏
   （272px 抽屉放大后会换行重叠、且这些功能在电视上用不到），阶段 4 与手机输入页一并补。
4. `auth.getState` / `auth.restoreSession` 回 `NOT_IMPL` 是**刻意的**：站点靠 `capabilities.actions`
   里有没有 `auth.*` 判断原生登录态同步是否支持，不报即回退 web 登录态。
5. 远程配置下发尚未实现；阶段 3 提供 `--es tvskin off` A/B 开关与 CDP 热注入通道兜底，
   正式下发推迟到阶段 4 与手机输入服务合并。

## 下一步

阶段 4：手机扫码输入（局域网 HTTP 服务 + 二维码 + 输入回传，延迟目标 < 200ms），
顺带补回账号登录 / 扫码入口。然后阶段 5：ExoPlayer 播放条（左右快退快进 10s、OK 暂停、
返回退出、上下选集）。

阶段 3 的 Chrome 83 五个失效 CSS 特性（flex `gap` / `aspect-ratio` / `:has` /
`:focus-visible` / `inset`）已全部避开，后续改皮肤也要守住这条基线。
