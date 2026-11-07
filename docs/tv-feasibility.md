# 搜剧 AI 电视版（雷鸟鹤系列）可行性与技术方案

> 调研日期：2026-11-07 · 目标设备：**雷鸟 鹤7 Pro 75R675C**（MT9653 / Android 11）
> 固件：`V8-0012T11-LF1V706.003371` · **WebView：Chromium 83.0.4103.120（实测）**
> 实测数据：`docs/tv-webview-capabilities.json` · 复测工具：`tools/tv-webview-probe.py`
> 参考实现：同仓 iOS 版 `souju-shell`（6049 行 Swift） · 电视工程与命令：`tv/README.md`

---

## 0. 结论

**可行，且比 iOS 版省事得多。**

一句话概括取舍：**这条路有两个真难点 —— 遥控器焦点，和一个 2020 年的 WebView 内核。其余都是移植。**

三条路线里推荐 **A（WebView 壳）先跑通 → B（补原生播放器）**，不做全原生。理由在 §3。

必须先说清楚一个前提：**Android 侧没有 iOS 那套 7 天限制**。APK 用自签名证书，装一次永久有效，不会因为证书过期闪退。iOS 版为了续签折腾的那一整套（Sideloadly、daemon、Wi-Fi 同步）在电视上完全不存在。

### 0.1 两轮校准：截图 → ADB 实测

| 项 | 初版假设 | 截图校准 | **ADB 实测** | 对方案的影响 |
|---|---|---|---|---|
| 机型 | 鹤6 24款 | 鹤7 Pro 75R675C | `tcl_mt5879_cn` / `mt9952` / `MT9653-DMIC-4` | 平台同代，路线不变 |
| WebView | 未知，概率「中」 | 猜 ≥90（V706 较新） | **Chromium 83.0.4103.120** | 猜测被推翻，须加兼容层（§5.5） |
| ABI | arm64-v8a | — | **armeabi-v7a（32 位）** | APK 只能打 32 位，见 §4 |
| CSS 视口 | 1920×1080 | — | **1280×720 @ dpr 1.5** | 版式全部重算（§6） |
| 播放 | H5 可用 | 建议做 B 阶段 | WebView 内 HEVC 完全不支持 | B 阶段进一步坐实 |

**值得记下来的一次判断失误**：我看到固件是 `V706`（2026-01-22 构建），推断系统 WebView「大概率 ≥90」。实测是 **83**——厂商把 WebView 锁在系统分区，固件再新也不更新它。以后判断内核版本，只认 `dumpsys webviewupdate`，不从固件版本外推。

好消息是：站点 JS 产物里**没有任何解析级不兼容语法**（`??=` / `&&=` / `||=` 全为 0），缺的都是可补的运行时 API 和 CSS 特性。所以路线 A 依然成立，兼容工作从「启动前置」降为「防御性补丁」（§5.5）。

### 0.2 阶段 0 已验证通过（2026-11-07 11:10 实机）

自签名 APK 已经装进电视并启动，路线 A 的前置条件全部拿到硬证据：

| 验证项 | 结果 |
|---|---|
| `adb install -r` | ✅ `Success`，489ms；两个 verifier 开关为 `null` 也不拦截 |
| 桌面可见 | ✅ 「我的应用」列表共 10 项，**搜剧TV 排第一位**，橙色图标正常 |
| 第三方 App 的 WebView | ✅ `com.android.webview / 83.0.4103.120`，与系统浏览器一致 |
| CSS 视口 | ✅ `1280×720 @ dpr 1.5`，UA 覆盖生效 |
| **站点裸跑** | ✅ **React SPA 完整渲染：988 节点 / 1836 字符 / 37 张海报 / 61 链接，logcat 无一条 JS 错误** |
| 遥控器按键 | ✅ DPAD 上/下/左/右、OK、BACK 六个键全部到达 `dispatchKeyEvent` |

最意外的一条：**不加任何 polyfill，站点首页就跑起来了**。静态扫描里那 3 个「未保护运行时 API」不在首屏初始化路径上，`souju.ai → bpz2.com` 的线路自动跳转也正常走完。因此 §5.5 兼容层不再阻断启动，阶段 0.5 可以并入后续开发。

截图同时确认了一件必须做的事：站点现在是**桌面窄版布局**（内容居中、两侧大片留白），字号对 2.5m 观看距离过小 —— §6 的 TV 版式不是锦上添花，是可用性前提。

