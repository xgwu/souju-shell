# 搜剧 · iOS 自用壳

一个**给自己用、自签名、不上架**的 iOS 套壳看剧 App。基于资料库里两份材料：

- `report-hctd4-ios-shell.html` —— 套壳可行性实测（结论：自用壳可行，上架无解）
- `souju-light.html` —— 界面语言（海报优先 / 单一强调色 / 编辑感）
- `souju-dark.html` —— 同一套界面语言的暗介质（墨玉画布 / 暖白 / 单一亮橙），是默认皮肤的依据

**核心判断**：这个壳不是"从零造一个浏览器"，而是**照站点已有的 `nativeBridge` 协议复刻一个容器**。协议是从线上 bundle 里逆出来的（见下文对照表），不是猜的。

---

## 1. 先说清楚边界

| | 结论 |
|---|---|
| 自用 / 自己一台手机 | ✅ 可以做，本工程就是 |
| 发给别人 / 长期运营 | ❌ 不做。版权 + 审核 2.5.2 / 5.2.1 是硬阻断，我不会协助设计绕审核的方案 |
| 上 App Store | 成功率 ≈ 0，不要投入 |

App Store 那几条拦路的是：权利证明、内容授权、Guideline 4.2（纯网页包装）、隐私政策页、中国区 ICP + 视听许可证。这个壳一个都不解决，**它只解决"我自己看得舒服"**。

---

## 2. 跑起来

**Xcode 14.2 在本机已经装好并激活**（`/Applications/Xcode.app`，`Build 14C18`，iOS 16.2 SDK）。你的机器是 macOS 12.7.6 Monterey，14.2 是它能装的最高版本（14.3 起要求 Ventura 13）。重装或换机时才需要走 `tools/activate-xcode.sh`。

### 已有脚本

```bash
cd ~/WorkBuddy/2026-11-06-11-31-15/souju-shell

bash tools/build.sh          # 无签名编译 → build/Build/Products/Debug-iphoneos/SoujuShell.app
bash tools/make-ipa.sh       # 打包 → dist/SoujuShell.ipa（ad-hoc 签名，供 SideStore 重签）
```

### 装到 iPhone

**方式 A：Xcode**（能调试，7 天需重签）

1. `open SoujuShell.xcodeproj`
2. target → **Signing & Capabilities** → `Team` 选 **Personal Team**（免费 Apple ID 即可）
3. `Bundle Identifier` 已经是 `com.wuxiaogang.soujushell`，想换就换（必须全球唯一）
4. 顶部选你的 iPhone → `⌘R`

**方式 B：SideStore / AltStore**（不用 Xcode，能自动续签）

把 `dist/SoujuShell.ipa` 导入 SideStore，用它自带的 Apple ID 重签安装。

首次安装后，手机上要**信任证书**：设置 → 通用 → VPN与设备管理 → 开发者 App → 信任。

### 自签的现实约束

| 项目 | 免费 Apple ID | 付费开发者账号（$99/年） |
|---|---|---|
| 证书有效期 | **7 天**，到期重签 | 1 年 |
| 同时可装 App | 3 个 | 不限 |
| 推送 / 部分 Entitlement | 不可用（本工程不依赖） | 可用 |
| 重签方式 | Xcode 再 `⌘R` 一次 | 过期前重装 |

