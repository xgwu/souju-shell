# 搜剧 AI 电视版 · 阶段 1~10 工程

**当前状态**：`0.10.3` / build 18 / 388KB —— WebView 壳 + 遥控器焦点引擎 + TV 版式皮肤 +
手机扫码输入 + 原生播放器 + 选集面板 / 进度回写 / 登录入口 / 远程线路配置 +
首屏揭幕门 / 下划线导航 / 紧凑主推条 / 首屏排序 / 焦点放大 / 滚动补间 +
首屏取舍（只留继续观看 + 海报墙）/「追剧」菜单 / 点海报直进全屏播放器 +
**自建签名通道（点海报 1.5 秒起播）** + 选集焦点态与「当前集」分层 +
**播放器 bar 自动隐藏 / 上键回首屏不跳菜单 / 导航下划线跟随焦点 / AI 搜索修复** +
**焦点去橙框 / 继续观看列表即时刷新**，
已装进雷鸟鹤7 Pro 75R675C 实机验证。
自签名证书 30 年有效，装一次永久可用，没有 iOS 版那套 7 天续签。

首屏实机截图：`docs/tv-stage8-home.png`（阶段 8 首屏）、
`docs/tv-stage8-updates.png`（「追剧」周表页）、`docs/tv-stage8-directplay.png`
（点海报后的起播遮罩）、`docs/tv-stage7-focus.png`（海报获焦）；阶段 3 / 7 的旧图保留做对比。
选集面板三张（阶段 9.1，原生面板是普通 View，截得到）：
`docs/tv-stage9-sheet-focus.png`（焦点＝当前集第 4 集）、
`docs/tv-stage9-sheet-moved.png`（焦点移到第 6 集，第 4 集橙底已去掉、只剩描边）、
`docs/tv-stage9-sheet-after-pick.png`（换集后重开，`当前 第6集`）。
阶段 10 三张：`docs/tv-stage10-nav-focus.png`（导航焦点态：白字 + 下划线，无橙底）、
`docs/tv-stage10-nav-moved.png`（下划线跟着焦点走到「追剧」）、
`docs/tv-stage10-player-bars.png`（按 OK 后顶栏剧名 + 底栏按键说明重新出现）。
完整方案与实测数据：`docs/tv-feasibility.md`、`docs/tv-webview-capabilities.json`。

## 目录

```
tv/
├── AndroidManifest.xml                  minSdk 21 / targetSdk 30 / 双 LAUNCHER category
├── res/values/strings.xml               app_name = 搜剧TV
├── res/mipmap-mdpi/ic_launcher.png      192×192，由 tools/make-tv-icon.py 生成
├── libs/zxing-core-3.5.3.jar            只用 QRCodeWriter 生成二维码（Maven Central）
├── assets/
│   ├── bridge.js                        documentStart 注入：RPC 桥 + 环境标记 + polyfill（含 replaceChildren）
│   ├── focus.js                         焦点引擎：候选集 / 轴向最近邻 / 宽元素特例 / 卡片放大 / rAF 滚动补间 / 浮层焦点域
│   ├── focus.css                        焦点环样式（Chrome 83 基线）
│   ├── tv-skin.css                      TV 版式：1200px 全宽 / 6 列网格 / 深色令牌 / 下划线导航 / 等高占位 / 追剧页 / 起播遮罩
│   ├── tv-skin.js                       data-* 标记 / 首屏排序 / 占位 / 今晚首选卡 / 就绪上报 / 锚点自检 / 追剧菜单注入
│   ├── tv-overlay.js                    顶部工具栏（搜索/选集/登录/扫码/原生播放）+ 浮层 + 手机输入回传 + 媒体嗅探 + 进度回写 + 直通播放
│   ├── input-page.html                  手机扫码后的局域网输入页（由 LocalInputServer 提供）
│   ├── error.html                       两条线路全挂时的错误页
│   ├── probe.html                       阶段 0 能力探针（保留）
│   └── security-probe.html              桥令牌隔离验证页
├── src/com/wuxiaogang/soujutv/
│   ├── MainActivity.java                宿主、按键路由、全屏、failover 编排、揭幕门门控
│   ├── RevealGate.java                  揭幕门：setAlpha(0) 藏起未上皮肤的页面，JS 就绪后 160ms 渐入（8s 超时兜底）
│   ├── LoadingSplash.java               揭幕期间的品牌加载页（搜剧TV + 正在加载… + 橙色进度条）
│   ├── ShellConfig.java                 线路、可信 host、UA、常量
│   ├── NativeBridge.java                RPC 路由 + 令牌校验 + 能力上报 + playNative/setOverlay
│   ├── TvWebViewClient.java             导航边界、注入挂钩、失败上报
│   ├── TvChromeClient.java              全屏回调、控制台（含 `SOUJUTV SKIN_READY` 零延迟捕获）、进度兜底
│   ├── TvFocusEngine.java               注入器 + 按键映射 + 皮肤/浮层注入 + VERIFY 自检
│   ├── QrGen.java                       ZXing 生成 WiFi 配网二维码 PNG（data URL）
│   ├── LocalInputServer.java            8088 端口局域网 HTTP：配对码隔离 + /api/send 回传 + /api/config 线路下发
│   ├── PlayerActivity.java              系统 MediaPlayer + SurfaceView 原生播放器 + 选集面板 + 退出回传进度
│   ├── TvConfig.java                    远程线路配置：拉 JSON → 校验 → SharedPreferences，`--es config off` 可清
│   └── BridgeLog.java                   logcat + 落盘双写
└── build/                               构建产物（gitignore）
```

开发期工具（都在 `tools/`）：`tv-skin-preview.py` 通过 CDP 把本地皮肤注入
正在运行的 WebView 并截图，**改 CSS 不用重装**；`tv-cdp.py` 是通用的实机 JS 执行 /
几何量取工具（纯标准库 WebSocket 客户端，Chrome 83 只回整数 id，`--await` 可等 Promise）。