---

## 1. 目标设备事实（ADB 实测，非规格页推断）

| 项 | 值 | 对方案的影响 |
|---|---|---|
| 机型 | **鹤7 Pro 75R675C**（电视名 `FF 75R675C-7A0A`，序列号 `630349991`） | 2023 年 MiniLED 机型，平台与鹤6 24款同一代 |
| 芯片 | MT9653（`ro.board.platform=mt5879` / `ro.hardware=mt9952` / `persist.xfar.platform=MT9653-DMIC-4`） | 固件平台码 `0012T11` 属 0012 平台族 |
| 系统 | **Android 11 / API 30**，`RQ3A.210705.001` | 只能自签名侧载；无 GMS、无 Play 商店 |
| 固件 | `V8-0012T11-LF1V706.003371`，构建日期 `2026012200` | 系统很新，但 WebView 没跟着更新 |
| **ABI** | **`armeabi-v7a` + `armeabi`（32 位用户态）** | **APK 必须打 32 位**；不要引入 arm64-only 的 .so |
| **WebView** | **`com.android.webview` 83.0.4103.120**，且是唯一 provider | 落在 80–89 风险带，见 §5.3 / §5.5 |
| 内存 | 4GB（系统 334MB / 桌面 380MB 常驻） | 跑 SPA 够用；`hls.js` 仍吃内存，海报预载要限制 |
| 存储 | 64GB，**当前可用 43.8GB** | TV 端本地缓存 / 离线下载可行，可后置 |
| 显示 | `wm size 1920×1080`、`wm density 240`、支持 50/60/100/120Hz | 系统层跑在 1080p，面板再上采样到 4K |
| **CSS 视口** | **1280×720，`devicePixelRatio=1.5`** | 版式按 1280×720 设计，不是 1920×1080（§6） |
| HDR | `HdrCapabilities [1,2,3,4]` = DV / HDR10 / HLG / HDR10+ 全支持 | 播放走原生解码才有意义（§5.4） |
| 遥控器 | 蓝牙语音键 + 方向键、OK、返回 | 语音键走系统助手，**第三方 App 拿不到** |
| 侧载环境 | 已装 Kodi、电视助手、QQ 音乐等 13+ 个三方包 | 说明这台机器装第三方 APK 没有额外门槛 |

> 固件编号解读（TCL 命名规则）：`V8-<平台码>-LF1V<版本>.<内部构建号>`。
> `0012T11` 属 0012 平台族（Pentonic 700 / MT9653），`LF1` 是国内区语言包，`V706` 是稳定版 OTA 版本号。
> **但固件版本与 WebView 版本无关** —— 这条已由实测证伪，不要再据此推断。

> 另一个坑：系统内置浏览器 `com.tcl.browser` 用的是同一个 WebView 83，却把 UA 伪造成
> `Mozilla/5.0 (iPad; ... Version/5.0.2 Safari/6533.18.5#2.0#TCL/`。我们自己的 App 必须用
> `WebSettings.setUserAgentString` 覆盖成正常 UA，否则站点会按「上古 iPad」降级。

### 安装路径（已核实）

雷鸟/TCL 的开发者模式与未知来源安装都可用，两条路：

1. **ADB 无线**（推荐，可反复迭代）
   - 设置 → 系统 → 关于本机 → 连点「版本号」7 次
   - 若没出现，走工厂菜单：本机信息页 → 遥控器依次按 `上 下 左 右`
   - 开 ADB 后：`adb connect <电视IP>:5555` → `adb install -r -g app.apk`
2. **U 盘**：APK 放根目录（不能放子文件夹）→ 文件管理器点安装

已知坑：新系统会拦安装校验，报 `INSTALL_FAILED_VERIFICATION_FAILURE`，两条命令可解：

```
adb shell settings put global verifier_verify_adb_installs 0
adb shell settings put global package_verifier_enable 0
```

### Manifest 要点（不写就跑不起来或桌面看不到图标）

```xml
<uses-feature android:name="android.hardware.touchscreen" android:required="false" />
<uses-feature android:name="android.software.leanback" android:required="false" />
<!-- Activity 同时声明两种入口，AOSP TV 桌面与灵控桌面都能识别 -->
<intent-filter>
  <action android:name="android.intent.action.MAIN" />
  <category android:name="android.intent.category.LAUNCHER" />
  <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
</intent-filter>
```
外加 `android:banner`（320×180），否则部分桌面显示空白卡片。