7 天过期后会变成"无法打开"。两种做法：
1. **手动**：每周连一次 Mac，Xcode `⌘R`。最省事，缺点是要记着。
2. **自动续签**：装 [SideStore](https://sidestore.io)（在设备上自签，配合 WireGuard 本地回环），或用 AltStore。配置比手动麻烦，但一次搞定后不用管。

> 想彻底免掉 7 天限制，只能上付费账号 + 自签 IPA，属同一套流程。

---

## 3. 壳做了什么（能力矩阵）

| 能力 | 状态 | 实现位置 |
|---|---|---|
| 多线路探活 + 自动故障转移 | ✅ | `ShellViewController.orderedDomains / handleFailure` |
| 记住上次可用线路 | ✅ | `ShellSettings.preferredDomain` |
| 状态栏跟随站点明暗 | ✅ | `statusBar.setStyle` → `ShellModel.applyStatusBarStyle` |
| 刘海 / 安全区 | ✅ 交给网页 | `contentInsetAdjustmentBehavior = .never` + `viewport-fit=cover` |
| 外链用系统浏览器打开 | ✅ | `browser.openExternalURL` → SFSafariViewController |
| 离线下载（HLS + mp4） | ✅ 自研引擎 | `DownloadManager` |
| 本地播放 / 画中画 / 后台音频 | ✅ | `OfflinePlayerController`（AVPlayerViewController） |
| AirPlay 设备选择 | ✅ 原生面板 | `presentAirPlayPicker` |
| 顶部 2px 进度线 | ✅ | `RootView.loadingHairline` |
| 摇一摇 / 双指下滑 打开工具箱 | ✅ | `motionEnded` / `UISwipeGestureRecognizer` |
| 下拉刷新、右滑返回 | ✅ | `UIRefreshControl` / `allowsBackForwardNavigationGestures` |
| **原生播放器接管**（`aimovie_native_v1`） | ❌ 有意不做 | 见第 5 节 |
| 弹幕 / 一起看 | ❌ | 站点能力，壳不介入 |
| **整站换肤**（搜剧 Dark 默认 / Light） | ✅ | `Bridge/SkinPreset.swift`，工具箱 → 主题一键切换，偏好持久化 |
| **首页「今晚首选」置顶卡** | ✅ 皮肤 JS 注入 | 取日历里今天更新、且不在追的那一部 |
| **周表「只看未看过」筛选** | ✅ 皮肤 JS 注入 | 判定依据是站点自己的 `playback-resume` |
| **短剧竖屏流跟随介质** | ✅ 皮肤 CSS | `/short-drama` 与详情页、选集抽屉一并转墨玉（浅色下转纸白） |
| **横屏 → 竖屏方向补正** | ✅ | `Core/RotationGuard.swift`，见下方说明 |

> **2026-11-06 移除「播放页沉浸」**。原先壳会在播放页藏掉站点页头与侧栏、把视频居中到黑底，
> 并叠一条原生胶囊。但它和站点自己的全屏按钮是两条不相通的路径：点全屏走的是站点的
> 「选择全屏方式 → 原生全屏（系统播放器）」——那是 WebKit present 的 AVPlayer 全屏 VC，
> 网页 CSS 与壳的 UIView 都进不去，设置项（画质增强 / P2P / 弹幕 / 选集）也完全不同。
> 与其让两个"全屏"体验打架，不如把播放页完整交还给站点。相关文件已删，
> 备份在 `../.backup/immersive-20261106-1925/`。

**关于方向**：壳里没有任何方向控制代码，`Info.plist` 允许竖屏 + 左右横屏，旋转交给系统。
但实测偶发「从横屏转回竖屏，界面卡在横屏不动」。诱因在 UIKit / WebKit 一侧——站点「原生全屏」
走 `video.webkitEnterFullscreen()`，WebKit 的播放器全屏窗口控制器收起时可能把 `UIWindowScene`
的几何偏好留在横屏；`SFSafariViewController` 与 SwiftUI sheet 在横屏下进出也可能留下同样的残留。

`Core/RotationGuard.swift` 只补**一种确定不合理**的状态：设备已竖持（`portrait`），界面仍是横屏。
做法是收窄场景掩码到 `.portrait` 触发一次真正的旋转，0.7s 后无论成败都把 `.allButUpsideDown`
还回去（少这一步本次运行会退化成"只能竖屏"）。反方向（界面竖屏、设备横持）**刻意不处理**——
那通常是用户开了竖屏锁定，替用户"纠正"反而是 bug。iOS 15 走 `attemptRotationToDeviceOrientation()`，
该 API 会尊重竖屏锁定，不会硬掰。

**关于原生播放器**：站点有一套完整的 `aimovie_native_player_v1` 协议（`playback.openNativePlayer` / `updateNativePlayerSlot` / `resolveDataRequest` / `cast.startDiscovery`…），工程量是数周级，且每个回包都要按抓包对齐 `command_id` / `generation` 的严格校验。当前壳如实上报 `supportsNativePlayer: false`，站点会判为 `legacy_app` 并**回落到自带的 H5 播放器** —— 看剧这件事完全可用，这是有意的取舍，不是缺陷。

---

## 4. 协议对照表（本工程的核心资产）

以下全部来自 2026-11-06 对 `hctd4.com` 线上 bundle 的静态分析，不是推测。

### 探测链（`native-environment-ChodKNAD.js` 原文逻辑）

```
1. window.H5ShellNativeBridge 存在且 isAvailable !== false  → 认定原生容器
2. 否则 window.webkit.messageHandlers.nativeBridge 存在     → 认定原生容器
3. 都失败 → 以 [0, 120, 320, 700]ms 四轮重试
```

关键：`H5ShellNativeBridge` 在网页侧**只读不定义**（`main.js` 里 5 次出现全是读）。谁注入它，谁就掌握 RPC 的 resolve 权 —— 所以注入脚本在 `BridgeScript.swift`，`documentStart` 就位。

### RPC 契约

```
上行  window.H5ShellNativeBridge.call(module, method, params)
      → postMessage({ operation_id, module, method, params })
下行  壳执行 window.__nativeReply(operation_id, json)
事件  壳执行 window.__nativeEvent(name, payload)
      → 网页收 CustomEvent("h5shell:native-event", { detail: { name, payload } })
```

### 方法清单

| module.method | 参数 | 壳回包 | 状态 |
|---|---|---|---|
| `app.getCapabilities` | `{}` | `{ platform:"ios", actions:[…], nativePlayer:{…} }` | ✅ |
| `app.getSystemInsets` | `{}` | `{ platform:"ios", top,right,bottom,left }` | ⚠️ 站点解析器只认 `platform==="android"`，iOS 走 CSS `env()`，回包会被忽略 |
| `statusBar.setStyle` | `{ style: "lightContent" \| "darkContent" }` | `{ ok:true }` | ✅ 注意不是 `"light"/"dark"` |
| `browser.openExternalURL` | `{ url, title? }` | `{ opened:true, mode:"external", url }` | ✅ |
| `download.enqueue` | 透传，形状未知 | `{ ok:true, accepted:[{taskId,url,state}] }` | ⚠️ 见第 5 节 |
| `download.existsBatch` | 含媒体 URL | `{ results:[{url,taskId,exists,state}] }` | ✅ |
| `download.getState` | `{}` | `{ tasks:[…], total, active }` | ✅ |
| `download.play` | `{ taskId? \| url? }` | `{ ok, taskId }` + 弹原生播放器 | ✅ |
| `download.showManager` | `{}` | `{ ok:true }` + 弹下载列表 | ✅ |
| `download.storeCover` | `{ movieId?, cover }` | `{ ok:true }` | ✅ |
| `cast.openAirPlayRoutePicker` | — | 弹 AirPlay 面板 | ✅ 未在 actions 中上报 |
| `playback.getNativePlayerState` | `{}` | `{ state:"idle", nativePlayer:null }` | ✅ 空态 |
| `auth.getState` | `{}` | `{ ok:false, code:"NOT_IMPL" }` | ❌ 站点启动时会调，见下 |
| `auth.restoreSession` | `{}` | 同上 | ❌ 同上 |
| 其余（`playback.*` / `cast.*` 全量） | — | `{ ok:false, code:"NOT_IMPL" }` | ❌ 未实现 |

**关于 `auth.*`**：站点内置了一套原生登录协议 `aimovie.native-auth.project-jwt.v1`，靠 `capabilityMarker: "project_jwt_v1"` 激活；激活后要求壳走 `transport: "web_jwt_cookie_exchange"` 做 JWT 交换。本壳**不声明该 marker**，所以站点按"无原生登录"处理，回落到自己的 web cookie 登录——登录/收藏/历史都正常。如实回 `NOT_IMPL` 而不是假装成功，是刻意的。

`capabilities.actions` 是站点的**唯一判定依据**（`mt(caps).includes("download.enqueue")`）。谎报会让它调用不存在的方法然后静默降级 —— 比不支持更难查，所以这里只报真的实现了的。

---

## 5. 实测验证（2026-11-06 / iPhone 14 · iOS 16.2 模拟器）

不是"应该能用"，是装进模拟器跑出来的结果。

| 验证项 | 结果 |
|---|---|
| `xcodebuild -version` | Xcode 14.2 / Build 14C18 |
| 真机版编译（`-sdk iphoneos`，arm64） | **BUILD SUCCEEDED**，产物 3.1M |
| 模拟器版编译（`-sdk iphonesimulator`） | **BUILD SUCCEEDED** |
| 安装 + 启动 | 成功，进程存活 |
| 站点加载 | `https://souju.ai` 完整渲染（搜索框 / 热门标签 / 本周追剧 / 剧集列表全在） |
| 桥注入自检 | **`bridge-ok`** |
| 桥 RPC 往返 | 站点主动发起 8 次调用，全部正确回包 |
| 皮肤注入（搜剧 Light） | 首页 / 剧集页 / 周表 / 片单全部转为纸白，`data-skin="souju-light"` 生效 |
| 皮肤路由切换 | 从首页 pushState 到 `/short-drama`：`data-skin` 保持 `souju-light`、`data-theme` 仍 `movie-light`、body 仍 `rgb(250,250,248)` |
| 短剧竖屏流（模拟器） | 视频铺满、底部纸白渐隐、剧名为墨色、片单/查看更多为白胶囊+墨胶囊、底部导航纸白 |
| 短剧详情页（模拟器） | 右侧五个操作按钮转白磨砂胶囊、状态栏深色图标、返回按钮白底圆 |
| 选集抽屉（模拟器） | 站点把控制层钉在 `data-theme="movie-dark"`，层内重映射令牌后转白；选中集为墨底白字 |
| 皮肤抗覆盖 | 手动把 `data-theme` 改回 `movie-dark`，300ms 内被纠正回浅色 |
| 状态栏 | 浅色页面自动 `darkContent`，模拟器截图确认时间/电量可读 |
| 首页「今晚首选」 | 插入位置在 `.home-watch-calendar` 之前；续播含《尚公主》时改选《走马上任》；路由往返后仍只有 1 张卡 |
| 周表筛选 | 8 部中识别出 1 部已看；点开后剩 7 部可见，`souju:unseen-only=1` 已持久化 |
| 播放页（移除沉浸后） | 模拟器截图：站点页头（返回/剧名/菜单）正常、视频回到 y=68 的 16:9 位置、弹幕正常、无胶囊残留 |
| 皮肤无回归 | 注入移除沉浸后的 CSS/JS：`/`、`/updates`、`/player/...` 三页均 `movie-light` + body `rgb(250,250,248)`，无 JS 异常；「今晚首选」卡与「只看未看过」筛选仍在 |
| 首页顶部浓缩（chips 单行） | 无头 Chromium 注入真实皮肤实测：提示条 164→40px、顶部 336→212px、「本周追剧」y=605→481；375/390/430 三宽度均为一行（可视 351/366/406，内容 778）；`scrollLeft` 可置 412 上限，滑动后行高不变 |
| 浓缩后其余路由 | `/updates`、`/short-drama` 同皮肤实测无错位（选择器限定在 `.movie-home-prompt-groups`，非首页不命中） |
| 默认深色启动 | 首次安装直接落 `data-skin="souju-dark"`；老安装里 `shell.skin` 为旧默认值 `souju-light`、且 `shell.skinExplicit` 为假 → 启动时自动改写为 `souju-dark`（`simctl` 读 plist 确认已落盘） |
| 主题开关 | 工具箱顶部「主题」默认选中**深色**；点「浅色」即时切到纸白（`body` 回 `rgb(250,250,248)`、`data-skin="souju-light"`），杀进程重启后仍是浅色（`skinExplicit` 已置真，不再被迁移覆盖） |
| 深色全路由无回归 | `/`、`/updates`、`/player/...`、`/short-drama` 四页截图逐一比对：画布 `#0E0E10`、卡片 `#191A1D` + 1px 描边、文字暖白；tab 选中态为暖白下划线而非橙；浅色版同四页无变化 |
| 深色可读性补丁 | 品牌标在暗底由 `filter: none` 改为 `grayscale(1) brightness(1.32)`（原方案是一团深墨）；短剧页「片单」「热度」等浅底暖白字的按钮改墨磨砂后边界清晰 |
| 状态栏随介质 | dark 皮肤 `lightContent`、light 皮肤 `darkContent`；短剧页两套都交回站点自己决定（不抢占） |
| 「今晚首选」海报自愈 | 冷启动源图 `src` 为空导致海报永久空白（既有 bug）：改 `loading="eager"` + `referrerPolicy="no-referrer"` + `posterOf()` 四级回退 + 最多 4 次重试 + 内容未变但海报仍空则重建卡片，模拟器确认自愈 |
| 方向守卫（`RotationGuard`） | **链路验证通过**：应用内先 `requestGeometryUpdate(.landscapeRight)` 把界面转 90°（证明 `simctl` 做不到的旋转可以被程序驱动），再恢复掩码造出"设备竖持、界面横屏"的卡死态，抛一次方向通知 → 0.45s 后判定卡住、1.35s 内界面回到竖屏、掩码已还原（`retry` 读到 `interface=1`）。注：模拟器 `UIDevice.orientation` 恒为 `unknown(0)`，验证时临时覆盖成 `portrait`，该覆盖已删除 |

实际抓到的桥日志（`Documents/bridge.log` 原文节选）：

```
16:07:12.669 [nav] 载入 https://souju.ai
16:07:16.994 [bridge] 注入自检：bridge-ok
16:07:17.363 [← app.getSystemInsets] {...}
16:07:17.372 [← app.getCapabilities] {...}
16:07:17.376 [→ capabilities] {"platform":"ios","actions":[...]}
16:07:17.427 [← statusBar.setStyle] {"params":{"style":"lightContent"}}
16:07:17.427 [statusBar] style = lightContent
16:07:17.428 [← download.getState] {...}
16:07:19.622 [← auth.getState] {...}
16:07:19.622 [bridge] 未实现：auth.getState
16:07:19.643 [← auth.restoreSession] {...}
16:07:19.643 [bridge] 未实现：auth.restoreSession
```

几个可直接对号入座的结论：

- **`bridge-ok`** 证明站点把壳识别成了原生容器——这是整个方案成立的前提，已实证。
- `statusBar.setStyle` 的实参确认是 **`lightContent`**（不是 `"light"`），与静态分析的预判一致。
- 站点启动就调 `download.getState`，说明下载模块**真的被激活了**，不是摆设。
- `auth.*` 返回 `NOT_IMPL` 后**界面无任何报错**，站点正常回落到 web 登录。

## 6. 改网页 UI：内置皮肤 + 自定义注入

站点是远端 SPA，HTML/CSS/JS 都在服务端，本地改不了源码。但**它渲染出来的样子可以改**——
用 `WKUserScript` 注入 CSS/JS，这是把我们自己那个桥注进去的同一套机制。

这里分三层，能改的程度不一样：

| 层 | 在哪 | 能改吗 | 怎么改 |
|---|---|---|---|
| **壳的原生 UI** | 工具箱、下载列表、启动页、进度线、橙色调 | ✅ 完全可控 | 改 `Core/Theme.swift` 和 `UI/*.swift`，重编译 |
| **站点整站外观** | 首页、周表、片单、剧集页 | ✅ 一键切换 | 工具箱 → 主题 → 深色 / 浅色 |
| **站点局部细节** | 任意元素 | ✅ 可注入覆盖 | 工具箱 → 外观 → 编辑样式与脚本 |

### 内置皮肤：两套介质（Dark 默认 / Light）

两套皮肤是**同一套结构的两种介质**，这一点是设计稿定下来的，不是实现上的偷懒：
`被关掉的是灯，不是结构`。Light 版的六条约束——一屏一焦点、海报优先、单一强调色、
留白建层级、海报承担全部色彩、3.2× 比例——在 Dark 里一条没动，换的只是承载它们的介质：

| 维度 | dark（默认） | light | 为什么这么定 |
|---|---|---|---|
| 画布 | 墨玉 `#0E0E10` | 纸白 `#FAFAF8` | 纯黑 `#000` 会让海报黑边和背景融成一片，层级彻底消失 |
| 卡片 | `#191A1D` + 1px `rgba(255,255,255,.07)` 描边 | `#FFFFFF` + 阴影 | 暗底上黑投影打在近黑面上等于没画，层级只能靠"卡片比画布亮" |
| 文字 | 暖白 `#F2F1ED` | 墨黑 `#12100F` | 纯白在暗底有 halation，小字尤其糊 |
| 强调 | 亮橙 `#FF6B42`，用途收紧 | 橙 `#FF5C35` | 同一块橙在暗底视觉重量约 1.6 倍，必须做减法：日期指示线改暖白、发送键不做实心橙 |
| 海报 | `brightness(.88)`，按下复原 `1` | 原亮度 | 暗底会把海报衬得过曝，六张一起喊就没了焦点 |
| 主按钮 | 暖白实心 + 墨字 | 墨黑实心 + 白字 | 暗底上"反白"才是行动色 |

实现只有两个文件：

| 文件 | 作用 |
|---|---|
| `Bridge/SkinPreset.swift` | 皮肤枚举 + 内联的 CSS/JS 常量（不做资源文件，避免动 pbxproj 的构建阶段） |
| `Web/ShellViewController.installCustomScripts` | **先皮肤、后自定义**：同一份注入串里皮肤在前，用户的规则天然压在上面 |

站点 DOM 用的是 `home-feed-card` / `watch-calendar-page-day` / `app-primary-bottom-nav` 这类**语义类名**，
不是纯原子类，所以覆盖是按"组件"写的，不是按"第几个 div"写的——改版时失效范围可控。

皮肤具体做了什么（下表列 light 介质的落地值，也是结构基准；dark 只是把表面与文字换成另一套色阶，
布局一列完全相同）：

| 站点元素 | 原样 | 皮肤之后 |
|---|---|---|
| 画布 / 卡片 / 分隔线 | `#0b1113` / `rgba(255,255,255,.06)` | `#FAFAF8` / `#FFFFFF` / `#E8E6E1` |
| 强调色 | 青 `#67E8F9` | 橙 `#FF5C35`，且只用于「更新」角标、选中下划线、今天 |
| 首页日期条 | 整块色卡 + 青色描边 | 无底色，选中是 2px 橙色下划线 |
| 首页剧集卡 | 横向滑动、图上压字 | 三列海报流，海报 2:3，标题/年份落在海报下方 |
| 「大家都在看」 | 148px 横滑卡片 | 三列网格 + 极轻角标（`更新` 才给橙色） |
| 首页顶部提示（热门影片 / 推荐输入） | 两段「标题 + chips」折行，共 4 行 / 336px | 合并为一行横滑，2 行 / 212px（首屏多露出 124px） |
| 周表 `/updates` | 圆角色块日期 + 分段胶囊 | 同款下划线指示器，卡片降为白底细边 |
| 底部导航 | 深色磨砂 + 青色选中环 | 纸白磨砂 + 墨色图标 + 选中橙色下划线 |
| 广告位 | 内嵌推荐位 | 隐藏（`movie-player-info-ad-*` / `movie-content-grid-ad`） |

#### dark 是 light 派生出来的，不是另写一份

结构只有一份（light 的 CSS 已经把整站按 BEM 类名重排过），dark 在 `SkinPreset.swift` 里由它生成：

```swift
private static let soujuDarkCSS: String = {
    let scoped = soujuLightCSS.replacingOccurrences(
        of: #"data-skin="souju-light""#, with: #"data-skin="souju-dark""#)
    return darken(scoped) + soujuDarkLayerCSS
}()
```

- `darken` 是一张 12 条的**色值映射表**（`background: #FFFFFF → #191A1D`、`color: #FFFFFF → #0A0A0B`、
  `rgba(250,250,248,α) → rgba(14,14,16,α)` …），只换表面与文字，不碰任何结构属性；
  顺序有讲究：`background-color: #FFFFFF` 必须排在 `color: #FFFFFF` 前面，否则会被子串规则截胡。
- `soujuDarkLayerCSS` 是手写的**介质层**（约 190 行）：令牌重映射、用描边重建层级、
  收紧橙色预算（日期指示线改暖白）、海报压 12% 亮度、把 light 的白磨砂按钮翻成墨磨砂。
- 好处：以后调布局只改 light，dark 自动跟上。代价：dark 独有的判断（"哪块橙该留"）
  必须集中写在介质层里，不能散落回结构里。

JS 同理只有一份模板 `skinJSTemplate`，三处占位 `__SKIN__` / `__THEME__` / `__DARK__`；
结构逻辑（今晚首选、只看未看过、路由跟随、状态栏取向）不重复实现，
所以深色和浅色的行为差异只有"切哪个 `data-theme`、挂不挂 `html.dark`"。

#### 默认深色 + 一个开关 + 一次迁移

- `ShellSettings` 默认 `souju-dark`；工具箱顶部「主题」是深/浅两枚按钮，
  点一下写偏好 → `applyCustomInjection()` 重建注入 → reload，登录态和播放进度都在站点侧，不受影响。
- 老安装里存的 `souju-light` 是**旧版本的默认值**，不是用户的选择：
  启动时若 `shell.skin == souju-light` 且没有 `shell.skinExplicit` 标记，一次性迁到 `souju-dark`。
  用户一旦在主题开关里点过，`skinExplicit` 置真，之后不再覆盖他的选择。
- 深色皮肤把状态栏切成浅色图标（`lightContent`）；短剧页仍然交回站点——那一页顶部就是视频画面，
  明暗不可控，深色图标和浅色图标都会有时候看不见。

**首页顶部信息浓缩（2026-11-06）**：站点把搜索提示做成两段「分组标题 + chips」并允许折行——
热门影片 7 个 chip 折成 3 行，推荐输入只有 1 个 chip 却独占 1 行；再加上搜索框的控制行
（`+` / 快速·智能 / 语音 / 发送），顶部一共吃掉 4 行 336px，等于首屏 40%。

压成一行的关键不是 `nowrap`（那只会把内容挤出屏幕），而是用 `display: contents` 把
两个 `[data-home-suggestion-group]` 盒子从布局里摘掉，让它们的子项（标题 + chip）直接成为
外层 `.movie-home-prompt-groups` 这个横向滚动容器的 flex item：

```css
.movie-home-prompt-groups { display:flex; flex-wrap:nowrap; overflow-x:auto; gap:8px; }
[data-home-suggestion-group] { display: contents !important; }   /* 盒子消失，子项上浮 */
[data-home-suggestion-group] > span { display: none !important; } /* 分组标题在单行里打断节奏 */
```

实测（iPhone 14 / 390×844）：提示条 164px → 40px（34px chip + 6px 留白），顶部 336px → 212px，
「本周追剧」从 y=605 提到 481。8 个 chip 一个不少：内容宽 778px、可视 366px，右缘自然裁掉半个 chip
暗示可滑。分组标题收起是有意的——`热门影片`/`推荐输入` 在单行里更像噪音，chips 本身自解释。

**短剧竖屏流也跟着变**（`/short-drama` 与 `/short-drama/<id>`）：早期版本把这两页排除在皮肤之外，
理由是"全屏视频用深色更稳"。实际用下来，从浅色首页点进短剧后整页突然变黑，观感是断裂的。
现在这两页跟着皮肤走——dark 介质下是墨玉底，切浅色则是纸白，不再和首页打架。
做法不是"把黑色改白/改墨"这么直白，因为站点在这三处是反着来的：

| 站点写死的地方 | 表现 | 皮肤怎么处理 |
|---|---|---|
| `.short-drama-video-stage` / `-slide-body` / `-feed-viewport` | 背景 `rgb(5,9,11)` | 全部改 `--paper`，视频仍 `object-fit: cover` 铺满 |
| `.short-drama-video-backdrop` + `-cover-layer` | 竖屏裁切后剩余的上下区域，用同一张图模糊放大再压黑 | 压黑改成**压纸**（`rgba(250,250,248,.58)`），模糊区与纸白画布接得上，不再是"雾霾灰" |
| `.short-drama-control-drawer-layer` | 选集/评论/换源/倍速抽屉带 `data-short-drama-theme="fixed"` + `data-theme="movie-dark"`，**站点主动钉死深色** | 在这一层上重映射 `--movie-*` 令牌（特异性高于站点的 `[data-theme="movie-dark"]`），抽屉内部不用逐个选择器 |

上表是 light 的解法；dark 介质层里同样的三处改成"压墨"——画布 `#0E0E10`、模糊区 `rgba(14,14,16,.72)`、
令牌重映射到暖白文字，抽屉那一层因为本来就是深色，反而只需要把令牌对齐到新的墨阶。

信息层（剧名 / 集数 / 热度 / 片单 / 查看更多）叠在视频画面底部，用一条 `to top` 的纸白渐隐
（`#FAFAF8 → 透明`）当底，文字随之转墨色；否则白字压在任意画面上都没法保证对比度。
dark 介质层把这层渐隐翻成墨色（`#0E0E10 → 透明`）、文字回暖白，逻辑对偶、代码不必重写。
右侧操作列是五个**没有类名**的按钮（纯 Tailwind），只能用 `.short-drama-control-dock > button`
按结构选；白磨砂底在亮画面里会"消失"，靠 `0 3px 16px rgba(18,16,15,.22)` 的阴影把边界兜住。
暗底上这一招失效（黑投影打在视频上没感觉），所以 dark 层改用**墨磨砂 + 1px 白描边**——
这也是整站"阴影换描边"那条原则唯一必须破例补描边的地方。

**状态栏这一页反而交回站点**：短剧页顶部就是视频画面，明暗完全不可控（可能是一张亮到发白的海报），
深色图标和浅色图标都会有时看不见。所以 JS 只在**非短剧页**主动设置状态栏——
dark 皮肤给 `lightContent`（暖白图标），light 皮肤给 `darkContent`（墨色图标）；
短剧页两套都保持站点自己的 `lightContent`，让图标融进画面而不是和画面打架。

其余页面照旧主动 `statusBar.setStyle(...)`，并在 1.2s / 2.6s 各补一枪——
站点渲染完会自己再调一次 `lightContent`，不补这一枪会被它盖掉。

改皮肤：直接改 `SkinPreset.swift` 里 `soujuLightCSS` 原始字符串（`#"""…"""#`，
首尾都不缩进，否则 Swift 多行字符串会报 insufficient indentation），重编译即生效。
**改 dark 不用碰新字符串**——布局类改动写在 light 里，dark 自动继承；
只有"暗底特有的判断"（哪块橙该收、哪个投影要换描边）才加到 `soujuDarkLayerCSS` 末尾。

### 两处结构性改造（不只是换颜色）

换肤改的是"长什么样"，下面两件事改的是"页面里有什么"。它们都写在皮肤 JS 里，
所以同样做到「改一次不用重编译」；但因为是往别人的 React 树里插节点，做法要克制：
**只插不删、只标属性不移除、挂了就重建**。

#### ① 首页「今晚首选」

首页内容顺序是：品牌 → 搜索框 → 继续观看 → 本周追剧 → 大家都在看。
卡片插在「本周追剧」之前（`document.querySelector(".home-watch-calendar").parentElement.insertBefore`），
成为第一条内容卡。

选片逻辑：

1. 遍历 `.home-watch-calendar-group`（电视剧 / 动漫 / …）；
2. 取该组第一条**不在** `playback-resume` 里的条目；
3. 全都看过就退回第一条，保证卡片永远有内容。

为什么跳过"在追的"：站点首页本来就有「继续观看」卡片，再推同一部等于重复推荐。
实测：续播记录里是《尚公主》时，卡片选的是同日更新的《走马上任》。

React 每次渲染都可能把这个外来节点带走，所以 `syncTonight()` 用 `data-souju-key` 记住当前卡片的身份
（`cal:<href>`），内容没变就只校正位置，变了才重建——避免每 200ms 闪一次。

#### ② 周表「只看未看过」

`/updates` 每张卡片都指向 `/player/<variantId>`，而站点的 `playback-resume` 里正好是这个 id。
两边一对，就有了"看过 / 没看过"的判定，不自己维护任何状态：

```js
var watching = {};                       // 站点续播记录里的 variantId
links[i].setAttribute("data-souju-seen", watching[id] ? "1" : "0");
```

筛选靠 CSS 完成，不动 DOM：

```css
html[data-souju-unseen="on"] .watch-calendar-page-item-link[data-souju-seen="1"] { display: none !important; }
```

这样做的好处是**不会和 React 抢节点**——隐藏是样式层的事，列表还是它原来那份。
按钮状态存在 `localStorage` 的 `souju:unseen-only`，下次进来还是你上次的选择。
一个副作用：站点头部的「电视剧 8 / 89 部」是它自己算的，不会跟着筛选变，
所以按钮旁边补了一句「已看过的 1 部已隐藏」把话说清楚。

### 自定义注入（皮肤之上的补丁）

改法：**工具箱（摇一摇）→ 外观 → 编辑样式与脚本**。保存后自动刷新，不用重编译、不用重签名。

### 站点 CSP 决定的硬约束（2026-11 实测）

```
style-src 'self' 'unsafe-inline'    → 内联样式放行，CSS 注入不会被拦
script-src 'self' https:            → 没有 unsafe-inline / unsafe-eval
```

由此得出三条，代码里都绕开了：

1. **不能用 `eval` / `new Function`**。没有 `unsafe-eval`，运行时求值会被 CSP 拒绝。
   所以用户脚本是**直接拼进函数体**执行的，不是 `eval("...")`。
   代价：语法错误会让整段脚本解析失败（`try/catch` 兜不住解析期的错），
   因此在原生侧先用 **JavaScriptCore 只解析不执行**做预校验，写错会当场弹提示。
2. **不能引外部样式表**。`style-src` 只有 `'self'`，CSS 一律内联成 `<style>`。
3. **不能插 `<script>` 标签**。同理，用户 JS 走 user script 通道，不走 DOM 插入。

### SPA 的两个坑，都处理了

- **路由切换不重载页面**，`atDocumentEnd` 只跑一次。
  - CSS：`MutationObserver` 守着 `<style>`，被站点重写 head 删掉就补回（节流 500ms）。
  - JS：监听 `popstate` / `hashchange` 重跑；同页内的 DOM 更新**不**重跑，避免重复绑定事件。
  - 也可手动触发：`window.__shellCustom.rerun()`。
- **选择器会随改版失效**。这是这套方案唯一无法预防的，所以配置存在本地 UserDefaults 里，
  改一条规则的成本是"打几个字"，而不是"重编译 + 重签名"。

### 怎么找到正确的选择器

手机连 Mac → Safari → 开发 → 你的 iPhone → 搜剧 → 元素检查器。
工程里已经在 iOS 16.4+ 上打开了 `isInspectable`（用 KVC 探测，低版本 SDK 也不会编译失败）。

### 验证过的

| 项 | 结果 |
|---|---|
| CSS 往返无损（换行 / 引号 / 反斜杠 / 中文 / U+2028） | 10/10 通过 |
| `<style>` 插入、被删后补回、空内容不注入 | 通过 |
| 用户脚本执行、`popstate` 注册、`rerun()` 可重跑 | 通过 |
| 模拟器实战：注入 `body::after` 橙色横幅 | **截图确认生效**，覆盖在站点页面上 |
| 语法校验：`var x = ;` | 正确报 `SyntaxError: Unexpected token ';'` |

清除方式：编辑器里点「清空」，或关掉「启用自定义注入」开关——关掉后壳只注桥，页面回站点原样。
这个开关也是排障用的：某个问题如果关掉自定义样式就消失，那它就是样式造成的。

---

## 7. 已知限制

1. **`download.enqueue` 的入参形状没拿到**。它由懒加载路由 chunk 构造，静态分析够不到。壳的做法：递归扫描 payload 里所有像媒体地址的字符串（`.m3u8` / `.mp4` / `/hls/` / `playlist`）全部接下，并把**原始 payload 全文写进了 `bridge.log`**。真机上点一次下载，「文件」App 里把 `bridge.log` 拉出来，看一眼就能把字段名钉死——不需要重新逆向，也不需要连 Mac。
2. **域名轮换**是长期风险。站点一换域名，壳就白屏。缓解：多线路 + 工具箱里手填新域名（不需要改代码、不需要重新签名）。
3. **原生播放器未实现**，H5 播放器的代价是：投屏只能靠系统 AirPlay 面板，画中画只有下载内容才有。
4. **原生登录未实现**（`auth.*` 回 NOT_IMPL）。站点自带的 web 登录不受影响；但如果你以后发现"官方 App 才能用的功能"缺失，根因大概率在这。
5. **免费证书 7 天**，这是 Apple 的规则，工程侧解决不了。
6. **「未看过」以站点续播记录为准**。没看到一半就退出的，如果站点没写 `playback-resume`，就算"没看过"。
   好处是不用自己维护状态、换设备也一致；坏处是判定精度受站点限制。
7. **「今晚首选」依赖首页日历结构**（`.home-watch-calendar-group` / `-item` / `-item-copy`）。
   站点改版这几个类名就失效，卡片会消失——不会报错，只是没了。
8. **浅色的短剧页白磨砂按钮是"借"对比度**。按钮落点取决于视频画面本身，遇到接近纯白的镜头时，
   白底按钮只剩阴影描边可辨。要彻底解决得给按钮加一层墨色描边或改回半透明墨底，
   但那会破坏整站纸白的统一感——目前选择保留统一感。（深色皮肤已改用墨磨砂 + 白描边，没有这个问题。）
9. **短剧页上下模糊区是压色不是消除**。横屏内容在竖屏里够不满时，上下会露出同一张图的模糊放大版。
   皮肤把它压到 58% 纸色（深色皮肤压到 72% 墨色），肉眼是"淡淡的水彩"，不是纯粹的画布色。
10. **方向补正只处理一个方向**。设备竖持、界面卡横屏会被补正；反过来（界面竖屏、设备横持）
    故意不管，因为那多半是用户开了竖屏锁定。另外它依赖 `UIDevice.current.orientation`——
    手机平放（`faceUp`/`faceDown`）时方向不可信，此时不做判定。
11. **深色是派生的，所以"深色专属"必须有纪律**。任何只在暗底成立的微调都要写进 `soujuDarkLayerCSS`；
    图省事塞回 `soujuLightCSS` 里，浅色会被一起改坏。反过来，布局改动只写 light 一份，
    别在介质层里重复结构——否则以后调一次布局要改两处，派生策略就白费了。

---

## 8. 怎么调试

桥日志有三路输出，按"现场 / 事后 / 深度"分工：

| 路 | 怎么看 | 用途 |
|---|---|---|
| App 内 | 摇一摇 → 桥日志 | 现场看，最近 300 条 |
| **文件** | 「文件」App → 我的 iPhone → 搜剧 → `bridge.log` | 事后全文，1MB 封顶自动截断 |
| 系统日志 | `log stream --predicate 'subsystem == "com.wuxiaogang.soujushell"'` | 连 Mac 时实时看 |

（`Documents` 已通过 `UIFileSharingEnabled` 暴露给「文件」App，也能用 Finder 直接拖出来。）

- **远端调试**：手机连 Mac，Safari → 开发 → 你的 iPhone → 搜剧。能看到网页 console 与 DOM。
- **改线路**：`Core/ShellConfig.swift` 的 `builtinDomains`，或运行时在工具箱里加。
- **关掉下载能力**：工具箱 → 离线下载开关。关掉后站点自动隐藏下载入口，用于判断"某个问题是不是下载模块引起的"。
- **模拟器里开工具箱**：模拟器没有摇一摇也没有双指下滑，DEBUG 版支持启动参数直开——
  `xcrun simctl launch <device> com.wuxiaogang.soujushell -souju-toolbox 1`。
- **绕过 UI 直接改皮肤**：`xcrun simctl spawn <device> defaults write com.wuxiaogang.soujushell 'shell\.skin' souju-dark`
  （键名里的点要转义，否则 `plutil`/`defaults` 会当路径解析）。改完必须 `simctl terminate` 再
  `simctl shutdown/boot`，否则进程带着旧偏好继续跑，会误判"改了没生效"。

---

## 9. 目录

```
SoujuShell/
├─ App/      SoujuShellApp.swift          入口
├─ Core/     ShellConfig（配置+偏好）/ ShellModel（状态）/ Theme（设计令牌）
│           RotationGuard（横屏→竖屏残留补正）
├─ Web/      ShellViewController（WKWebView 宿主）/ WebContainer
├─ Bridge/   BridgeScript（注入桥 JS）/ NativeBridge（RPC 路由）
│           CustomInjection（自定义 CSS·JS）/ SkinPreset（内置皮肤常量）
├─ Download/ DownloadManager（HLS 引擎）/ DownloadModels / OfflinePlayerController
├─ UI/       RootView / ToolboxView / DownloadListView / CustomStyleView（外观编辑器）
└─ Support/  Info.plist

tools/
├─ activate-xcode.sh   接受许可 + 切工具链 + 装首次启动组件（只需一次，要 sudo）
├─ build.sh            编译（--sign / --archive）
├─ make-ipa.sh         打包 ipa（ad-hoc 签名）
├─ install-from-xip.sh 从 Xcode_14.2.xip 解压安装到 /Applications（换机时用）
└─ setup-xcode.sh      用 xcodes 走命令行下载（Apple 已关这条通道，留作记录）

docs/preview.html      界面预览（浏览器直接打开）
docs/shots/            实跑截图（skin-dark-* 为深色介质，skin-home-compact-* 为首页浓缩）
```

---

**免责声明**：本工程仅用于个人设备上的技术验证。目标站点是聚合影视站，其内容版权状态未经验证，工程本身不包含、不缓存、不分发任何内容。使用者应自行评估所在司法辖区的法律风险。不提供任何规避平台审核或版权监管的能力。