**仍然不用 Gradle**：13 个 Java 类 + 一个 zxing jar，`aapt2 → javac → d8 → zipalign → apksigner`
两秒出 364KB APK，改一行立刻装机实测。播放器实测系统 `MediaPlayer` 足够
（直链 mp4 / Range 拉流），ExoPlayer/media3 的收益只剩 DASH/DRM，不值得引入。

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
| OK / Enter | `click()` 当前焦点；搜索输入框里按下 = 提交搜索 |
| 返回 | 浮层打开 → 关浮层、焦点还给来源图标；否则回退站内历史；无站内历史时 2 秒内两次退出 |
| 菜单 | WebView 内切线路；原生播放器里显示/隐藏控制条 |

**原生播放器内**：OK 播放/暂停、左/右 ±10s、上/下 音量、菜单 唤出/收起**选集面板**（8 列/行、
当前集自动获焦）、返回 退出并把播放位置回传给站点「继续观看」。
播放期间 `FLAG_KEEP_SCREEN_ON`，不会进屏保（实测无此 flag 时 8 分钟即被 Dreaming 暂停）。

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

# 远程线路配置：先登记地址（持久化），之后每次启动自动拉；用 off 清掉
adb shell am start -n $PKG --es config "https://example.com/tv-config.json"
adb shell am start -n $PKG --es config off

# 桥令牌隔离验证：应看到 3 条 REJECT、无 capabilities 回包
adb shell am start -n $PKG --es url "file:///android_asset/security-probe.html"

# 关闭 TV 皮肤做 A/B 对比（不重装、不清数据；去掉该参数即恢复）
adb shell am force-stop com.wuxiaogang.soujutv
adb shell am start -n $PKG --es tvskin off

# 关掉揭幕门（加载页 + 渐入）：直接看未上皮肤的原始首屏，用来对比「闪一版」
adb shell am start -n $PKG --es gate off

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
| `reveal` | 揭幕门：`HIDE seq=N`（藏起）→ `JS_READY` / `SHOW js_ready` / `SHOW timeout_8000ms` / `SHOW failed` |
| `SKIN_PART` | 首屏各块挂载时间线（`SOUJUTV SKIN_PART feedTrack:true t=4083`），用于定位「闪一版」到底哪块晚了 |
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

### 阶段 4+5 追加验证（2026-11-07 14:35，鹤7 Pro 75R675C）

| 项 | 结果 |
|---|---|
| 构建 / 安装 | `0.6.0` / 352KB（含 zxing），v1+v2+v3 通过 |
| **焦点环残留** | 遍历 12 键后全页 `data-tv-ring` = 1（只有当前焦点），站点自身的橙色 `:focus` 被覆盖 |
| **海报获焦** | 获焦后图片 196×296 完整可见（修掉 `scale` + 站点 `overflow:hidden` 联动裁切） |
| **热词行** | 首页「热门影片 / 推荐输入」两行 chips 隐藏，首屏让给海报墙 |
| **搜索图标 + 浮层** | 常驻大搜索框隐藏；右上角搜索图标 → OK 开自建浮层（默认聚焦输入框）→ BACK 关浮层焦点还给图标 |
| **手机扫码输入** | 二维码渲染正常；`/api/send?k=6688` → 电视 100ms 收到 `tv.remoteInput`；无/错配对码 403 |
| **媒体直链发现** | `video.duration>0` 即可信：识破 `.jpg` 伪装的 532MB mp4 直链（`ftyp isom`） |
| **原生播放** | H5 20:46 续播 → 1s `PLAYING duration=2890120`；OK/±10s/音量/MENU/BACK 全部生效；错误流正确报 `MEDIA_ERROR` |
| **屏保修复** | 播放器加 `FLAG_KEEP_SCREEN_ON`；onPause 停 500ms 进度轮询，onResume 恢复 |
| **换集全链路** | `EPISODE_PICK 7` → `RETURN pos=337541 ep=5 pick=7` → `TVEPISODE 第8集` → `resolved .../axkVJBEe/index.m3u8` → `PLAYER_OPEN ep=7/15` → `PLAYING duration=1468250` |
| **进度回写** | `TVPROGRESS {synced:32}`；resume 存储首条变 `["走马上任","第8集",32]`，预览键同步 |
| **登录入口** | 手机推账号 114ms、密码 74ms → 自动提交 → 失败态文案正确（假账号属预期） |
| **远程配置** | LAN 推送 `v9 lines=3 changed=true`；重启仍生效；公网 `CONFIG_FETCH 200 → APPLIED v11`；`--es config off` 清理成功 |

## 已知限制

1. `auth.getState` / `auth.restoreSession` 回 `NOT_IMPL` 是**刻意的**：站点靠 `capabilities.actions`
   里有没有 `auth.*` 判断原生登录态同步是否支持，不报即回退 web 登录态。
2. 远程配置需要在外部托管一份 JSON（`ShellConfig.REMOTE_CONFIG_URL` 留空即不主动拉），
   否则只能用 `--es config` 或手机页 `/api/config` 手工下发。
3. adb 截屏拍不到原生播放器的视频层（MTK overlay 限制），画面取证依赖日志与音频状态。
4. BACK 退出播放器后 WebView 焦点在 body，需按一次方向键重新聚焦（可用性小项）。
5. Chrome 83 五个失效 CSS 特性（flex `gap` / `aspect-ratio` / `:has` / `:focus-visible` /
   `inset`）已全部避开，后续改皮肤要守住这条基线。
6. 冷启动第一下 DOWN 落点是导航的「首页」（引擎从第一个候选起步，页面初始没有焦点），
   第二下才到「今晚首选」。不影响使用，但第一下看起来「没动」。
7. 站点首页数据本身要 7~10 秒才齐（继续观看 7.6s、海报真卡 7~10s）。
   占位只保证**位置**不跳，内容仍会陆续填进来 —— 想更快只能预取站点接口，属于改站点侧的事。
8. 点海报到起播：`0.9.1` 起 **1.16~2.60 秒**（自建签名通道，不再等站点播放器 UI）。
   兜底路径仍是 12~14 秒（站点详情页解析线路的固有耗时）；两条都失败才走原来的
   10~28 秒。超过 1 分钟只会换提示（按返回可退出），3 分钟仍无地址才退回详情页。
9. **签名密钥是从站点前端 chunk 逆向来的**（`f39d73aa…e79d`），不是公开 API。
   站点发版换密钥或改 `x-ai-movie-build-version` 时自建通道会 401，
   表现是自动降级到兜底路径（变慢，不会白屏），此时需要重新核对 chunk 更新密钥。