---

## 2. 目标站点事实（实测）

```
$ curl -A "Chrome/120" https://souju.ai
HTTP 200   4021 bytes   0.79s
<title>搜剧AI - souju.ai - AI影视搜索与内容发现</title>
```

- 打包方式：**Vite + React + Radix UI**，产物 `main-*.js` / `react-vendor-*.js`
- 渲染方式：**纯 CSR**。首页 HTML 只有 4KB 骨架，内容全靠 JS 渲染（无 SSR）
- 播放：H5 播放器（iOS 版如实上报 `supportsNativePlayer: false` 后回落的那套）
- 桥方法：16 个（`app.*` / `browser.*` / `download.*` / `playback.*` / `cast.*` / `shell.*`）

**实测后的结论**：电视的 WebView 是 Chromium 83，`?.` / `??` 都支持，所以**不会白屏**。但我把站点 129 个 JS 文件（约 360 万字符）全扫了一遍，找到 3 个未保护的运行时 API 调用和一批 Chromium 83 不支持的 CSS 特性——这部分必须靠兼容层解决，见 §5.3 / §5.5。

---

## 3. 路线对比

| | 工作量 | 播放质量 | 维护成本 | 主要风险 | 结论 |
|---|---|---|---|---|---|
| **A. WebView 壳** | ~1200 行 | 中（H5 播放器） | 低 | WebView 内核版本 | ✅ 第一阶段 |
| **B. 混合（A + ExoPlayer）** | A + ~700 行 | 高（硬解 / 4K / HDR） | 中 | 抓流地址的稳定性 | ✅ 第二阶段 |
| C. 全原生（Leanback + API 逆向） | 3–6 周 | 高 | 高（站点改版即失效） | 接口无契约 | ✗ 不做 |
| D. 手机投屏 | 0 | 低 | 0 | iOS AirPlay 到电视不通 | ✗ 仅作对照 |

**为什么不选 C**：站点是 React SPA，接口没有公开契约，全部靠抓包。iOS 版的经验已经证明这套东西改一次版就要重新逆向（README 里"下载入参形状没拿到"就是活例子）。投入产出比不成立。

**为什么 B 要拆成第二阶段**：A 阶段能验证的东西（能不能装、能不能显示、遥控器能不能走）不需要播放器。播放不满意再上 B，触发条件明确写下来：**1080p 播放掉帧、或 H5 播放条无法用遥控器操作、或需要 4K / HEVC / HDR**，出现任一条就进 B。

> 这台电视是 360 分区 MiniLED + DV IQ / HDR10+ 面板，而 WebView 里的 `video` 只能出 SDR，且实测 **HEVC 完全不支持**。两条触发条件在你这台机器上天然成立。B 阶段不是"以后再说"，是"迟早要做"。

---

## 4. 推荐架构

```
雷鸟电视 · Android 11 · MT9653
└── SoujuTv (Kotlin, 单 Activity + 播放 Activity)
    ├── TvInputRouter        遥控器按键拦截与分发
    ├── WebView              React SPA + 注入 TV 皮肤 + 焦点引擎
    ├── NativeBridge         16 个方法的 Android 实现
    ├── PlayerActivity       media3 / ExoPlayer（B 阶段）
    └── LocalInputServer     手机扫码输入（局域网 HTTP，可选）
```

### 模块清单

| 文件 | 职责 | 估算行数 |
|---|---|---|
| `MainActivity.kt` | 宿主、生命周期、按键入口 | 240 |
| `TvWebViewClient.kt` | 域名白名单、m3u8 拦截、错误页 | 150 |
| `NativeBridge.kt` | 16 个方法路由 + 来源校验 | 320 |
| **`TvCompat.kt`** | **documentStart 注入 polyfill + Chrome 83 CSS 基线（§5.5）** | **80** |
| `TvFocusEngine.kt` | 注入 JS：候选集、最近邻、滚动、高亮 | 400 |
| `TvSkin.kt` | TV 版式 CSS（16:9 重排）+ 深色层 | 450 |
| `PlayerActivity.kt` | ExoPlayer + 遥控器播放条 | 320 |
| `LocalInputServer.kt` | 二维码 + 输入回传 | 180 |
| `ShellConfig.kt` | 线路、偏好、远程配置 | 120 |

