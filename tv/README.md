# 搜剧 AI 电视版 · 阶段 1~6 工程

**当前状态**：`0.6.0` / build 6 —— WebView 壳 + 遥控器焦点引擎 + TV 版式皮肤 +
手机扫码输入 + 原生播放器 + **选集面板 / 进度回写 / 登录入口 / 远程线路配置**，
已装进雷鸟鹤7 Pro 75R675C 实机验证。
自签名证书 30 年有效，装一次永久可用，没有 iOS 版那套 7 天续签。

首屏实机截图：`docs/tv-stage3-home.png`。完整方案与实测数据：
`docs/tv-feasibility.md`、`docs/tv-webview-capabilities.json`。

## 目录

```
tv/
├── AndroidManifest.xml                  minSdk 21 / targetSdk 30 / 双 LAUNCHER category
├── res/values/strings.xml               app_name = 搜剧TV
├── res/mipmap-mdpi/ic_launcher.png      192×192，由 tools/make-tv-icon.py 生成
├── libs/zxing-core-3.5.3.jar            只用 QRCodeWriter 生成二维码（Maven Central）
├── assets/
│   ├── bridge.js                        documentStart 注入：RPC 桥 + 环境标记 + polyfill（含 replaceChildren）
│   ├── focus.js                         焦点引擎：候选集 / 轴向最近邻 / refind / 宽元素特例 / 浮层焦点域
│   ├── focus.css                        焦点环样式（Chrome 83 基线）
│   ├── tv-skin.css                      TV 版式：1200px 全宽 / 6 列网格 / 深色令牌 / 今晚首选 / 搜索浮层
│   ├── tv-skin.js                       data-* 标记 / 首屏排序 / 今晚首选卡 / 锚点自检
│   ├── tv-overlay.js                    顶部工具栏（搜索/选集/登录/扫码/原生播放）+ 搜索/选集/登录浮层 + 手机输入回传 + 媒体嗅探 + 进度回写
│   ├── input-page.html                  手机扫码后的局域网输入页（由 LocalInputServer 提供）
│   ├── error.html                       两条线路全挂时的错误页
│   ├── probe.html                       阶段 0 能力探针（保留）
│   └── security-probe.html              桥令牌隔离验证页
├── src/com/wuxiaogang/soujutv/
│   ├── MainActivity.java                宿主、按键路由、全屏、failover 编排
│   ├── ShellConfig.java                 线路、可信 host、UA、常量
│   ├── NativeBridge.java                RPC 路由 + 令牌校验 + 能力上报 + playNative/setOverlay
│   ├── TvWebViewClient.java             导航边界、注入挂钩、失败上报
│   ├── TvChromeClient.java              全屏回调、控制台、进度兜底
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

**仍然不用 Gradle**：11 个 Java 类 + 一个 zxing jar，`aapt2 → javac → d8 → zipalign → apksigner`
两秒出 352KB APK，改一行立刻装机实测。播放器实测系统 `MediaPlayer` 足够
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

## 下一步

阶段 0~6 全部收口：看片、搜索、输入、播放、换集、进度记忆、登录、远程换域名都已实机可用。
再往下是「锦上添花」：站内评论区/片单的电视版式、播放器画质与音轨切换、
跨设备继续观看（同一账号多终端进度同步，站点已提供接口但电视端没接）。

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