10. 自建通道会让**每个片子的 `/v1/*` 请求量翻倍**（站点自己的请求照发，我们并行再取一份），
    换集时也如此；目前站点无限流迹象，但属于「借来的通道」，不保证长期可用。
11. 换集 5.1 秒里 **2.4 秒是故意等的**：要让 H5 播放器先把进度回写（`TVPROGRESS`），
    否则新集从 0 开始、旧集进度丢失。纯解析只占 2.5 秒，想更快得改进度回写策略。
12. 冷缓存下 chunk 预热（`<link rel=prefetch>`，首页 5 秒后最多 40 条）只省 0.39 秒
    （14.49s vs 14.10s）—— 瓶颈从来不在 chunk，而在等站点发 `resolve`。
    这段代码保留是为了暖二跳，不作为主要收益。
13. **`epList` 不能跟着 pathname 变化清空**（`0.9.3` 已修，见「阶段 9.1」）：
    直通播放时清单是自建通道在首页填好的，站点随后才 SPA 跳到 `/player/xxx`。
    一清空，播放器里的换集就取不到那一集（`TVPICK eps:0`），遮罩永久停在
    「正在切换剧集」。以后判断「是否换了片子」只能用 `collectEpisodes()` 有没有
    新列表，不能用路径。

## 下一步

阶段 0~9 全部收口：看片、搜索、输入、播放、换集、进度记忆、登录、远程换域名、
首屏不闪版、点海报一步进播放器、点海报 1.5 秒起播，都已实机可用。
再往下是「锦上添花」：站内评论区/片单的电视版式、播放器画质与音轨切换、
换集再压 2 秒（把进度回写改成异步上报）、跨设备继续观看（同一账号多终端进度同步，
站点已提供接口但电视端没接）。

## 手机扫码输入（阶段 4）

启动 App 时 `LocalInputServer` 监听 `0.0.0.0:8088`，生成 4 位配对码并画成二维码。
点顶部工具栏的扫码图标（或搜索浮层里的「手机输入」）看到二维码，手机同一 WiFi 扫码打开
`http://<TV IP>:8088/?k=<配对码>`，输入文字点发送 → 电视 100ms 内收到、自动填入搜索框提交。

- **配对码隔离**：`/api/state`、`/api/send` 都必须带正确的 `k`，实测无 `k` / 错 `k` 一律 403；
- **回传链路**：`LocalInputServer` → `MainActivity`（main handler）→ `emit tv.remoteInput`
  → `tv-overlay.js` 用 React 受控组件的原型 setter 写值（直接赋值不触发站点 state）；
- 电视静膜/息屏不影响服务；App 被杀即停，无后台驻留。

## 原生播放器（阶段 5）

播放页顶部工具栏出现「原生播放」按钮（媒体直链就绪时自动显示），点击后：

1. `tv-overlay.js` 把 `video.currentSrc`（哪怕扩展名是 .jpg，见下）+ 当前进度交给
   `playback.playNative`；
2. `PlayerActivity` 用系统 `MediaPlayer` + `SurfaceView` 起播（带站点 UA/Referer 头），
   `seekTo` 到 H5 播放进度续播；
3. 遥控器全部接管（见按键表），BACK 回 WebView。

**关键实测发现（2026-11-07）**：站点把整部 mp4 存在 `.jpg` 路径下伪装 ——
CDN 回包 `content-type: image/jpeg` 但字节是 `ftyp isom/avc1`（532MB、支持 Range），
`video.currentSrc` 长得像封面图却在正常播放。所以媒体直链的判据是
**`video.duration > 0` 即可信**，绝不能按扩展名过滤（会误杀真直链、放过占位图）。
fetch/XHR 嗅探只作为 hls.js/MSE 场景的兜底。

已验证：H5 进度 20:46 续播、1 秒 prepared、48:10 时长、OK/±10s/音量/菜单/BACK 全部生效、
错误流（网络不可达）正确弹 `MEDIA_ERROR` 文案。屏幕本体画面正常；**adb 截屏视频层是黑的**
（MTK 对硬件 overlay 层的截屏限制），取证看 `player:` 日志与音频 `state:started`。

## 阶段 6：选集 / 进度回写 / 登录 / 远程配置

### 选集

- **H5 侧**：工具栏第二个图标（只在有剧集时出现）→ 自建 8 列网格浮层，当前集带 `is-current`；
  站点默认只挂 15 个「快速集」，需要时会自动点一次站点的展开按钮取完整目录。
- **原生侧**：播放中按 **菜单** 拉出底部选集面板（8 列/行，当前集高亮并自动获焦、超出屏高
  内部滚动）。选中后 `setResult(episode, pick)` 回 WebView，H5 先把这个集的进度写回站点，
  2.4 秒后再点站点对应集并重新拉起原生播放器。
- 换集实测要等 ~11 秒：这是站点自己拿到新 playlist 的时间（`TVEPISODE resolved afterMs=11281`），
  不是壳在等。等待期间 H5 `<video>` 被静音，避免网页和原生双声道。

### 播放位置回写「继续观看」

原生播放器用的是系统 `MediaPlayer`，站点看不到 `timeupdate`，「继续观看」会停在进播放器前的秒数。
退出/换集时把 H5 `<video>` **静音 seek 到目标位前 2 秒、真播 2.1 秒**，借站点自己的 recorder 落库
（`TVPROGRESS` 日志 + `movie-search:v2:playback-resume:owner:guest` 首条即更新）。

### 登录入口（手机输入）

站点只有账号+密码表单，电视上没法打字。工具栏「账号」图标打开自建浮层：右侧二维码 + 左侧字段，
遥控器 OK 选中「手机输入账号 / 密码」，手机扫同一二维码输入 → 文字落进字段 → 两项齐了自动提交。
字段值走 React 原型 setter 写入，否则站点 state 不更新。

### 远程线路配置

站点域名会轮换，重装 APK 在电视上很痛苦。两种下发方式：