**构建约束**：`minSdk 21` / `targetSdk 30+`，只能打 `armeabi-v7a`。不要引入 arm64-only 的 `.so`（某些版本的 media3 decoder 扩展、X5 内核需要核对架构）。media3-exoplayer 主库是纯 Kotlin + 系统 MediaCodec，32 位可用。

### 与 iOS 版的复用关系

**能搬的（设计资产，不是代码）**

- 16 个桥方法的语义与回包结构（已在 README 固定）
- 线路 failover 策略、`effectiveDomains` 概念
- 深色派生思路（结构一份 + 12 条色值映射 + 介质层）
- 皮肤自检的锚点清单（哪些选择器是关键路径）
- 站点 BEM 类名的重排手法（`.movie-home-page-shell` 等）

**不能搬的**：Swift 代码本身，0 行直接可用。UIKit/WKWebView 与 Android/WebView 的相似只到"都是 WebView"这一层。

**TV 版反而更安全**：iOS 版之所以要做 origin 白名单，是因为工具箱允许用户填任意域名。电视上没有键盘，**这个入口直接砍掉**，白名单固定为两条内置线路 + 远程配置下发。攻击面反而小了。

### 桥的 Android 实现要点

| | iOS | Android（本机 WebView 83） |
|---|---|---|
| 上行 | `webkit.messageHandlers.nativeBridge.postMessage` | **`@JavascriptInterface`**（`addWebMessageListener` 要 WebView 88+，本机不可用） |
| 下行 | `evaluateJavaScript` | `evaluateJavascript` |
| 来源校验 | `frameInfo.securityOrigin.host` | `shouldOverrideUrlLoading` 全域名拦截 + 一次性会话令牌 |
| UA | 系统默认 | **必须覆盖**（系统浏览器伪造 iPad Safari 5.0.2，会让站点降级） |

`addWebMessageListener` 需要 WebView 88 以上，本机 83 只能走 JS 接口。而 `@JavascriptInterface` 对该 WebView 里**所有 frame** 都暴露，所以必须同时做两件事：

1. `shouldOverrideUrlLoading` 拦掉白名单外的所有跳转（TV 版本来就没有任意 URL 入口，白名单固定）
2. 每次页面加载由 `documentStart` 注入一个随机令牌，桥方法校验令牌后才执行

这两条合起来才等价于 iOS 版 `securityOrigin.host` 那道校验。**不能只做其一。**

**能力上报要改**：B 阶段实现 ExoPlayer 后，`supportsNativePlayer` 才能报 `true`。A 阶段仍然报 `false`，让站点走 H5 播放器——和 iOS 版同样的取舍。

---

## 5. 硬问题清单

### 5.1 遥控器焦点（真正的难点，占整体难度一半）

**事实**：Android WebView 里，方向键常常根本到不了 JS 的 `keydown`——被原生消费用于它自己的焦点遍历。而原生空间导航在嵌套容器（横向滑动列表套在纵向列表里，正是海报墙的结构）会失效，社区里有完整的问题记录：上下跳跃、焦点越界、页面抖动。

**所以不要指望 WebView 自带的焦点行为。**

方案：原生拦截 + 自建焦点引擎。

```
按键 → dispatchKeyEvent 拦截 DPAD_UP/DOWN/LEFT/RIGHT/CENTER
     → evaluateJavascript("__tvKey(20)")
     → JS: 候选集 → 方向最近邻 → el.focus({preventScroll:true}) → scrollIntoView
```

JS 侧三个要点：

1. **候选集**：`[data-tv-focusable], a[href], button, [role=button]`，过滤掉不可见（`rect.width > 0 && getComputedStyle(el).visibility !== 'hidden'`）。
2. **方向最近邻**：不要用简单的"最近中心点"，会斜跳。用轴向惩罚——主方向距离权重 1，垂直偏移权重 2~3，只考虑主方向上确有位移的候选。
3. **滚动节流**：`scrollIntoView({block:'center', behavior:'smooth'})` 在低端 SoC 上会抖，改成 `behavior:'auto'` + 自己算 `scrollTop`，200ms 内合并。

**视觉**：DOM 的 `:focus` 在 TV 上默认不可见，必须自己画。2px 描边用现有橙色强调色 + `transform: scale(1.06)`，`transition` 120ms。这是电视上"能看懂自己在哪"的唯一依据。

**一处必须留的例外**：进入原生播放器后**停止注入按键**，否则播放条和视频本身抢事件。

