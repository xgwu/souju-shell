# 搜剧 AI 电视版（雷鸟鹤系列）可行性与技术方案

> 调研日期：2026-11-07 · 目标设备：雷鸟 鹤系列（Android 11 / MT9653）
> 参考实现：同仓 iOS 版 `souju-shell`（6049 行 Swift）

---

## 0. 结论

**可行，且比 iOS 版省事得多。**

一句话概括取舍：**这条路唯一真正难的地方是遥控器，其他都是移植。**

三条路线里推荐 **A（WebView 壳）先跑通 → B（补原生播放器）**，不做全原生。理由在 §3。

必须先说清楚一个前提：**Android 侧没有 iOS 那套 7 天限制**。APK 用自签名证书，装一次永久有效，不会因为证书过期闪退。iOS 版为了续签折腾的那一整套（Sideloadly、daemon、Wi-Fi 同步）在电视上完全不存在。

---

## 1. 目标设备事实

| 项 | 值 | 对方案的影响 |
|---|---|---|
| 芯片 | MT9653（Pentonic 700），4×Cortex-A73 + Mali-G52 MC1 | 跑 WebView 够用，但别指望 4K UI |
| 系统 | **Android 11**（AOSP，无 GMS、无 Play 商店） | 只能自签名侧载；也无法依赖 Google 的 WebView 更新通道 |
| 内存/存储 | 4GB / 64GB | 服务端渲染的 SPA 可以，`hls.js` 会吃内存 |
| ABI | arm64-v8a | 单一架构，好打 |
| 屏幕 | 4K 面板，系统按 1920×1080 dp / density 2 呈现 | WebView 视口按 1920×1080 CSS px 设计 |
| 遥控器 | 蓝牙语音键 + 红外/蓝牙方向键、OK、返回 | 语音键走系统助手，**第三方 App 拿不到** |

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

**这条事实决定了最大的技术风险**：Vite 默认构建目标是 ES2020。如果电视的 WebView 内核低于 Chromium 80，`?.` 和 `??` 会直接语法报错，整站白屏——不是"难看"，是"打不开"。见 §5.3。

---

## 3. 路线对比

| | 工作量 | 播放质量 | 维护成本 | 主要风险 | 结论 |
|---|---|---|---|---|---|
| **A. WebView 壳** | ~1200 行 | 中（H5 播放器） | 低 | WebView 内核版本 | ✅ 第一阶段 |
| **B. 混合（A + ExoPlayer）** | A + ~700 行 | 高（硬解 / 4K / HDR） | 中 | 抓流地址的稳定性 | ✅ 第二阶段 |
| C. 全原生（Leanback + API 逆向） | 3–6 周 | 高 | 高（站点改版即失效） | 接口无契约 | ✗ 不做 |
| D. 手机投屏 | 0 | 低 | 0 | iOS AirPlay 到电视不通 | ✗ 仅作对照 |

**为什么不选 C**：站点是 React SPA，接口没有公开契约，全部靠抓包。iOS 版的经验已经证明这套东西改一次版就要重新逆向（README 里"下载入参形状没拿到"就是活例子）。投入产出比不成立。

**为什么 B 要拆成第二阶段**：A 阶段能验证的东西（能不能装、能不能显示、遥控器能不能走）不需要播放器。播放不满意再上 B，触发条件明确写下来：**1080p 播放掉帧、或 H5 播放条无法用遥控器操作、或需要 4K/HEVC**，出现任一条就进 B。

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
| `TvFocusEngine.kt` | 注入 JS：候选集、最近邻、滚动、高亮 | 400 |
| `TvSkin.kt` | TV 版式 CSS（16:9 重排）+ 深色层 | 450 |
| `PlayerActivity.kt` | ExoPlayer + 遥控器播放条 | 320 |
| `LocalInputServer.kt` | 二维码 + 输入回传 | 180 |
| `ShellConfig.kt` | 线路、偏好、远程配置 | 120 |

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

| | iOS | Android |
|---|---|---|
| 上行 | `webkit.messageHandlers.nativeBridge.postMessage` | `WebViewCompat.postWebMessage`（WebView 88+）或 `@JavascriptInterface` |
| 下行 | `evaluateJavaScript` | `evaluateJavascript` |
| 来源校验 | `frameInfo.securityOrigin.host` | `WebMessageListener` 的 `sourceOrigin`；JS 接口方案需另配令牌 |

优先 `addWebMessageListener`（带 `allowedOriginRules`，天然做来源隔离）。只有内核 < 88 才退回 `addJavascriptInterface`——那时**必须**配合 `shouldOverrideUrlLoading` 的全域名拦截，因为 JS 接口对整个 WebView 的所有 frame 都是暴露的。

**能力上报要改**：B 阶段实现 ExoPlayer 后，`supportsNativePlayer` 才能报 `true`。A 阶段仍然报 `false`，让站点走 H5 播放器——和 iOS 版同样的取舍。

---

## 5. 四个硬问题

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

### 5.3 WebView 内核版本（最大不确定项）