```bash
# ① 公网托管：登记一次地址，之后每次启动自动拉取（带 ETag）
adb shell am start -n com.wuxiaogang.soujutv/.MainActivity \
  --es config "https://example.com/tv-config.json"

# ② 家庭局域网：手机页「线路配置」区块，或 curl 直接推
curl -X POST -H "Content-Type: application/json" \
  -d '{"version":9,"lines":["https://souju.ai","https://hctd4.com"]}' \
  "http://192.168.0.4:8088/api/config?k=<配对码>"

# 清掉远程地址（已应用的线路保留）
adb shell am start -n com.wuxiaogang.soujutv/.MainActivity --es config off
```

JSON 格式（未识别的字段一律忽略，网络失败静默回落到内置线路）：

```json
{ "version": 9, "lines": ["https://souju.ai", "https://hctd4.com"],
  "trusted": ["bpz2.com"], "notice": "换域名说明", "minBuild": 6 }
```

版本号不高于本地时不覆盖，最多 8 条线路。日志看 `CONFIG_FETCH / CONFIG_APPLIED / CONFIG_STATE`。

## 阶段 7：首屏体验六项

用户实机提的六条观感问题，逐条落地（根因与数据见 `docs/tv-feasibility.md` §0.7）：

| 问题 | 改法 |
|---|---|
| 打开时「初始首页布局一闪再刷新」 | **原生揭幕门**（`RevealGate` + `LoadingSplash`）：WebView 先 `alpha=0`，JS 上报 `SOUJUTV SKIN_READY` 后 160ms 渐入。就绪信号走 console 而不是 `evaluateJavascript` 轮询 —— 这台机器上回包延迟能到 1.6 秒 |
| 菜单选中用色块，观感重 | 只留 3px 橙色下划线，`min-width:0` 让线贴住文字；站点的 1px 青色四边框也压成透明 |
| 「今晚首选」占满一屏且糊 | 148→116px：背景换同图 `blur(26px)` 遮掉放大痕迹，前景改 64×96 竖版缩略图（原图 420×600 恰 2:3） |
| 继续观看 / 本周追剧被挤到最底 | `order` 重排：今晚首选 0 / 继续观看 1 / 追剧日历 2 / 海报墙 3 / 加载更多 4；日历按方案 B 只留 7 天日期条 |
| 获焦几乎看不出来 | 放大对象从内层链接换成**卡片外壳**（`cardOf()`），`scale(1.10)` → 190→209px，`.14s` 过渡，焦点环 + 外发光 + 投影一起写 |
| 上下滚动是瞬间刷新 | rAF + easeOutCubic 补间 **150–330ms**（这台机器约 25–30fps，330ms≈9 帧才看得出滑）；新按键从当前 `scrollTop` 续接目标 |

关键一条：**「闪一版」的成因是两次位移，不是两次渲染**。站点先画骨架，再陆续挂
「继续观看（184px）」「追剧日历（118px）」「今晚首选（126px）」，每挂一块就把海报墙顶下去。
所以除了揭幕门还做了等高占位（`.tv-ph` + `[data-tv-tonight-host] min-height`），
真块到位后同位替换 —— 实测 5 秒与 13 秒的「继续观看」都在 y=208，全程零位移。

**验收后又修的三处**（`0.7.1`）：横幅按 DOWN 会跳过整排继续观看（宽条改为纵向距离优先）、
宿主标记晚了 8 秒导致揭幕后仍下移 102px（改为从热词组父节点提前标记）、
「首页」上那圈查不到 CSS 来源的橙框（WebView 系统 default focus highlight 残留，
`setDefaultFocusHighlightEnabled(false)`）。

### 阶段 7 实机验证（2026-11-07 17:5x，鹤7 Pro 75R675C）

| 项 | 结果 |
|---|---|
| 构建 / 安装 | `0.7.1` / build 8 / 364KB，v1+v2+v3 通过，`adb install -r` 579ms |
| **揭幕** | `HIDE seq=1` → `JS_READY` → `SHOW js_ready`（冷启动 PAGE_START→揭幕 ≈ 4.0s，此前是等满 8s 超时） |
| **零位移** | 5s：宿主 126px、继续观看占位 y=208；13s：真块 y=208、占位已撤、海报标题 y=553 |
| **首屏预算** | 导航 66 / 主推条 116 / 继续观看 184 / 日历 118 / 海报第一行 y≈598 |
| **焦点路径** | 导航 → 今晚首选 → 继续观看 → 日历 → 海报墙；海报墙内连按 DOWN 同列换行（x 恒 638），`ring=1 / parent=1` 无残留 |
| **焦点放大** | 卡片 `matrix(1.10,…)`，190→209px；横幅 `matrix(1.012,…)`（1200 宽不能 1.10） |
| **滚动补间** | `scroll` 事件 3 个采样点 `[60356,1201] [60451,1250] [60532,1253]`，有渐变非一步到位 |
| **导航选中态** | 只有 3px 下划线，`border-top/left/right` 透明，`outline 0` |
| 站内跳转 | 点片进 `/player/...` 不套揭幕门（日志无 HIDE/SHOW），返回首页正常 |

## 阶段 8：首屏取舍 + 「追剧」菜单 + 直通播放

三条来自实机观感的改造（根因与全部数据见 `docs/tv-feasibility.md` §0.8）：

| 需求 | 改法 | 关键实现 |
|---|---|---|
| 首屏去掉「今晚首选」「本周追剧」 | `display:none` 掉 `[data-tv-tonight]` / `[data-tv-tonight-host]` / `[data-tv-late]` / `.tv-ph-late`；JS 侧 `SHOW_TONIGHT=false`、`PH_KEYS=['resume']`；继续观看改 5 列只露前 5 条 | 首屏 = 导航 66 → 继续观看 184 → 「大家都在看」y≈265 → 海报第一行 y≈296，完整两行海报 |
| 主菜单加「追剧」 | `navExtra()` 往 `nav.app-primary-nav-desktop` 插 `.tv-nav-updates`（`href=/updates`），点击走 `history.pushState` + 手工 `PopStateEvent` | 站点自己的 SPA 路由接手，**不触发整文档加载**（`PAGE_START` 计数 0）；页内样式挂在 `html[data-tv-page="updates"]`，广告块全隐藏、卡片 148px / 标题 23px / meta 16px |
| 点海报直进沉浸式全屏播放器 | `tv-overlay.js` 的「直通播放」：点海报盖一层全屏起播遮罩（海报背景 + 片名 + 进度条），站点照常在遮罩下面 SPA 进详情页；`currentMedia()` 一拿到地址立刻开原生播放器；退出时 `history.back()` 回首页 | 播放器原生选集面板照旧可用，`pick` 回来走 `__tvSyncThenPick`，6~7 秒重新起播，全程没有详情页出现在用户眼前 |