### 5.2 搜索输入（决定可用性）

电视上打字是这类应用的生死线。四个选项：

| 方式 | 体验 | 成本 | 结论 |
|---|---|---|---|
| 手机扫码输入 | 最好，手机全键盘 | ~180 行 + 一个局域网 HTTP 服务 | ✅ 做 |
| 九宫格 T9 拼音 | 可接受 | 高（要拼音词表） | 备选 |
| 只给热词 + 首字母 | 够用但受限 | 低 | 兜底 |
| 语音 | 最理想 | 拿不到（系统助手占用） | ✗ |

扫码方案：TV 显示二维码 → 手机打开 `http://<电视IP>:8080` → 输入 → WebSocket 回传 → 注入到站点搜索框并触发搜索。延迟目标 < 200ms。

### 5.3 实测结果：Chromium 83

```
adb shell dumpsys webviewupdate
  Current WebView package (name, version): (com.android.webview, 83.0.4103.120)
  WebView packages: 只有一个，Fallback logic enabled: false
```

落在原先判定的 **80–89 风险带**。复测工具已沉淀为 `tools/tv-webview-probe.py`，完整数据见 `docs/tv-webview-capabilities.json`。

**JS 侧（好消息）**：站点全部 10 个初始 JS（101 万字符）+ 119 个懒加载分片（259 万字符）里，`??=` / `&&=` / `||=` 这类**解析级不兼容语法为 0**。也就是说不会出现「整站白屏」。缺的是运行时 API，且站点自己已经给 `WeakRef` / `AggregateError` / `AbortSignal.timeout` / `Array.findLast` 写了保护或 polyfill。

真正没有保护、会实际抛错的只有三处：

| API | 站点调用 | 出现位置 |
|---|---|---|
| `Array.prototype.at` | 6 处 | **首页追剧日历、首页地址提示、播放器分组** |
| `String.prototype.replaceAll` | 1 处 | 原生播放器 surface 目录 |
| `crypto.randomUUID` | 1 处无保护调用 | 影片卡的会话 ID |

这三个各写几行 polyfill 就够了，见 §5.5。

**CSS 侧（真正的麻烦）**：Chromium 83 缺一批现代布局特性，而站点自己的 492KB CSS 大量依赖它们。

| 特性 | Chrome 83 | 站点 CSS 使用次数 | 后果 |
|---|---|---|---|
| flex `gap` | ✗（84 才支持） | `gap:` 88 处 | flex 容器子元素贴在一起 |
| `aspect-ratio` | ✗（88） | 25 处 | 海报卡高度塌陷 |
| `:has()` | ✗（105） | 20 处 | 条件样式整条被忽略 |
| `:focus-visible` | ✗（86） | 74 处 | 站点自身焦点样式失效 |
| `inset` | ✗（87） | 4 处 | 定位偏移失效 |
| `clamp()` / `backdrop-filter` / grid gap / `object-position` | ✓ | — | 可用 |

实测 flex gap 的判据不是查文档：放了 `gap:10px` 的 flex 容器，第二个子元素 `offsetLeft=10`（支持应为 20）。

**结论**：路线 A 依然成立，但不能裸跑。需要 §5.5 的兼容层；另一个更彻底的选择是升级系统 WebView（见 §5.6），那是系统级改动，须单独拍板。

### 5.4 播放

A 阶段直接用站点的 H5 播放器，需要两件事：

- `WebChromeClient.onShowCustomView / onHideCustomView` 必须实现，否则 `requestFullscreen` 静默失效（WebView 会告诉网页"我不支持全屏"）
- `android:hardwareAccelerated="true"`，否则视频白屏有声音没画面

但 H5 播放器在电视上有个死结：**它的控件是为触摸设计的**，遥控器点不到进度条。这就是进 B 阶段的理由。

B 阶段做法（不改站点一行代码）：

```
WebViewClient.shouldInterceptRequest
  → 命中 .m3u8 / /hls/ 
  → 记下地址 + 返回空响应（阻止 WebView 自己播）
  → 起 PlayerActivity，ExoPlayer 播
```

这招 iOS 版已经在用（递归扫描 payload 里的媒体地址），只是当时没接原生播放器。Android 侧反而更简单：`media3-exoplayer-hls` 直接吃 m3u8，硬解走 MediaCodec，4K/HEVC/HDR 都是现成的。