**这是开工前必须先测的一条。** Vite 产物是 ES2020，内核低于 80 直接白屏。

测法：

```
adb shell dumpsys webviewupdate | grep "Current WebView package"
adb shell getprop ro.build.version.release
adb shell wm size; adb shell wm density
```

| 内核版本 | 判定 | 应对 |
|---|---|---|
| ≥ 90 | ✅ 无忧 | 直接做 |
| 80–89 | ⚠️ 可用 | 关掉站点用不到的新 API，别用 `ResizeObserver` |
| 66–79 | ⚠️ 危险 | 白屏风险高，先试装 Google WebView 或 X5 内核 |
| < 66 | ✗ 不可行 | 转 C 路线或换设备 |

AOSP TV 的 WebView 是厂商预编译的（`com.android.webview`），不走 Google 更新通道。所以这一条不能靠"猜"，必须实测。缓解手段依次是：`cmd webviewupdate set-webview-implementation` 指定新内核 → 装 Google WebView APK → X5 内核 → 放弃 WebView 路线。

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

播放条按电视习惯做：左右 = 快退/快进 10s，OK = 暂停，返回 = 退出，上下 = 选集。**不要做成触摸式的进度条拖拽。**

---

## 6. 16:9 版式改造

现有 iOS 皮肤是手机竖屏的版式（底部 tab、单列卡片）。电视要重做，但**结构复用**——还是按 BEM 类名重排，套路一样。

| 项 | iOS（竖屏） | TV（1920×1080） |
|---|---|---|
| 导航 | 底部 tab | 顶部横向，或左侧竖栏（推荐左侧，横向滚动更省） |
| 海报网格 | 2–3 列 | **6 列**（每张 260px 宽，间距 24px） |
| 今晚首选卡 | 1.42:1 竖版 | 16:9 横幅，占满首屏上半 |
| 最小字号 | 13px | **32 CSS px**（≈24sp，2.5m 观看距离可读） |
| 焦点态 | 无 | 2px 描边 + 1.06 缩放 |
| 默认皮肤 | 深色 | 深色（电视环境光暗，不做浅色也无妨） |

深色层可以基本照搬现有的 `soujuDarkLayerCSS` 思路，只是色值映射表要按 TV 版式重算一遍。

---

## 7. 里程碑

| 阶段 | 交付 | 估时 | 验收标准 |
|---|---|---|---|
| 0 | 环境（JDK17 + cmdline-tools + platform-tools），空壳装进电视 | 0.5 天 | 桌面能看到图标并启动 |
| 1 | WebView 壳 + 桥 + 线路 failover | 2 天 | 首页能显示，桥日志有 `bridge-ok` |
| 2 | **遥控器焦点引擎** | 2–3 天 | 首页 6 列海报可用方向键遍历，无斜跳、无抖动 |
| 3 | TV 版式皮肤 | 2–3 天 | 16:9 下无横向滚动条，字能看清 |
| 4 | 手机扫码输入 | 1 天 | 手机输入后 TV 200ms 内出结果 |
| 5 | ExoPlayer 播放（可选） | 2–3 天 | 1080p 硬解，遥控器可控播放条 |

合计约 **8–12 个工作日**，业余节奏 2–3 周。

---

## 8. 开工前需要先确认的三件事

1. **具体型号**（鹤 5 / 鹤 6 / 鹤 6 Pro / 鹤 7，哪一年款）——直接影响 Android 版本与 WebView 内核
2. **开启 ADB 并记下电视 IP**（路径见 §1）
3. **允许我在 Mac 上装 `android-platform-tools`**（约 10MB，只为拿到 `adb`）

拿到 ADB 后，六条命令即可给出全部关键参数：

```bash
adb connect <IP>:5555
adb shell getprop ro.product.model
adb shell getprop ro.build.version.release
adb shell dumpsys webviewupdate | grep -i "current webview package"
adb shell wm size; adb shell wm density
adb shell dumpsys meminfo | head -5
```

其中第三条（WebView 内核）决定这件事能不能做成。

---

## 9. 风险清单

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| WebView 内核过低导致白屏 | 中 | 路线 A 直接失效 | 先实测；备选 Google WebView / X5 |
| 遥控器焦点手感差，做不出"顺" | 中高 | 可用性受损 | 焦点引擎是独立模块，可单独打磨与回归 |
| 站点域名轮换导致线路失效 | 高（已知） | App 打不开 | 远程配置下发线路，不必重装 |
| 电视厂商限制第三方安装 | 低 | 装不上 | ADB 关闭安装校验；U 盘兜底 |
| 4GB 内存跑 SPA + hls.js 吃紧 | 中 | 卡顿/被系统杀 | 限制同时预载海报数；必要时 B 阶段把播放挪出 WebView |
| 语音键不可用 | 确定 | 少一个输入入口 | 用手机扫码输入替代 |

---

## 10. 一句话建议

先只做 **0 + 1 + 2** 三个阶段（约 5 天），把"能装、能看、遥控器能走"验证掉。这三步过了，剩下都是体力活；过不了，越早发现越省事。