**四个必须记住的实现细节**：

1. 遮罩的 `z-index` 必须是 `2147483002` —— 站点详情页自己的起播层是
   `2147483000`，用 90 会被整块盖住，用户看到的是站点那句「精彩即将开始」。
2. 遮罩**不能用 `filter: blur()`**：全屏模糊每帧重栅格化，会把遮罩下正在解析的
   详情页从 11 秒拖到 30 秒以上。用 `opacity:0.55 + scale(1.08)` 代替。
3. 起播判据必须和工具栏「原生播放」一致（`currentMedia()`，即 `video.duration>0`），
   因为站点把 mp4 藏在 `.image` / `.jpg` 路径下伪装；但**还要加新鲜度闸门**
   （`mediaSeq` + 元素/地址比对），否则 SPA 换页后残留的 `<video>` 会让你播上一部片。
4. 起播等待期间按返回要能取消：主线程被详情页解析占满时 BACK 会排队数秒才派发，
   实测和 `TVDP_START` 只差 93ms。`popstate` 里判「回首页」即 `dpReset()`。
5. **遮罩是会话级的，不是起播级的**（`0.8.1`）：从点海报一直挂到回到首页，
   `playing` 阶段也不撤 —— 播放器是独立 Activity，会整块盖住 WebView，留着它
   换来「换集回来零闪烁」。早期那版「10 秒没地址就撤遮罩」正是用户看到的
   「缓冲中跳回详情页」，已删除。
6. 换集阶段禁止 `dpTick` 抢起播（交给 `pickEpisode` 自己带集号起播），否则旧集
   换个 HLS 变体地址（`index.m3u8` → `3000k/hls/mixed.m3u8`）就能骗过新鲜度判断，
   实测会先黑屏播回旧集、4 秒后新集才盖上来。

### 日志（直通播放）

| 日志 | 含义 |
|---|---|
| `TVDP_BEGIN {"title"}` | 点了海报，遮罩已挂上，开始轮询 |
| `TVDP_START {"src","note","waitedMs"}` | 拿到直链交给原生播放器；`note` = `resolve`（首播）/ `pick`（换集） |
| `TVDP_SWITCH {"label"}` | 播放器里换集/下一集，遮罩切回「正在切换剧集…」 |
| `TVDP_EXIT {"reason"}` | 播放器退出，遮罩换「正在返回首页…」，2.6 秒后 `history.back()` |
| `TVDP_CANCEL {"note","phase"}` | 会话收尾（`popstate` 落地首页 / 用户中途返回 / 路径被改） |
| `TVRESUME {"note","title","step"}` | 继续观看列表核对/刷新：`fresh`（一致）/ `detour`（路由绕行）/ `reload`（整页刷新）/ `giveup-*`（放弃原因）；见「0.10.3」 |
| `TVDP_SLOW` | 超过 60 秒仍没地址，提示换成「线路较慢…（按返回可退出）」，**不撤遮罩** |
| `TVDP_TIMEOUT` | 3 分钟仍解析不出，才退回详情页 |

### 阶段 8 实机验证（2026-11-07 18:5x，鹤7 Pro 75R675C）

| 项 | 结果 |
|---|---|
| 构建 / 安装 | `0.8.0` / build 9 / 368KB，v1+v2+v3 通过 |
| **首屏** | 导航「首页,追剧,短剧,历史,片单」；继续观看 5 卡一行 y≈106~242；海报第一行 y≈296（两行可见） |
| **追剧页** | `data-tv-page="updates"` 生效，广告块消失；滚动容器 `.watch-calendar-page-content`（1693/574），焦点引擎 `reveal()` 自动接管（`st=468 / ring=1`） |
| **直通播放** | `TVDP_BEGIN` → `TVDP_START note=resolve 13695ms` → `PLAYER_OPEN ep=0/8`；13 秒时抓图仍是「正在解析线路… 13s」，**不再回退详情页** |
| **换集** | 面板 `pick=1` → `TVDP_SWITCH` → 3 秒时抓图「正在切换剧集… 3s」→ `TVPROGRESS {synced:17}` → `TVEPISODE afterMs=6976` → `TVDP_START note=pick 9630ms` → `PLAYER_OPEN ep=1/8`（只开一次，无黑屏旧集） |
| **退出** | `TVDP_EXIT` → 2.6 秒 → `TVDP_CANCEL note=popstate phase=exit` → `location.pathname="/"`，`mask:false / active:false` |
| **中途返回** | `BACK → goBack(-1)` → `TVDP_CANCEL waitedMs=2512`；之后 30 秒无幽灵起播 |
| **二次点击** | 同会话内连点两张海报都能触发（修掉 `dpStarted` 残留后） |

## 阶段 9：起播提速 —— 14 秒 → 1.5 秒（自建签名通道）

问题：电视上点海报要 20 秒左右才出画面，iOS 版几秒就播。逐段拆日志后定位到三条根因
（完整数据见 `docs/tv-feasibility.md` §0.9）：

| 根因 | 证据 |
|---|---|
| 访客态下站点死磕官方线路 | `resolve-line` 连打 9~12 次全 401，白等 **8.35s**；而第一次 `resolve` 响应里已经有 22 条可直接播的第三方 m3u8 |
| 站点「先搭播放器 UI 再解析地址」 | `resolve` 请求在点海报后 **12.4s** 才发出（detail 2.6s 就完成了） |
| WebView 无原生 HLS | `MediaSource.isTypeSupported('application/vnd.apple.mpegurl')` = false，必须走 hls.js + MSE + 60+ 个 vite chunk |

结论：既然站点后端签名可复现，就**别等站点**。改成自建通道直接取第三方线路，交给原生
`MediaPlayer`（系统播放器本身能播 HLS，不需要 ExoPlayer）。

**签名算法**（硬编码在站点前端 chunk `movie-card-runtime-*.js` 里）：