**HDR 是这台机器特有的增量收益**：75R675C 支持杜比视界 IQ / HDR10+ / IMAX Enhanced，但 WebView 内的 HTML5 `video` 走普通渲染路径，HDR 元数据不会直通到显示链路，画面按 SDR 呈现——面板能力被浪费。ExoPlayer 走 MediaCodec 硬解，HDR10 / HLG 直通比较有把握；杜比视界取决于厂商是否向三方 App 暴露 DV 解码器，属不确定项，需要实测。

播放条按电视习惯做：左右 = 快退/快进 10s，OK = 暂停，返回 = 退出，上下 = 选集。**不要做成触摸式的进度条拖拽。**

补充一条实测证据：`MediaSource.isTypeSupported('video/mp4; codecs="hev1..."') = false`、`video.canPlayType('hevc') = ""`，而 `h264 = "probably"`。也就是说 **WebView 里根本播不了 HEVC**。如果站点后续上 HEVC 片源，H5 播放器会直接失效——这是 B 阶段除 HDR 之外的第二个硬理由。

### 5.5 兼容层（防御性补丁，约 0.25 天）

**定位变化**：原先按静态扫描判断「首页可能因 `Array.at` 报错」，把它列为启动前置项。
11:10 实机裸跑（§0.2）证明首页完整渲染、logcat 无 `TypeError`，所以它**不再是路线 A 的前置条件**。
但懒加载分片里那 6 处 `.at(` 和 1 处 `.replaceAll(` 是真实调用，进入对应页面时仍可能抛错；
TV 皮肤也必须避开 Chrome 83 不支持的 CSS。因此这层保留，只是并入阶段 3 一起做，不再单列一个里程碑。

在 `documentStart` 注入，先于站点任何脚本执行。两件事：

**① 运行时 polyfill**（只需 3 个，其余站点已自补或没用到）

```js
// Array.prototype.at —— 首页追剧日历会用到 arr.at(-1)
if (!Array.prototype.at) Object.defineProperty(Array.prototype, 'at', {
  value: function (n) { n = Math.trunc(n) || 0; if (n < 0) n += this.length;
    return (n >= 0 && n < this.length) ? this[n] : undefined; }, writable: true, configurable: true
});
// String.prototype.replaceAll
if (!String.prototype.replaceAll) String.prototype.replaceAll = function (a, b) {
  return String(this).split(a).join(b);
};
// crypto.randomUUID（Chrome 92 才有）
if (window.crypto && !crypto.randomUUID) crypto.randomUUID = function () {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
    var r = crypto.getRandomValues(new Uint8Array(1))[0] & 15;
    return (c === 'x' ? r : (r & 3 | 8)).toString(16);
  });
};
```

不要把 `WeakRef` / `FinalizationRegistry` / `structuredClone` 也随手补上——站点对前两个有 `typeof` 保护，后一个根本没用，多补反而可能改变库的特征检测分支。

**② TV 皮肤 CSS 按 Chrome 83 基线写**

这套皮肤本来就要重写（§6），所以「写成 83 兼容」只是约束，不是额外工作：

| 不要用 | 改用 |
|---|---|
| flex `gap` | 子元素 `margin`，或改用 CSS Grid（grid gap 是支持的） |
| `aspect-ratio` | 显式 `height` / `padding-bottom` 百分比 |
| `:has()` | `sync()` 里用 JS 打 `data-*` 类，CSS 再选中 |
| `:focus-visible` | 普通 `:focus` + JS 维护的 `.tv-focused` 类 |
| `inset` | 展开成 `top/right/bottom/left` |
| `content-visibility` | 直接不用 |

站点自身 CSS 里那些失效的 `gap` / `aspect-ratio`，靠 TV 皮肤对关键容器（海报卡、卡片网格、首屏横幅）显式覆盖即可，不必逐条修补 492KB。

### 5.6 系统 WebView：已拍板不升级

上面这套兼容层能解决**当前**站点，但站点以后重新构建、把 target 提到 Chrome 87+，就可能出现 `??=` 这类解析级语法，polyfill 补不了（脚本根本加载不了）。

彻底解法是给电视装一个新 WebView provider：

```
adb install com.google.android.webview-<arm32>.apk
adb shell cmd webviewupdate set-webview-implementation com.google.android.webview
```