```js
const KEY = "f39d73aa7a6426203cdee1ef17b31d3b7ea8c23f4c59c62a3a8aa0f39ee5e79d";
// signature = HMAC-SHA256(KEY, `${METHOD}\n${pathname}${search}\n${timestamp}\n${nonce}`)
// 只作用于同源 /v1/*；nonce = 16 字节随机数 hex；timestamp = Date.now()
```

请求头：`x-ai-movie-timestamp` / `x-ai-movie-nonce` / `x-ai-movie-signature` /
`x-ai-movie-client-name: movie-search-frontend` / `x-ai-movie-client-version: 1.0.0` /
`x-ai-movie-protocol-version: 2026-07-05.library-v2.playback-v1` /
`x-ai-movie-build-version`（随站点发版变，**运行时从站点请求头里学**，不写死）。

**四步链路**（`dpOwnChannel`）：

1. `/v1/catalog/{id}/episodes?limit=48&offset=0` —— 41ms 拿到 15 集，每集带 `token`
2. `/v1/catalog/{id}/detail` —— 拿标题与 `available_episode_count`
3. `/v1/playback/resolve/{epToken}?view=compact` → `line_options`
4. 过滤 `http` + `m3u8` + `resolved !== false` + `minimum_user_level <= 0`，
   **前 3 条并行预检**（各 1600ms 超时，拉文本看 `#EXTM3U`），先可用者胜
   → `startNativePlay(url, 'own')`

**五个实现细节**：

1. `dpChanBusy` 互斥：自建通道和方案 A（`dpOnResolve` 钩子）只能活一条，
   否则两边同时起播会抢播放器。
2. 自建通道任何一步失败（签名失效 / 401 / 超时）都 `dpChanBusy=false` 并打
   `TVDP_CHANNEL_FAIL`，`dpOnResolve` 立刻接管 —— **最坏退回 12~14 秒，不比优化前差**。
3. 预检中的 URL 登记进 `dpProbeSet`，`fetch` / `XHR` 钩子见到就**不记 `mediaSeq`**，
   否则自己的预检会被当成「站点开始播」而抢先拿坏线路起播。
4. 剧集列表优先从接口取（`token` 直连换集，`TVDP_OWN_EP` 2.5s），接口失败才退回 DOM 点选；
   起播太快时站点详情页还没渲染出按钮，用 detail 的集数伪造「第N集」占位。
5. `playing` 阶段在 `tick()` 里把站点那个 `<video>` `pause()` 掉，避免它偷偷续流量/抢音频焦点。

### 日志（阶段 9）

| 日志 | 含义 |
|---|---|
| `TVDP_CHANNEL {"ms","eps","ep","lines"}` | 自建通道拿到线路（`ms` 应 < 2000） |
| `TVDP_CHANNEL_FAIL {"note","ms"}` | 自建通道失败，已降级到兜底路径 |
| `TVDP_LINES {"n","total","ep"}` | 线路过滤结果（n 条可用 / total 条原始） |
| `TVDP_LINE_OK {"idx","ms","src"}` | 某条线路预检通过 |
| `TVDP_LINE_BAD` / `TVDP_LINE_ERR` | 预检不通 / 请求异常 |
| `TVDP_OWN_EP {"ms","idx","label"}` | 用 token 直接换集成功 |
| `TVDP_START {"note":"own"}` | 起播来源 = 自建通道（`own-pick` = 换集） |
| `TVWARM_COLLECT {"n"}` | 播放页停留 6s 后收集 chunk 列表并存 localStorage |
| `TVWARM_PREFETCH {"n"}` | 首页停留 5s 后建 prefetch 链接（去重后） |
| `TVPICK {"sec","idx","eps","tok"}` | 选集面板触发换集（`tok` = 该集 token 是否就绪） |
| `TVPICK_RECOVER {"idx","id"}` | 换集时清单是空的，正在按 catalog id 重新拉取 |
| `TVPICK_RECOVERED {"n","tok"}` | 清单补回来了，继续换集 |
| `TVPICK_NOEP {"idx","note"}` | 补不回来，已撤遮罩收会话（不再卡在「正在切换剧集」） |

### 画面取证

Amlogic 硬件视频层**不参与屏幕合成**：`screencap` 与 `screenrecord` 录出来纯黑，
只剩 UI 层文字。所以「有没有出图」只能看日志：

```
I/player: PLAYING duration=1982493 video=1920x1080
```

`getVideoWidth()/getVideoHeight()` ≠ 0 才证明视频轨真的解出来了（`PlayerActivity.onPrepared`
里上报）。这也是唯一可靠的证据。

### 阶段 9 实机验证（2026-11-08 07:56，鹤7 Pro 75R675C）

| 项 | 结果 |
|---|---|
| 构建 / 安装 | `0.9.1` / build 12 / 377KB，v1+v2+v3 通过 |
| **首次点海报** | `TVDP_CHANNEL {"ms":1617,"eps":15,"ep":1,"lines":6}` → `TVDP_START note=own waitedMs=2602` → `PLAYING video=1920x1080` |
| **同会话第二次** | `waitedMs=1164` / `1616`（热路径） |
| **换集** | `TVPICK {"sec":9,"idx":1,"eps":15,"tok":15}` → `TVDP_OWN_EP {"ms":2528}` → `TVDP_START note=own-pick waitedMs=2537` → `PLAYER_OPEN ep=1/15`（面板等 2.4s 收进度回写，合计 5.1s） |
| **续播** | 「继续观看」卡片「上次看到 3:33」→ `pos=213000` 起播，集数取 `current_episode.sequence_index`（不再显示成第 1 集） |
| **退出回写** | `ACTIVITY_RESULT reason=back pos=15200` → `TVDP_EXIT` → `TVPROGRESS {"synced":13,"from":0}` → `pathname="/"` |
| **画面** | `PLAYING duration=1982493 video=1920x1080`（截图取不到，见上） |

## 阶段 9.1：选集面板两处修复（0.9.3 / build 14）

### ① 当前集背景一直是橙色，焦点移走也不消失

反馈原话：「换集列表中当前播放的集背景一直是橙色，遥控器选其他集后，背景没有去掉。」

根因在 `PlayerActivity.cellBg`：焦点态和「当前播放集」共用**同一套亮橙底**——

```java
// 旧代码：两个条件或在一起，同一个样式
v.setBackground(cellBg(hasFocus || index == episodeIndex));
```

于是焦点移到第 6 集后，第 4 集（当前在播）仍然满足 `index == episodeIndex`，橙底留着，
**屏幕上同时两格橙**，看起来像焦点没跟过去。

改法：橙底只属于焦点，当前集改用橙色描边 + 标题行文字。

| 状态 | 底色 | 描边 | 文字 |
|---|---|---|---|
| 焦点 | `0x44FF6B42` 亮橙 | 2dp `0xCCFF6B42` | `#F2F1ED` |
| 当前播放集（未聚焦） | `0x14FFFFFF` 深灰（**和其它格一样**） | 2dp `0x99FF6B42` | `#FFD3C2` 淡橙 |
| 其它 | `0x14FFFFFF` | 1dp `0x33FFFFFF` | `#F2F1ED` |

标题行同时补一句「当前 第N集」（`选集 · 共 8 集 · 当前 第4集`），不靠颜色也能读出来。

**实机验证（`0.9.3` / build 14）**：逐格采样格子底色（避开文字），焦点在第 4 集时
只有第 4 集是 `(75,37,28)`，右移两格后第 4 集回到 `(29,30,33)`、只有第 6 集是 `(75,37,28)`；
第 4 集左边框采到 `(157,68,46)`（橙描边），紧邻内侧 `(29,30,33)`（深灰底）。

### ② 从「继续观看」起播后换集失效、遮罩卡在「正在切换剧集」

修 ① 时顺手实测发现：从首页「继续观看」卡片起播，按 MENU 换集会卡死
（`TVPICK {"idx":5,"eps":0,"tok":0}`，遮罩停在「正在切换剧集… 37s」，只能按返回）。

根因在 `tick()`：

```js
if (location.pathname !== lastPath) {
  lastPath = location.pathname;
  epList = [];          // ← 路径一变就清空
```

自建通道在**首页**就把 8 集填好、原生播放器起播，随后站点自己 SPA 跳到 `/player/xxx` ——
这一跳把清单清空了。原生面板里那 8 集是起播瞬间传进去的拷贝，所以面板看着正常，
但换集时 `pickEpisode` 取不到那一集。

点海报起播没暴露，是因为站点详情页会发 `resolve`，`dpOnResolve` 把清单补了回来。

改法三处：

1. `tick()` 不再直接清空，只打 `epPathMoved` 标记；
   `openEpisodes()` 里才判断——DOM 有新列表就用新的，跨了页面且**不在直通会话里**才清空
   （会话期间一律保留，换集就发生在那个时候）。
2. `dpBegin()`（点海报开场）清一次 `epList`，否则 `dpFastChannel` 失败退回
   `dpFastStart` 时会用到上一部片的残留清单（串片）。
3. `pickEpisode()` 取不到剧集时不再只弹 toast：先用当前路径的 catalog id 把带 token 的
   清单重新拉回来（`TVPICK_RECOVER`），拉不回来才 `dpReset()` 撤遮罩收会话
   （`TVPICK_NOEP`）——无论如何都不会让用户对着转圈干等。

**实机验证（同一路径，修改前 → 修改后）**：

```
改前:  TVPICK {"idx":5,"eps":0,"tok":0}   → 遮罩停在「正在切换剧集… 37s」，无后续
改后:  TVPICK {"idx":5,"eps":8,"tok":8}
       TVDP_OWN_EP {"ms":2623,"idx":5,"label":"第6集"}
       TVDP_START {"note":"own-pick","waitedMs":2629}
       PLAYER_OPEN ep=5/8 → PLAYING duration=2784083 video=1920x1080
       再开面板: SHEET_OPEN ep=5，标题「当前 第6集」，只有第6集橙底
```

## 阶段 10：四条沙发反馈（0.10.1 / build 16）

用户实机用出来的四条体验问题，全部当轮修复、当轮实机验证。

### 1. 播放器顶栏（剧名）和底栏（按键说明）自动隐藏

旧版两条 bar 永久压在画面上下沿。改为：进播放 **4 秒后淡出**，之后任何按键
（OK / 方向 / 音量 / 播放暂停）都会重新亮出并重开倒计时；bar 隐藏时第一下 OK
只负责唤出 bar、不顺手暂停（画面突然停住很意外，再按一下才播放/暂停）。
选集面板打开期间 bar 强制隐藏，关面板重新亮出。报错时 bar 常显不倒计时。
日志：`BARS 显示/隐藏`（实测起播后整 4.0s 触发隐藏）。

### 2. 首页按上键先回首屏、再上菜单栏

根因：顶部导航 `position:fixed`，无论滚多远都贴在视口顶上，`nearest()` 永远
认为它「最近」—— 焦点先跳菜单栏，`reveal()` 又把这个视口外元素当目标，
每按一次上键页面滚 88px，看起来就是「先跳菜单，页面才开始滚」。
修复（focus.js）：

- 页面没回到顶（`.movie-page-body` scrollTop > 12）时，纵向移动一律跳过
  fixed 壳层（导航/工具栏），焦点只在内容里走；
- 焦点已在最上面一排但页面没到顶时，按上键不抢焦点，先把页面往回滚
  40% 屏高（`scroll-top`），滚到顶后下一按才落到菜单栏。

实测（scrollY 1378 起连续按上）：焦点逐行走内容 → scrollY 一路降到 0 →
焦点上到「查看更多 / 账号」，全程没有一次先跳「首页」菜单项。

### 3. 顶部菜单焦点态：去橙底、下划线跟随焦点、亮字放大

- 旧版选中项有 18% 橙底（用户原话「不好看」）；现在导航项**不走焦点环**：
  `applyStyle()` 对 `.app-primary-nav-desktop` 内的元素只加 `.tv-focused` 类，
  CSS 画「3px 橙色下划线（::after 绝对定位，不占布局）+ 白字 + 700 加粗 +
  scale(1.1) + 橙色 text-shadow」，其余项 `#BCB9B3` 暗灰。
- 旧版下划线绑在站点的 `.is-active`（按路由算），站点在电视上始终认为当前页
  是首页，线永远钉在第一项。现在下划线**完全由焦点类驱动**，路由态只管字亮。
- 站点原生给的 1px 青色选中框压成透明（保留 1px 宽度防抖动）。