- 优点：一劳永逸，站点改版不用跟着打补丁
- 风险：**这是系统级改动**，会影响电视上所有用 WebView 的 App；需要找匹配 `armeabi-v7a` + API 30 的 APK 版本；失败可用 `set-webview-implementation com.android.webview` 回退
- 代价：约半天验证，且要确认厂商是否放行用户安装的 provider

**决定（2026-11-07）：不动系统 WebView。** 走 §5.5 兼容层，不改电视系统、随时可迭代。
上面这组命令只作为将来站点改版、真出现解析级语法时的应急手段留档，现在不执行。
实机裸跑已证明当前站点在 83 上能完整渲染，这个「一劳永逸」的收益目前并不紧迫。

---

## 6. 16:9 版式改造

现有 iOS 皮肤是手机竖屏的版式（底部 tab、单列卡片）。电视要重做，但**结构复用**——还是按 BEM 类名重排，套路一样。

| 项 | iOS（竖屏） | TV（**1280×720 CSS px @ dpr 1.5**） |
|---|---|---|
| 导航 | 底部 tab | 顶部横向，或左侧竖栏（推荐左侧，横向滚动更省） |
| 海报网格 | 2–3 列 | **6 列**（每张约 185 CSS px ≈ 278 物理 px，间距 12 CSS px） |
| 今晚首选卡 | 1.42:1 竖版 | 16:9 横幅，约 1140×270 CSS px |
| 最小字号 | 13px | **24 CSS px**（≈36 物理 px，2.5m 观看距离可读） |
| 焦点态 | 无 | 2px 描边 + 1.06 缩放，用 `:focus` 而非 `:focus-visible` |
| 默认皮肤 | 深色 | 深色（电视环境光暗，不做浅色也无妨） |

**数值为什么变了**：`wm size 1920×1080` 是物理像素，`wm density 240` 意味着 1 CSS px = 1.5 物理 px，实测 `innerWidth=1280 / innerHeight=720 / dpr=1.5`。所以坐标系是 1280×720，之前写的 1920×1080 是物理值，用来排版会做出偏小一半的界面。

字号同理：24 CSS px 在这个 density 下已经是 36 物理像素，比初版写的 32 CSS px 更合理（32 会大到一屏放不下几张卡）。

排布约束见 §5.5：**不要用 flex gap、aspect-ratio、`:has()`、`:focus-visible`、`inset`**，这些在 Chromium 83 上全部无效。

深色层可以基本照搬现有的 `soujuDarkLayerCSS` 思路，只是色值映射表要按 TV 版式重算一遍。

---

## 7. 里程碑

| 阶段 | 交付 | 估时 | 状态 / 验收标准 |
|---|---|---|---|
| **0** | JDK17 + SDK + 32 位空壳 APK + 安装取证 | 0.5 天 | ✅ **已完成**，见 §0.2 六项实测 |
| ~~0.5~~ | 兼容层（polyfill + Chrome 83 CSS 基线） | 0.25 天 | 已并入阶段 3；裸跑证明不阻断启动 |
| 1 | WebView 壳 + 桥 + 线路 failover | 2 天 | 首页能显示，桥日志有 `bridge-ok` |
| 2 | **遥控器焦点引擎** | 2–3 天 | 6 列海报可用方向键遍历，无斜跳、无抖动 |
| 3 | TV 版式皮肤（1280×720 坐标系）+ 兼容层 | 2–3 天 | 无横向滚动条，字能看清，避开 5 个失效 CSS 特性 |
| 4 | 手机扫码输入 | 1 天 | 手机输入后 TV 200ms 内出结果 |
| 5 | ExoPlayer 播放 | 2–3 天 | 1080p 硬解，遥控器可控播放条 |

阶段 0 已完成，**剩余约 8–12 个工作日**，业余节奏 2–3 周。
工程骨架（`tv/`）、构建脚本、自签名证书都已落地，阶段 1 不用再从零搭环境。

---

## 8. 环境、工具链与安装链路（全部已验证）

| 事项 | 状态 |
|---|---|
| 型号确认（鹤7 Pro 75R675C） | ✅ |
| 电视 ADB 开关 + RSA 授权 | ✅ |
| Mac `android-platform-tools` | ✅ `adb 1.0.41 / 37.0.1`，软链 `/usr/local/bin/adb` |
| 电视 IP | ✅ `Android.local` → `192.168.0.4:5555`，mDNS 自动发现 |
| 设备 / WebView / 视口取证 | ✅ `tools/probe-tv.sh` |
| WebView 能力边界 | ✅ `tools/tv-webview-probe.py` → `docs/tv-webview-capabilities.json` |
| **JDK 17** | ✅ Temurin `17.0.21+9`，`~/Library/Android/jdk17/home`（清华 Adoptium 镜像） |
| **Android SDK** | ✅ cmdline-tools 12.0 / platform-34 / build-tools 34.0.0（dl.google.com 直连） |
| **构建脚本** | ✅ `tools/build-tv-apk.sh`：aapt2 → javac → d8 → zipalign → apksigner，产物 20KB |
| **签名证书** | ✅ `~/.souju-tv/tv.jks`，30 年有效；v1/v2/v3 全通过，覆盖安装签名不变 |
| **安装链路** | ✅ `adb install -r` → `Success`；两个 verifier 开关为 `null` 并未拦截 |
| **桌面可见** | ✅ 「我的应用」列表共 10 项，搜剧TV 排第一位 |

三条最常用的命令：

```bash
# 一次构建 + 安装
bash tools/build-tv-apk.sh && adb install -r tv/build/souju-tv-debug.apk

# 取证：App 自己打的全部日志（BOOT / JS / DOM / KEY / CONSOLE）
adb logcat -d -s SoujuTV

# 换页不用重编译
adb shell am force-stop com.wuxiaogang.soujutv
adb shell am start -n com.wuxiaogang.soujutv/.MainActivity --es url "https://bpz2.com/"
```

mDNS 发现链路留档（换路由器、IP 变了时用）：

```bash
dns-sd -B _adb._tcp local.
dns-sd -L <实例名> _adb._tcp local.        # → Android.local.:5555
dscacheutil -q host -a name Android.local  # → 192.168.0.4

# 重跑能力探针（会唤醒电视并强停自带浏览器，30 秒出结果）
python3 tools/tv-webview-probe.py --save /tmp/probe.json
```

下一步是**阶段 1**：把空壳升级成正式 WebView 壳（域名白名单、桥、线路 failover）。
`tv/` 里已有可直接运行的 manifest / MainActivity / 资源，不必再从零搭工程。

---

## 9. 风险清单

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| **Chromium 83 缺运行时 API / CSS 特性** | **能力缺失已确认，首页未受影响** | 懒加载页可能报错、站点 CSS 版式塌陷 | §5.5 兼容层（0.25 天）+ TV 皮肤显式覆盖；裸跑首页已通过 |
| **站点未来改版用上 Chrome 85+ 语法** | 中 | 解析级白屏，polyfill 补不了 | §5.6 升级系统 WebView；或保留远程注入 CSS/JS 通道做应急 |
| 遥控器焦点手感差，做不出"顺" | 中高 | 可用性受损 | 焦点引擎是独立模块，可单独打磨与回归 |
| 站点域名轮换导致线路失效 | 高（已知） | App 打不开 | 远程配置下发线路，不必重装 |
| ~~`adb install` 被安装校验拦截~~ | **已排除**（实测 `Success`） | — | 两条 `settings put global` 与 U 盘兜底留作备用 |
| 32 位 ABI 导致某个依赖装不上 | 中（空壳已验证通过） | 编译/运行时失败 | 空壳不含 `.so`，天然兼容；将来引入 ExoPlayer 时核对 `.so` 架构 |
| 杜比视界未必对三方 App 开放 | 中 | B 阶段只能拿到 HDR10/HLG | 实测；不承诺 DV，UI 上不标 DV 角标 |
| WebView 内 HEVC 不支持 | 已确认 | HEVC 片源播不了 | B 阶段 ExoPlayer 走 MediaCodec |
| 4GB 内存跑 SPA + hls.js 吃紧 | 低–中 | 卡顿/被系统杀 | 限制海报预载数；B 阶段把播放挪出 WebView |
| 语音键不可用 | 确定 | 少一个输入入口 | 用手机扫码输入替代 |

---

## 10. 一句话建议

阶段 0 已完成，接下来先做 **1 + 2**（约 5 天）：正式 WebView 壳（桥、域名白名单、线路 failover）+ 遥控器焦点引擎。

「能装、能显示」已经用实机证明，不必再验证；剩下的最大不确定性只在焦点手感上。
兼容层和 TV 皮肤并入阶段 3 一起做，是因为实测证明它们不阻断启动，可以边写边看效果。

系统 WebView 已决定不动（§5.6），没有待拍板事项。