### 4. AI 搜索「会话没有打开成功」（iOS 版同样存在）

根因在壳层伪装得**太像**原生 App：bridge.js 曾把 `isAvailable` 写成 true 并挂了
`window.AiMovieAndroidBridge`。站点 native-environment 据此判定「原生壳」，
于是它的会话归属逻辑走 `owner` 分支：桥存在但没有 `auth.getState /
auth.restoreSession` → 两次 auth 探测回 NOT_IMPL → `kind = restore_failed` →
`owner = "unavailable"` → 所有 `auth:"session"` 的请求（`POST /v1/threads` 等）
**发出去之前**就被抛成「会话尚未就绪」，页面只显示「连接失败，请稍后重试」，
站点自己那条「创建匿名会话（POST /v1/users/anonymous）」的分支永远走不到。
修复：`isAvailable: false` + 不再暴露 `AiMovieAndroidBridge`，让站点按普通
浏览器处理 —— 它自己会建匿名会话，搜索/收藏/评论全部恢复。
壳层自己的代码只读 `.call`，native 播放、手机输入、远程配置不受影响。
取证链路（均为实机日志）：`TVTHREAD`（threads 请求/响应体）、`TVAPI_FAIL`
（任何 /v1/ 4xx/5xx 的状态码 + 响应体）。

### 换集兜底补强（回归时发现）

- `dpOwnEpisode` 失败退 `doPickDom` 时，占位清单（自建通道伪造的「第N集」）
  没有 DOM 元素，旧版静默 return，遮罩永久停在「正在切换剧集」。现在
  `doPickDom` 遇 `el:null` 会用 `findEpEl` 等站点渲染（最多 10s），等不到才
  `dpReset()` + toast 明说。
- `waitForMediaAndPlay` 20s 超时从「只 toast」改为「撤遮罩交还站点页面」，
  不再让用户对着遮罩干等 3 分钟。
- 教训（写进 `dpFastChannel` 注释）：自建通道 `no-line` **不等于播不了** ——
  实测第 8 集自建通道 0 条第三方线路，但站点自己的 resolve-line 流程 13.5s
  拿到官方 CDN 直链正常播出。任何「提前判死」都会掐死这条活路。

### 实测（0.10.1 / build 16 / 381KB，鹤7 Pro）

| 项 | 结果 |
|---|---|
| bar 隐藏 | `PLAYING` 后整 4.0s `BARS 隐藏`；按 OK 立即重现（截图） |
| 上键回滚 | scrollY 1378→0 全程内容行走，不先跳菜单栏 |
| 导航焦点 | `docs/tv-stage10-nav-focus.png`：白字+下划线，无橙底；右移后下划线跟走 |
| AI 搜索 | `POST /v1/threads` 201，AI 回复 + 影片卡片正常出图 |
| 换集正向 | 第 1 集：站点 DOM 路径 6.3s 起播（伪装 .jpg 真视频正确识别） |
| 换集兜底 | 第 7 集（自建通道 no-line）：5.4s 经站点路径起播，遮罩不卡 |

### 0.10.2 焦点态去橙框（build 17）

用户反馈：焦点元素「除了背景色提示以外，还有一个橙色的方框，不好看也多余」。

改动（三处，全部去掉框、保留背景/放大提示）：

- `focus.js` RING：`outline: 4px solid #FF8A3D` + 10px 橙色光晕 → `outline: none` +
  只留 `0 18px 40px rgba(0,0,0,0.62)` 暗色投影。outline 仍写（none）是为了压掉
  站点按钮 `:focus` 自带的框；`outline-offset` 一并写 0。
- `focus.css` 兜底规则同步：3px 橙 outline + 7px 光晕 → none + 暗投影。
- 原生选集面板 `PlayerActivity.cellBg`：焦点格去掉 2dp 橙描边，只留橙底；
  「当前集」的描边保留（那是位置标记，不是焦点框）。

焦点可见性现在靠三层无框提示：海报卡 scale(1.10) 放大、暗色投影、站点/皮肤自己的
背景高亮（弹窗按钮聚焦时是整块白底，效果自然）。`outline:none` 的 inline 写法对
站点自画框是净压制——之前站点三个按钮只有一个是橙色，现在全部统一无框。

实机验证（`0.10.2` / build 17）：焦点海报「嫁金钗」边缘 4968 个采样点 **0 个橙色**
（全图唯一橙色是海报封面本身的内容色）；原生面板焦点格纯橙底无描边。
截图：`docs/tv-stage10-noring-focus.png`、`docs/tv-stage10-noring-sheet.png`。

### 0.10.3 继续观看列表即时刷新（build 18）

用户反馈：「刚刚看过的剧集，没有出现在继续观看列表里。」

取证（CDP 实机逐层验证）：进度回写本身没问题——`playback-resume` 本地存储首条
就是刚看的剧；冷启动 / 站点自身真实跳转后列表也是全的。问题出在**退出播放器
SPA 回到首页那一刻列表不重读数据**：

| 手段 | 结果 |
|---|---|
| 直接改 localStorage + 派发站点 `movie-search-playback-resume-updated` 事件 | 已挂载的列表**不变** |
| pushState 到 `/library/history` 再回首页 | **仍不变** |
| 整页加载 / 站点自身路由跳转后的重挂载 | 读到新数据 |

根因：首页列表由 React `useSyncExternalStore` 订阅站点的 `playback-resume-store`
驱动，SPA 返回不触发重挂载，store 的变更事件在我们的回写路径里到不了它。

修法（壳层兜底，`tv-overlay.js`）：进度回写完成置 `resumeDirty`；回到首页
（popstate）后核对「本地最新一条 vs 列表 DOM」（`.movie-resume-name` 片名比对），
不一致就逐级刷新——① 派发站点 store 事件（`playback-resume-updated` /
`library-updated` / 合成 `storage` 事件，无副作用）→ ② 路由绕行进一次
「播放历史」再回首页逼重挂载（同「追剧」菜单机制）→ ③ 整页 `reload`
（冷启动水合必读 localStorage；sessionStorage 记时间戳，2 分钟内只允许一次防循环）。
列表未挂出（骨架期）先等（1.6s × 4）再升级，全程 `TVRESUME` 日志。
