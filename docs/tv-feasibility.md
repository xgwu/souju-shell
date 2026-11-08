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

### 0.3 阶段 1+2 已验证通过（2026-11-07 12:00 实机）

正式壳与焦点引擎已经装进电视，全部取证来自 `adb logcat -s SoujuTV` 与自检回包，不依赖界面描述。

| 验证项 | 结果 |
|---|---|
| 构建 | 7 个 Java 类 / 44KB APK，v1+v2+v3 签名通过，`adb install -r` 319–469ms |
| **桥就位** | 站点主动调用 `app.getSystemInsets`、`app.getCapabilities`（多次），`bridge:true`；令牌误拒 0 次 |
| **能力协商** | `platform:"android"` + `supportsNativePlayer:false` → 站点判 `legacy_app`，回落 H5 播放器 |
| **注入自检** | `cssInjected:true`、焦点环 `rgb(255,138,61)`、`Array.at` / `replaceAll` / `randomUUID` 三个 polyfill 全生效 |
| **焦点遍历** | 83 个候选；连续右键 y=16→16→19，向下 x 偏移 26–27px，**无斜跳**；OK 键 `clicked` 生效 |
| **焦点环可见** | 实机截图确认橙色描边框住「周六 7日」日历格 |
| **令牌隔离** | 不可信 `file://` 页面上 `SoujuTvNative` 确实存在，但伪造/空/猜测令牌 3 次调用**全部 REJECT**，且 `H5ShellNativeBridge === undefined` |
| **线路 failover** | 首条 `ERR_UNSAFE_PORT` → `FAILOVER_TRIGGER` → 600ms 后切第二条，VERIFY / DOM 全绿 |
| 返回 / 菜单 | BACK 跳过失败页历史、单次不退出；MENU 切线路生效 |
| 稳定性 | 无 JS 错误、无崩溃、进程存活 |

**四条推翻或细化了原方案的实测结论**（细节见 §4、§5.1）：

1. **站点 CSP 是 `script-src 'self' https:`（无 `unsafe-inline`），`frame-ancestors 'none'`**。
   所以不能靠 `shouldInterceptRequest` 改写 HTML 塞 `<script>` 来做 documentStart 注入。
   `evaluateJavascript` 从 WebView 层执行，**不受页面 CSP 约束** —— 自检回包证实了这一点。
   注入时序靠 start / progress≥15 / finish 三次幂等注入 + 站点自身 `[0,120,320,700]ms` 四轮等桥重试兜底。
2. **导航白名单必须与桥白名单分开**。原方案写「拦掉白名单外所有跳转」，但站点是域名轮换架构，
   顶层导航一旦严格拦截，中转域换了就打不开。改成：顶层 https 导航放行，
   **只有可信 host 的主 frame 下发令牌**。安全等价性更强 —— 令牌才是真正的权限边界。
3. **站点的 `window.AiMovieAndroidBridge.postMessage` 只是环境探针，不是 RPC 通道**。
   全量 bundle 里它只出现在 `native-environment`，真正 RPC 一律走 `H5ShellNativeBridge.call`。
   UA 刻意**不加** `AIMovieAndroidBrowser/1`：那个标记会让站点走原生更新检查 / 午夜剧场原生全屏分支，
   而 A 阶段两者都没实现。`capabilities.platform:"android"` 已足够让 insets 与评论区走正确分支。
4. **焦点环比预想难**：站点按钮带 `.movie-button-secondary:focus` 这类高特异性规则，
   会盖掉样式表里的 `.tv-focused { outline:…!important }`（实测三个按钮里两个分别显示白/深墨色）。
   最终改成 JS 侧写 **inline `!important`** 并在切换时还原原值。另外补了 `elementFromPoint` 最上层过滤，
   否则弹窗遮罩底下的元素仍会被当成可聚焦；以及去掉 `outline-color` 的 120ms 过渡，让焦点环即时可见。

### 0.4 阶段 3 已验证通过（2026-11-07 13:23 实机）

TV 版式皮肤 + 兼容层 + 锚点自检已装进电视。取证来自 `adb logcat -s SoujuTV`、
CDP 几何量取与 `docs/tv-stage3-home.png`（App 自注入皮肤后滚回顶部的首屏）。

| 验证项 | 结果 |
|---|---|
| 构建 / 安装 | `0.3.0`（build 3）/ 52KB APK，v1+v2+v3 通过，`adb install -r` 518–684ms |
| **6 列网格** | `gridTemplateColumns` = 6 × `190px`，卡片 `190×287`（`padding-bottom:150%` 做 2:3），替代原 `180px×10` 横向 rail |
| **无横向溢出** | `documentElement.scrollWidth=1280`、`overflowX:false`；所有横滑列表改成网格 / wrap |
| **字号** | 搜索输入 26px、顶部导航 26px、热词 19px、卡片标题 20px、section 标题 26px（原 11–16px） |
| **今晚首选** | 由首张 feed 卡数据生成的 1200×148 宽幅卡，焦点可达、点击走站内链接 |
| **深色层** | 重映射站点 `--movie-*` 令牌为 iOS souju-dark 同套色值 |
| **锚点自检** | `HEALTH_OK checked=13 columns=6 overflowX=false missing=''`，站点改版会主动告警 |
| **VERIFY** | `skinCss:true / skinMarker:on / skinState.missing:[] / gridColumns:6`，3 个 polyfill 仍全绿 |
| **焦点连续性** | 连续 8 次 DOWN 全部 `moved`（首页→搜索→今晚首选→第 2/3/4/5 行海报），零 `initial` |
| 稳定性 | 无 JS 错误、无崩溃；`DOM` 979 节点 / 40–42 图 / 62 链接 / 46 按钮 |

**四条推翻或细化了 §6 初版设计的实测结论**：

1. **左侧竖导航改成了「隐藏侧栏 + 满宽顶部导航」**。CDP 量取发现站点那个 272px 侧栏
   不是主导航，而是用户信息抽屉（头像 / 成长值 / 扫码 / 分享 / 通知 / 登录）。把它收窄并放大到
   20px 后内容换行重叠、被裁切，占 272px 却只提供电视上用不到的功能。真正的主导航是
   `.app-primary-nav-desktop`（首页/短剧/历史/片单），改成满宽顶栏后内容区 1200px，
   6 列每张正好 190 CSS px —— 与 §6 初版数值一致，但路径完全不同。
2. **站点用 `--movie-sidebar-width` 变量 + `!important` 决定主内容 padding**。
   只写 `padding-left:40px!important` 会被反压回 288px；实测在 `html` 上写
   `style.setProperty('--movie-sidebar-width','40px','important')` 才稳。
3. **首屏排序比压缩尺寸更有效**。「本周追剧」日历（7 个日期 + 4 组剧集小卡）放大后会占 528px，
   把海报推到 y≈1100。用 flex `order` 把日历挪到海报墙之后、`继续下滑` 提示挪到最后
   （不能 `display:none`，站点靠它触发无限滚动），首屏第一行海报从 y=538 开始。
4. **宽幅卡的焦点要用「覆盖区间」而不是中心点**。1.2k 宽的今晚首选卡中心 x=640，
   从左侧热词按 DOWN 时按中心点算侧向偏移 400+px，会被轴向加权判成斜跳而整张卡跳过。
   焦点引擎补了「当前坐标落在超宽元素水平范围内时 cross=0」的特例。

**阶段 3 顺带修掉两个焦点隐患**（都是实机按键轨迹暴露的）：
`tv-skin.js` 的 `tonight()` 第一版每次同步都移除重建横幅，MutationObserver 被自己的 DOM 改动
触发，形成 220ms 死循环（候选数 75/76 跳动、焦点每按两下弹回顶部）→ 改成按数据签名幂等；
焦点引擎补了 `refind()`（站点重建 feed 卡后按「标签+可读文本+坐标」找回等价元素）与
`recovered` 分支（彻底失联时落在上次位置附近，而不是列表第一个「首页」）。

### 0.5 阶段 4+5 已验证通过（2026-11-07 14:35 实机）

版本 `0.5.0` / build 5 / 336KB APK（新增 zxing 只为画二维码）。包含
**四项用户实报 UI 修复** + **阶段 4 手机扫码输入** + **阶段 5 原生播放器**。

**四项 UI 修复**（全部 CDP 断言回归通过）：

| 问题 | 根因 | 修复 |
|---|---|---|
| 焦点移开后顶部菜单残留橙框 | 旧实现给站点元素写 inline `outline/box-shadow`，失焦时还原被站点高特异性 `:focus` 盖掉；多元素同时带环 | 改为 `data-tv-ring` 属性标记 + 单一焦点持有，遍历 12 键后全页 ring=1 |
| 海报获焦后消失 | 获焦 `scale(1.04)` 放大元素，站点卡片 `overflow:hidden` 联动把图片裁没了 | 缩放改到内层 / 修 `transform-origin`，获焦后图片 196×296 完整可见 |
| 「热门剧」热词行无意义 | 站点首屏两行 chips 占 ~120px | 隐藏 `.movie-home-prompt-groups`，首屏让给海报墙 |
| 搜索框太大占地方 | 常驻 composer 占 ~100px | 收成右上角搜索图标；OK 开**自建**搜索浮层（默认聚焦输入框），BACK 关浮层、焦点还给图标。不自建浮层不行：站点的 `fixed` composer 被 `.keepalive-route-container` 的 `isolation:isolate` 锁在低层堆叠上下文，且聚焦输入框会触发 WebView 视口缩小 |

**阶段 4（手机扫码输入）**：`LocalInputServer` 监听 8088、4 位配对码、ZXing 画二维码。
实测 `/api/send?k=6688` → 电视 100ms 收到 `tv.remoteInput` → 用 React 受控组件原型
setter 写入搜索框自动提交；无/错配对码一律 403。

**阶段 5（原生播放器）**：`PlayerActivity` 用系统 `MediaPlayer`（不是 ExoPlayer ——
直链 mp4 + Range 拉流 MediaPlayer 足够，media3 的收益只剩 DASH/DRM，不值得为此引入
AAR 链）。遥控器全接管：OK 播放/暂停、←→ ±10s、↑↓ 音量、MENU 显隐控制条、BACK 退出。
实测 H5 播放到 20:46 点「原生播放」→ 1 秒 `PLAYING duration=48:10` 续播、全部按键生效、
网络不可达的流正确弹 `MEDIA_ERROR`。

**本次最重要的技术发现 —— 伪装直链**：
站点把整部 mp4 存在 `.jpg` 路径下（`p6-volc-community-sign.byteimg.com/...jpg~tplv-...`），
CDN 回包 `content-type: image/jpeg` 但字节是 `ftyp isom/avc1`（`Range: bytes=0-127` 实测，
总长 532MB、`accept-ranges: bytes`）。`video.currentSrc` 长得像封面图却在正常播放
（`duration=2890s`、`currentTime` 前进）。**推论：媒体直链判据是 `video.duration > 0`，
绝不能按扩展名过滤** —— 按 `.mp4/.m3u8` 后缀过滤会误杀真直链、放过真占位图。
同时确认站点有全站 Service Worker（scope=`https://souju.ai/`，controller=true）。

**顺带修复**：播放中无操作 8 分钟电视进屏保并把播放器暂停（用户实报场景）→
`PlayerActivity` 加 `FLAG_KEEP_SCREEN_ON`；onPause 停 500ms 进度轮询、onResume 恢复。
另：**adb 截屏拍不到原生播放器的视频层**（HUD 能拍到、视频层全黑），这是 MTK 对
硬件 overlay 层的截屏限制 —— 播放器取证看 `player:` 日志与音频 `state:started`，
画面以电视实际显示为准。

### 0.6 阶段 6 四项可选增强（2026-11-07 16:40 实机）

版本 `0.6.0` / build 6 / 352KB APK。四项全部实机跑通：

| 增强 | 落点 | 实机证据 |
|---|---|---|
| ① 选集 / 剧集列表原生 UI | H5 自建 8 列网格（`.tv-episode-cell`）+ `PlayerActivity` 底部面板（MENU 唤出、8 列/行、当前集高亮并自动获焦） | `EPISODE_PICK 7` → `RETURN reason=episode pos=337541/1694083 ep=5 pick=7` → `TVEPISODE pick 7 第8集` → `resolved .../axkVJBEe/index.m3u8 afterMs=11281` → `PLAYER_OPEN ep=7/15` → `PLAYING duration=1468250`（24:28，正是第 8 集） |
| ② 播放位置回写「继续观看」 | H5 `syncProgress()`：退出时把站点 `<video>` 静音 seek 到目标位前 2 秒、真播 2.1 秒，借站点自己的 recorder 落库 | `TVPROGRESS {synced:32,from:111}`；localStorage `movie-search:v2:playback-resume:owner:guest` 首条变 `["走马上任","第8集",32]`，`updatedAt` 同步刷新；预览键 `playback-resume-preview` 也指向第 8 集 |
| ③ 账号登录入口 | 自建登录浮层（二维码 + 账号/密码两个「手机输入」按钮 + 登录/返回）；回车路径全部走 8088 局域网输入，React 原型 setter 写值后点站点提交 | `TVINPUT {text:"demo@example.com",field:"account",lagMs:114}` → `TVLOGIN_ARM password` → `TVINPUT (password) lagMs:74` → 自动 `TVLOGIN_SUBMIT {hasForm:true,hasSubmit:true}` → 3.8s 后 `登录未成功`（假账号，属预期） |
| ④ 远程线路配置下发 | `TvConfig`：启动异步拉 JSON（version/lines/trusted/notice），校验后落 SharedPreferences；两条下发通道 —— 公网 `--es config <url>`、局域网 `POST /api/config?k=<pin>` | LAN 推送 `CONFIG_PUSH len=137` → `CONFIG_APPLIED v9 lines=3 source=lan changed=true`；重启后 `LINES [souju.ai, hctd4.com, test-line-3.example]` 仍生效；公网通道 `CONFIG_FETCH 200` → `CONFIG_APPLIED v11 lines=2 trusted=bpz2.com,bpz3.top changed=true`；`--es config off` → `CONFIG_URL_CLEARED` |

**本轮抓到的真 bug —— .ts 分片把播放列表挤出缓冲**：
媒体嗅探原来把 `.ts` 也算媒体地址，HLS 每 2 秒一片，8 条环形缓冲几秒钟就被分片占满，
点「原生播放」拿到的可能是一个 `.ts` 分片（只能播 2 秒）。改为：
`.ts` 不入队，只用它反推 `index.m3u8`；`currentMedia()` 优先返回含 `m3u8` 的地址。
修完 `playUrl` 稳定命中 `https://hn.bfvvs.com/play/e9rp0gPa/index.m3u8` 这类播放列表。

**换集为什么要点完等 11 秒**：点站点选集后，站点自己要 11 秒左右才去请求新集的
playlist（`TVEPISODE resolved afterMs=11281`），不是壳在等。这期间的优化是：
切集瞬间把 H5 `<video>` 静音（站点会自己开播），拿到新地址再交给原生播放器；
超时 20 秒才放弃并解除静音。原生面板换集还会先 `__tvSyncThenPick()`
把当前集进度写回、2.4 秒后再切，避免两个动作抢同一个 `<video>`。

**其它修复**：`log()` 统一加 `SOUJUTV` 前缀（`TvChromeClient` 的白名单），否则电视上
console 取不到、现场只能靠截图；`visibilitychange` 补一次 `tick()`（WebView 被原生
播放器盖住时定时器会被冻结，回来要立刻恢复工具栏状态）。

### 0.7 阶段 7 首屏体验六项（2026-11-07 17:35 实机）

版本 `0.7.0` / build 7 起，收尾后为 `0.7.1` / build 8（含下面「验收后又补的三处」）/ 364KB APK。用户报的六条观感问题逐条落地：

| # | 问题 | 根因（实测） | 改法 |
|---|---|---|---|
| 1 | 打开应用能看到「初始首页」一闪再刷新 | 注入在 `progress15`，`PAGE_START 44.32 → PAGE_FINISHED 47.00`，中间 2.7 秒跑站点原生版式；且首页各块挂载时间差很大：海报墙 4.3s、继续观看/日历 7.6s、真卡 7~10s | 原生**揭幕门**（`RevealGate`）：`setAlpha(0)` 藏起 WebView，等 JS 上报就绪再 160ms 渐入；期间盖一块同色品牌加载页（`LoadingSplash`）。就绪信号走 console（`SOUJUTV SKIN_READY`），**不用 evaluateJavascript 轮询**——实测这台机器上它的回包延迟能到 1.6 秒，8 秒只回了 5 次，永远踩不到就绪那一刻 |
| 2 | 顶部菜单用色块表达选中，观感重 | 旧版同时给「18% 橙底 + 3px 下划线」，`min-width:108px` 让下划线拖出比文字长很多的空线 | 只留下划线；`min-width:0` + `padding:0 4px` 让线贴住文字；文字提亮到 `#F2F1ED` |
| 3 | 今晚首选横幅占屏且糊 | 卡 `1200×148`，封面原图 `420×600`，`object-fit:cover` 先横向放大 **2.86 倍**再裁掉 82% 画面 | 改 `1200×116`：背景用同图 `blur(26px) brightness(.62)` 抹掉放大痕迹，前景放 `64×96` 竖版缩略图（与 2:3 原比例一致，缩小后锐利） |
| 4 | 继续观看 / 本周追剧被甩到最下方 | `[data-tv-resume]` 与 `[data-tv-late]` 同 `order:3`，feed 是 `2` | order 改为 今晚首选 0 / 继续观看 1 / 追剧日历 2 / 海报墙 3 / 加载更多 4；日历按方案 B 只留 7 天日期条（藏 4×4 小组卡，`.home-watch-calendar` 还有 `min-height:240px` 必须清掉，否则留 136px 空白）；继续观看 4 张卡改网格 136 高（顺带解决「横滑后几张遥控器够不到」） |
| 5 | 海报获焦几乎看不出 | `scale(1.04)` 打在**内层链接**上：188→196 只大 8px，外框卡片/圆角不动，海报从边框溢出 4px | 放大对象换成卡片外壳（`focus.js` 新增 `cardOf()`），`scale(1.10)` → 190→209，`transform .14s` 过渡，焦点环画到卡片上（4px 环 + 10px 外发光 + 卡片投影一起写 inline） |
| 6 | 上下滚动没有滑动感 | `scroller.scrollTop += delta` 一步 307px 到位，零动画 | rAF + easeOutCubic 补间 150–330ms（这台机器 WebView 约 25–30fps，330ms≈9 帧才看得出滑）；新按键从当前 `scrollTop` 续接目标；上下留白 72→96 |

**「闪一版」的真正成因是两次位移，不是两次渲染**：站点先画骨架，再挂「继续观看（184px）」
「追剧日历（118px）」「今晚首选（126px）」，每挂一块就把海报墙往下顶一次。
所以除了揭幕门，还做了**占位**（`tv-skin.js` 的 `placeholders()` + `[data-tv-tonight-host] min-height`）：
真块没到之前先用等高 div 撑住，到货后同位替换，海报墙从第一帧起就在最终位置（实测 `ph` 归零、位移 0）。

**同时修掉的三个真 bug**：

1. `data-tv-feed` 靠 `innerText` 猜块，站点标题渲染晚 0.5 秒就漏标 → 海报墙按默认 `order` 排在
   日历前面再被顶下去。改成 `flagBlock()`：从真实节点向上走到 wrap 的直接子节点再打标。
2. `tonight()` 取「第一张 `.home-feed-card`」，但骨架卡也带这个类、没有 `<img>`/标题，
   一直卡到 9.4 秒才建卡。改成扫描第一张「图 + 标题都在」的真卡（提前到 ~5 秒）。
3. `focus.js` 的 `scrollY` 诊断读 `document.scrollingElement`（恒为 0），实际滚动容器是
   `.movie-page-body`；面板类页面永远读不到滚动量。

**门控范围**：只给「本进程第一次加载」和「回首页」套门（`--es gate off` 可整体关掉做 A/B）。
实测站点站内跳转多为 SPA 换页（不触发 `onPageStarted`），但「今晚首选」是我们插的裸 `<a href>`，
点它会走整文档加载——这种也会被放行，不再盖 2.7 秒加载页。

**首屏预算（1280×720 实测）**：导航 66 + 主推条 116 + 继续观看 184 + 日历 118 + 海报标题 ~45
→ 第一行海报从 **y≈598** 开始，露出约 120px；三块信息齐全且全程零位移。

**验收后又补的三处（`0.7.1` / build 8）** —— 六项改完在实机上按遥控器走一遍发现的：

| # | 现象（实机） | 根因 | 改法 |
|---|---|---|---|
| 1 | 在「今晚首选」上按 DOWN，焦点直接落到日历的「周四」，整排「继续观看」永远不会被走到 | `nearest()` 打分是 `primary + cross*2.6`。横幅宽 1214、居中：下一排继续观看 dx=151 / dy=184 → 578；再往下 164px 的日历格 dx=0 / dy=348 → 348。**侧向对齐压过了纵向距离**，而且越按越往下 | 源是宽幅条时（`width > 50vw`）纵向移动改「距离优先」：`primary*4 + cross`。实测路径恢复为 导航 → 今晚首选 → 继续观看 → 日历 → 海报墙，海报墙内左右/换行不受影响 |
| 2 | 揭幕之后整页还会再下移 102px | `data-tv-tonight-host` 只在卡建好后才打标记，`min-height:126px` 到 9.7 秒才生效（实测继续观看占位 y=106，真块到位后变 208） | 改成从「热词组」的父节点**提前**打标记（约 1.5 秒就有）。实测 5 秒时占位 y=208、13 秒真块 y=208，零位移 |
| 3 | 「首页」明明只留了下划线，却总带一圈橙色圆角方框 | **不是 CSS**：是 WebView 系统自绘的 default focus highlight（API 26+），焦点移走后会残留在原处；`getComputedStyle` 的 `outline` / `box-shadow` 全是 0，查不到 | `web.setDefaultFocusHighlightEnabled(false)`；顺带把站点给导航项的 1px 青色四边框压成透明（`border-color: transparent`，保留 1px 宽度，否则选中项比邻居窄 2px 会左右抖） |

> 日历里「今天」那格（周六）的橙色描边是**站点自己的语义样式**（`border-color: rgb(255,107,66)`，类名不变、按日期算出），刻意保留。

### 0.8 阶段 8 首屏取舍 / 追剧菜单 / 直通播放（2026-11-07 18:55 实机）

版本 `0.8.0` / build 9 起（收尾为 `0.8.1` / build 10，含下面 §0.8.1 的追加改造）/ 368KB APK。三条需求逐条落地：

| # | 需求（原话） | 改法 | 实机结果 |
|---|---|---|---|
| 1 | 把「今晚首选」「本周追剧」从首屏去掉 | CSS 把 `[data-tv-tonight]` / `[data-tv-tonight-host]` / `[data-tv-late]` / `.tv-ph-late` 一起 `display:none`；JS 侧 `SHOW_TONIGHT=false`、`PH_KEYS=['resume']`（占位也只留继续观看）；继续观看改 5 列、只露前 5 条 | 首屏 = 导航 66 → 继续观看（5 卡一行，y≈106~242）→「大家都在看」标题 y≈265 → 海报第一行 y≈296，**完整露出两行海报**（`docs/tv-stage8-home.png`） |
| 2 | 主菜单「首页」后面加一个「追剧」，点进去是完整周表 | `tv-skin.js` 新增 `navExtra()`：往 `nav.app-primary-nav-desktop` 里插一个 `.tv-nav-updates`，`href=/updates`；点击走 `history.pushState` + `dispatchEvent(new PopStateEvent('popstate'))`，**不让它整文档加载**（实测 `PAGE_START` 计数 0，站点自己的路由接手）。页内样式全套 `html[data-tv-page="updates"]` | 两条线（`hctd4.com` / `souju.ai`）菜单均为「首页,追剧,短剧,历史,片单」；追剧页广告块消失、卡片 148px / 标题 23px / meta 16px、3 列 389px，滚动容器 `.watch-calendar-page-content`（`scrollHeight 1693 / clientHeight 574`）由焦点引擎 `reveal()` 沿父链自动接管（`docs/tv-stage8-updates.png`） |
| 3 | 点海报直接进沉浸式全屏播放器，不要经过详情页 | `tv-overlay.js` 新增「直通播放」：点海报时记 `{t,title,poster}` 进 `sessionStorage`、盖一层全屏起播遮罩，站点照常 SPA 进详情页（跑在遮罩下面，用户看不见）；一旦 `currentMedia()` 拿到可播地址立刻交给原生播放器全屏起播；退出播放器时 `history.back()` 回首页 | `TVDP_START waitedMs=25768` → `PLAYER_OPEN` → `PLAYING duration=2782302`；退出后 `TVPROGRESS {synced:16}` 再自动回 `/`（`docs/tv-stage8-directplay.png`） |

**四条与判断相关的实测**（都是先踩坑后量出来的，不是猜的）：

1. **详情页天然就慢，不是皮肤拖慢的**：点海报到 `<video>` 元素出现 11~14 秒，到 `readyState>=1` 20~27 秒。关掉皮肤（`--es skin off`）实测 14 / 27 秒 —— 同一量级，所以「优化详情页」这条路不成立，只能绕开。
2. **全屏 `filter: blur(30px)` 在这台机器上是负优化**：遮罩一加模糊，下层正在解析的详情页被拖死，`<video>` 从 11 秒推到 30 秒以上（每帧重栅格化一张全屏大图）。改成 `opacity:0.55 + transform:scale(1.08)` 拿到同样的观感，代价接近零。
3. **站点把整部 mp4 伪装成 `.image`**：直链形如 `…~tplv-xxx-image.image`（或 `.jpg`），CDN 谎报 `image/*`，实际字节是 `ftyp isom`、支持 Range。所以判据只能是 `video.duration > 0`，按扩展名过滤会把真直链当封面图跳过（第一版就是因此一直等到超时）。
4. **站点是 SPA，`history.pushState` + 手动派发 `PopStateEvent` 就能换页**：整文档加载（`PAGE_START`）不触发，导航不闪白，这也是「追剧」菜单能做到无缝的直接原因。

**直通播放踩的四个坑**（实机复现 → 定位 → 修法）：

| 现象 | 根因（实测证据） | 改法 |
|---|---|---|
| 遮罩期间看到的是站点那句「精彩即将开始」，我们的海报遮罩等于不存在 | `document.elementFromPoint()` 链上最顶层是 `line-loading--parse … z-index: 2147483000`，我们的 `.tv-dp` 只有 `z-index: 90` | `.tv-dp` 提到 `z-index: 2147483002`；顺手删掉 `tv-skin.css` 里被重复粘贴的一整份遮罩样式（两个 `.tv-dp {}` 块，`z-index` 都还是 90） |
| 同一会话里第二次点海报不生效，直接落到普通详情页 | `dpStarted` 只在 `dpBegin` 里复位，一轮播完后永远停在 `true`，把后续点击全吃掉（`__tvDirectPlayState()` 返回 `started:true, session:false`） | 新增 `dpReset()`：回到首页（`popstate`）时复位整个会话；`0.8.1` 起状态机改为 `dpActive + dpPhase` |
| 点的是《尚公主》，播放器的地址却是上一部片（`20261102/22082_565930aa`） | SPA 换页后 `<video>` 里残留上一部片的地址且 `duration` 依然 `>0`，`currentMedia()` 直接认定可播 | 两道新鲜度闸门：① `mediaSeq`（`recordMedia` 每次被调用 +1，必须比点之前大，即「这一轮真发过媒体请求」）；② 元素和地址不能还是点海报那一刻的那一对 |
| 按了返回、人已经回到首页，播放器 93ms 后又自己弹出来 | 详情页解析把主线程占满，BACK 被排队 8 秒才派发（按键 18:48:59，`BACK → goBack(-1)` 落在 18:49:07.793），正好和 `TVDP_START` 撞上 | `popstate` 里判「回首页 + 非播放会话」直接取消（`TVDP_CANCEL`）；`dpTick` 再补一道 1.5 秒宽限的「路径回到 `/`」兜底（宽限是因为 `dpBegin` 那一刻路径还是 `/`） |

**端到端日志（2026-11-07 19:44，`0.8.1` 一次跑完首播 + 换集 + 退出）**：

```
TVDP_BEGIN   {"title":"今天是太阳雨"}
TVDP_START   {"note":"resolve","waitedMs":13695}   ← 地址一就绪立刻交给原生播放器
PLAYER_OPEN  title=今天是太阳雨 pos=0 ep=0/8
PLAYING      duration=2782302
ACTIVITY_RESULT reason=episode pos=19040 dur=2782302 ep=0 pick=1   ← 播放器原生选集面板
TVDP_SWITCH  {"label":""}          ← 遮罩切回「正在切换剧集」，此时用户看到的是遮罩
TVPROGRESS   {"synced":17}          ← 换集前先把当前集进度写回站点
TVEPISODE    {"pick":1,"label":"第2集","autoPlay":true}
TVEPISODE    {"resolved":"…","afterMs":6976}
TVDP_START   {"note":"pick","waitedMs":9630}
PLAYER_OPEN  … ep=1/8
ACTIVITY_RESULT reason=back pos=…
TVDP_EXIT    {"reason":"back"}      ← 遮罩换「正在返回首页…」，2.6 秒后 history.back()
TVPROGRESS   {"synced":16,"from":111}
TVDP_CANCEL  {"note":"popstate","phase":"exit"}   ← 落地首页，撤遮罩、状态清零
```

**换集不另做 UI**：播放器上原生的选集面板（`MENU` 唤起，`SHEET_OPEN`）已经够用。选一集后 `pick>=0` 返回，Java 侧调 `__tvSyncThenPick(sec, idx)` —— 先把当前集进度写回站点，2.4 秒后在后台详情页点对应集，约 7 秒重新起播，**全程没有详情页出现在用户眼前**。

**已知代价**：起播等待 10~28 秒这一段是站点给的（实测 10.3 / 13.7 / 14.6 / 18.3 / 22.5 / 25.6 / 29.2 秒都有），我们能做的是让这段时间停留在海报遮罩上。

### 0.8.1 起播页全程不跳详情页（2026-11-07 19:45 实机）

验收后用户提的第二轮反馈：「沉浸播放页缓冲过程中，还是会中途切换到播放详情页，缓冲完毕才会全屏播放」+「在剧集 UI 切换剧集后，也不要跳转到详情页」。

根因就是我们自己在 `0.8.0` 里加的那条**「10 秒还没地址就撤遮罩、把详情页交还用户」**（`TVDP_REVEAL`），以及换集时遮罩根本没有重新挂上。改法是把遮罩从「起播遮罩」升级成**会话级遮罩**：

| 环节 | 0.8.0 | 0.8.1 |
|---|---|---|
| 首次解析 | 10 秒没地址就撤遮罩，露出详情页；地址到了再弹播放器 | **遮罩一直挂着**，地址到了直接切播放器，用户看不到详情页 |
| 换集 | 遮罩已撤，用户对着详情页等 7 秒 | 遮罩**一直没撤**（播放器是独立 Activity，会整块盖住 WebView），只是把提示换成「正在切换剧集…」 |
| 退出播放器 | 撤遮罩回退，2.6 秒内可能露出详情页 | 遮罩换成「正在返回首页…」，2.6 秒后 `history.back()` 落地首页才撤 |
| 超时 | 10 秒回退 / 60 秒放弃 | 60 秒只换提示「线路较慢…（按返回可退出）」，**3 分钟**才判定线路死亡并退回详情页 |

三个实现要点：

1. **状态机换成 `dpActive` + `dpPhase`**（`resolve / switch / playing / exit`）。`dpActive` 的生命周期是「点海报 → 回到首页」，遮罩只在会话结束（`popstate` 且路径回到 `/`）时才移除。
2. **换集阶段禁止 `dpTick` 抢起播**：`pickEpisode` 自己会轮询并用「正确的第几集」调 `startNativePlay`。第一版没禁，实测旧集换个 HLS 变体地址（`index.m3u8` → `3000k/hls/mixed.m3u8`）就骗过了新鲜度判断 —— 结果先黑屏播回旧集，4 秒后新集的播放器才盖上来。禁掉之后换集只开一次播放器。
3. **换集回来零闪烁**：因为遮罩在 `playing` 阶段也没撤，PlayerActivity 关闭瞬间 WebView 里第一帧就已经是遮罩，不会闪出详情页（这是「遮罩全程挂着」最直接的收益）。

**实机验证（`0.8.1` / build 10 / 368KB）**：

| 项 | 结果 |
|---|---|
| 13 秒时（旧版此刻已在详情页） | 截图仍是「今天是太阳雨 / 正在解析线路… 13s」，`__tvDirectPlayState()` = `{active:true,phase:"resolve",mask:true}` |
| 换集后 3 秒 | 截图是「今天是太阳雨 / 正在切换剧集… 3s」，不是详情页；日志只有一条 `PLAYER_OPEN ep=1/8`（无黑屏旧集） |
| 换集总耗时 | `TVDP_SWITCH` → `TVDP_START note=pick waitedMs=9630`（含 2.4 秒进度回写 + 6.9 秒站点解析） |
| 退出 | `TVDP_EXIT` → 2.6 秒 → `TVDP_CANCEL note=popstate phase=exit` → `pathname="/"`，`mask:false`、`active:false` |

---

### 0.9 阶段 9 起播提速：14 秒 → 1.5 秒（2026-11-08 07:5x 实机）

用户反馈：「电视上进入播放页后，缓冲时间非常长，差不多要二三十秒才进入播放，而 iOS 版本打开几秒钟就进入播放了。」

先把「慢在哪」量清楚。三轮实测（同一台电视，点海报到 `PLAYER_OPEN`）：

| 轮次 | 片名 | 点击→起播 | 播的线路 |
|---|---|---|---|
| A | 走马上任 | 19.6s | `wsyzym3u8` HLS |
| B | 走马上任 | 23.7s | `xgplay17` HLS |
| C | 谷雨 | 25.3s | byteimg 伪装 mp4 |

B 轮按相对点击时刻拆开（`performance.getEntriesByType('resource')`）：

| 时刻 | 发生了什么 |
|---|---|
| 0 → 3.24s | SPA 路由 + 首批 chunk |
| 3.24 → 3.93s | `/v1/catalog/{id}/detail` |
| 4.68s | `hls.js` chunk 到达 |
| **8.36s** | **`resolve` 返回 200 —— 此刻手里已经有 22 条可播地址** |
| **9.69 → 18.04s** | **9 次 `resolve-line` 全 401，横跨 8.35s** |
| 18.04 → 22.69s | artplayer + P2P chunk 才加载完 |
| 24.35s | 站点终于请求 m3u8 |

三条根因，一条比一条要命：

1. **站点在访客态死磕「官方线路」。** `resolve` 响应里 30~35 条线路分两类：8 条官方线路（`url` 是 `resolve://av_...` 票据，要再调 `resolve-line` 换真地址，且要求登录）；22 条第三方线路（`url` 直接是可播 m3u8，`resolved:true`、`minimum_user_level:0`）。站点把官方线路排在前面，电视端是访客态（`/v1/users/me` 401），于是 `resolve-line` 连打 9~12 次全 401：

   ```json
   {"statusCode":401,"code":"playback_user_session_required","message":"该内容需要登录后播放"}
   ```

   **答案在第一次响应里就已经有了，站点却去敲一扇锁着的门，还敲了 9 遍。**
2. **站点是「先搭播放器 UI，再解析地址」。** 实测 `resolve` 请求在点海报后 **12.4 秒**才发出（detail 在 2.6 秒就完成了，中间 9.6 秒全在加载 hls.js / artplayer / P2P / 弹幕那一堆 chunk）。
3. **WebView 没有原生 HLS。** `MediaSource.isTypeSupported('application/vnd.apple.mpegurl')` = **false**（iOS Safari 是 true）。所以站点必须走 MSE + hls.js，那 60+ 个 chunk 一个都省不掉。

已排除的方向：Wi-Fi（5G / WiFi6 / 链路 1201Mbps / 信道利用率 3%）、主线程卡顿（最大长任务 688ms）、皮肤拖慢（关皮肤同样 14/27 秒）、站点 API 绝对慢（Mac 直连同接口 TTFB 380~465ms）。

#### 做了什么

**方案 A（第一版）：hook 站点的 `resolve` 响应，把里面的 m3u8 直接交给原生播放器。**
这一版就把 19~25 秒压到了 12~14 秒（省掉站点 401 重试 + 播放器初始化那 10 秒）。但剩下那 12 秒仍然是在等站点的播放器 UI 加载完 —— 治标。

**方案 B（最终版）：自己走完整条链路。** 站点把签名密钥直接写死在前端 chunk 里，我们也算得出来：

```js
// movie-card-runtime-*.js 里
const lo = "f39d73aa7a6426203cdee1ef17b31d3b7ea8c23f4c59c62a3a8aa0f39ee5e79d";
// signature = HMAC-SHA256(key, `${method}\n${pathname}${search}\n${timestamp}\n${nonce}`)
// 只对同源 /v1/* 生效；nonce = 16 字节随机数的 hex；timestamp = Date.now()
```

于是点海报那一刻就能自己走：

```
点海报 → GET /v1/catalog/{id}/episodes?limit=48&offset=0   ← 每集都带 token，实测 41ms
        → GET /v1/catalog/{id}/detail                       ← 集数/标题，与上一条并行
        → GET /v1/playback/resolve/{epToken}?view=compact    ← line_options
        → 并行探测前 3 条 m3u8（拉文本看 #EXTM3U，顺带预热 DNS/TLS）
        → playNative
```

`episodes` 响应里每集都有 `token`，所以**换集也不用再点站点 UI**：播放器 MENU 选一集 → 直接用那集的 token 重新 resolve → 起播。

#### 实测（`0.9.1` / build 12 / 377KB）

| 场景 | 优化前 | 优化后 |
|---|---|---|
| 点海报（冷启动后首次） | 14.5s（方案 A）/ 19.6~25.3s（原版） | **1.16 ~ 2.60s** |
| 点海报（同会话第二次） | 5.2s（方案 A） | **1.16 ~ 1.62s** |
| 换集（播放器面板） | 9.6s | **5.1s**（含 2.4s 进度回写，纯解析 2.5s） |
| 续播定位 | 站点自己 seek | 卡片上「上次看到 3:33」→ `pos=213000`，直接传进播放器 |
| 退出 | 正常 | `pos=239458` → `TVPROGRESS {synced:237,from:213}` → 回首页 |

一条完整日志（点海报 → 起播 → 换集 → 退出）：

```
TVDP_BEGIN   {"title":"走马上任"}
TVDP_CHANNEL {"ms":1617,"eps":15,"ep":1,"lines":6}        ← 自建通道：1.6 秒拿到地址
TVDP_START   {"note":"own","waitedMs":2602}
PLAYER_OPEN  title=走马上任 pos=0 ep=0/15 url=…/index.m3u8
PLAYING      duration=1982493 video=1920x1080              ← 视频轨真的解出来了
TVPICK       {"sec":9,"idx":1,"eps":15,"tok":15}
TVEPISODE    {"pick":1,"label":"第2集","via":"own"}
TVDP_OWN_EP  {"ms":2528,"idx":1,"label":"第2集"}          ← 换集解析 2.5 秒
TVDP_START   {"note":"own-pick"}
PLAYER_OPEN  … ep=1/15
ACTIVITY_RESULT reason=back pos=239458
TVPROGRESS   {"synced":237,"from":213}
TVDP_CANCEL  {"note":"popstate","phase":"exit"} → pathname="/"
```

`video=1920x1080` 这条是专门加的取证：电视的 SurfaceView 走硬件视频层，`screencap` / `screenrecord` 都取不到画面（录出来是纯黑，只有 UI 层），所以「到底有没有画面」只能看 `MediaPlayer.getVideoWidth/Height` —— 非 0 即已解码出图。

#### 三个必须知道的实现细节

1. **`dpChanBusy` 是两条通道的互斥闸。** 自建通道跑着的时候，`dpOnResolve`（方案 A）一律不插手，否则两边同时挑线路会互相覆盖；自建通道一旦失败（签名变了、接口 401、某一步超时），`dpChanBusy` 复位，方案 A 立刻接管 —— 也就是**最坏情况退回到 12~14 秒，不会比现在更糟**。
2. **`build-version` 等头是运行时学的，不写死。** `x-ai-movie-build-version` 跟着站点发版变（当前 `aimovie-v2026.11.06.2-search-header-…`），所以从站点自己发的第一个 `/v1/` 请求里把它学回来，自己发请求时复用。
3. **预检三条线路是并行的，不是串行。** 串行时「第一条不通要干等 2 秒超时」，实测把 1 秒的通道拖成 3.5 秒起播；改成并行后最坏只多一个 RTT（1.46 秒）。
4. **剧集列表从 `episodes` 响应直接取，不再依赖站点 DOM。** 起播只用 1.5 秒，那时详情页还没渲染出剧集按钮，`collectEpisodes()` 是空的 —— 早期版本因此出现「播放器选集面板一集都没有」。现在 epList 用接口返回的真实 `title` + `token`；换集优先用 token 自己解析，同时 fire-and-forget 去点一下站点里对应那一集（最多等 10 秒），让站点的「当前集」和进度记录跟上。
5. **`playing` 阶段把站点自己的 `<video>` 按下去**（`pause`，`progressSyncing` 那 2 秒除外）：它会接着解析并起播同一部片，白占带宽和解码器 —— 电视上解码器只有两三个。

#### 已知代价

- **签名密钥是逆向来的、写死在 `tv-overlay.js` 里。** 站点换密钥或改签名协议，自建通道会 401 并打 `TVDP_CHANNEL_FAIL`，随后自动降级到方案 A（12~14 秒）。要恢复 1.5 秒需要重新从 chunk 里取一次密钥。
- 自建通道和站点自己会**各发一次 detail/episodes/resolve**（站点不知道我们抢先了），服务端请求量多一倍 —— 都是几十毫秒的轻接口。
- 换集的 5.1 秒里有 2.4 秒是**故意等的**（等 `syncProgress` 把上一集进度写入站点），不是解析慢。

### 0.9.1 选集面板两处修复（2026-11-08 08:1x 实机，`0.9.3` / build 14）

#### ① 当前集背景一直橙色，焦点移走不消失

**反馈原话**：「换集列表中当前播放的集背景一直是橙色，遥控器选其他集后，背景没有去掉。」

`PlayerActivity.cellBg` 里焦点态和「当前播放集」共用同一套亮橙底：

```java
v.setBackground(cellBg(hasFocus || index == episodeIndex));   // 旧代码
```

焦点移到第 6 集后，第 4 集（在播）仍满足 `index == episodeIndex`，橙底留着 ——
**屏幕上同时两格橙**，用户看到的就是「背景没有去掉」。

| 状态 | 底色 | 描边 | 文字 |
|---|---|---|---|
| 焦点 | `0x44FF6B42` 亮橙 | 2dp `0xCCFF6B42` | `#F2F1ED` |
| 当前播放集（未聚焦） | `0x14FFFFFF` 深灰（和其它格一致） | 2dp `0x99FF6B42` | `#FFD3C2` |
| 其它 | `0x14FFFFFF` | 1dp `0x33FFFFFF` | `#F2F1ED` |

标题行同时补「当前 第N集」，去掉橙底后仍能读出在播哪一集。

**像素级验证**（逐格采样底色，避开居中文字；1920×1080 截图）：

| 截图 | 第1~8 集底色 |
|---|---|
| 焦点在第 4 集 | `29,30,33` ×3 / **`75,37,28`** / `29,30,33` ×4 |
| 焦点移到第 6 集 | `29,30,33` ×5 / **`75,37,28`** / `29,30,33` ×2 |

第 4 集左边框采到 `(157,68,46)`（橙描边），紧邻内侧 `(29,30,33)`（深灰底）——
描边在、底色已去掉。

> 注：H5 那套选集浮层（`.tv-episode-cell.is-current`）不受影响：它的焦点只画
> `outline` 描边环、从不改背景，所以不存在两格同色的问题，无需改动。

#### ② 从「继续观看」起播后换集失效、遮罩卡在「正在切换剧集」

修 ① 时顺手实测撞到的阻塞性 bug：从首页「继续观看」卡片起播，按 MENU 换集会卡死。

```
TVPICK {"sec":179,"idx":5,"eps":0,"tok":0}     ← 清单是空的
遮罩停在「正在切换剧集… 37s」，无后续日志，只能按返回
```

根因在 `tick()`：路径一变就 `epList = []`。自建通道在**首页**就把 8 集填好、
原生播放器起播，随后站点自己 SPA 跳到 `/player/xxx` —— 这一跳把清单清空了。
面板里那 8 集是起播瞬间传进原生侧的拷贝，所以面板看着正常，换集时却取不到。

点海报起播没暴露，是因为站点详情页会发 `resolve`，`dpOnResolve` 把清单补了回来。

三处改动：

1. `tick()` 只打 `epPathMoved` 标记，不再直接清空；`openEpisodes()` 里才判断 ——
   DOM 有新列表就用新的，跨了页面且**不在直通会话里**才清空。
2. `dpBegin()` 开场清一次，避免 `dpFastChannel` 失败退回 `dpFastStart` 时
   用上一部片的残留清单（`epList.length ? epList : ...` 会串片）。
3. `pickEpisode()` 取不到剧集时先用当前 catalog id 把带 token 的清单拉回来
   （`TVPICK_RECOVER`），真拉不回来才 `dpReset()` 撤遮罩收会话（`TVPICK_NOEP`）——
   任何情况下都不会让用户对着转圈干等。

**同一路径实测对比**：

```
改前:  TVPICK {"idx":5,"eps":0,"tok":0}  → 卡住
改后:  TVPICK {"idx":5,"eps":8,"tok":8}
       TVDP_OWN_EP {"ms":2623,"idx":5,"label":"第6集"}
       TVDP_START {"note":"own-pick","waitedMs":2629}
       PLAYER_OPEN ep=5/8 → PLAYING duration=2784083 video=1920x1080
       再开面板: SHEET_OPEN ep=5，标题「当前 第6集」，只有第6集橙底
```

### 0.10 阶段 10 四条沙发反馈（2026-11-08 09:0x~09:20 实机，`0.10.1` / build 16）

用户实机用出来的四条体验问题，全部当轮修复、当轮实机验证。细节见 `tv/README.md` 阶段 10。

| # | 反馈 | 根因 | 修复 | 验证 |
|---|---|---|---|---|
| 1 | 播放器顶栏/底栏常驻不消失 | bar 从不自动隐藏 | 起播 4s 后淡出；任意按键重新亮出；bar 隐藏时第一下 OK 只唤出不暂停 | `PLAYING` 后整 4.0s `BARS 隐藏`；OK 后顶栏剧名 + 底栏说明重现（`docs/tv-stage10-player-bars.png`） |
| 2 | 首页按上键先跳菜单栏才滚动 | 导航 `position:fixed`，`nearest()` 永远认为它最近 | 未滚到顶时纵向移动跳过 fixed 壳层；已在最上一排时按上键先回滚页面（40% 屏高），到顶后才允许焦点上菜单 | scrollY 1378→0 全程走内容，无一跳先上「首页」 |
| 3 | 菜单橙底难看 + 下划线钉死在第一项 | 选中态橙底；下划线绑站点 `.is-active`（路由恒为首页） | 导航项不走焦点环：`.tv-focused` 驱动「下划线::after + 白字 + 加粗 + scale(1.1)」；下划线完全跟随焦点 | `docs/tv-stage10-nav-focus.png` / `tv-stage10-nav-moved.png` |
| 4 | AI 搜索「会话没有打开成功」（iOS 同样存在） | 壳层伪装原生太彻底：桥缺 `auth.getState/restoreSession` → 站点判 `owner="unavailable"` → `/v1/threads` 未发先拒 | `H5ShellNativeBridge.isAvailable=false` + 移除 `AiMovieAndroidBridge`，让站点按普通浏览器自建匿名会话 | `POST /v1/threads` 201，AI 回复 + 卡片出图 |

**换集兜底补强**（回归时发现）：`dpOwnEpisode` 失败退 `doPickDom` 遇占位清单
（`el:null`）会静默 return，遮罩永久卡死 —— 现在先 `findEpEl` 等站点渲染（10s），
等不到 `dpReset()+toast`；`waitForMediaAndPlay` 20s 超时改为撤遮罩交还页面。

**重要教训**（写进代码注释）：自建通道 `no-line` **不等于播不了** —— 第 8 集
自建通道 0 条第三方线路，但站点自己的 resolve-line 流程 13.5s 拿到官方 CDN
直链（`43.248.128.134`）正常播出。曾尝试「no-line 时立刻撤遮罩提示登录线路」，
实机验证发现会掐死这条活路，已回退为静默兜底。

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
雷鸟电视 · Android 11 · MT9653 · WebView 83
└── SoujuTv (Java, 单 Activity)                       ← 阶段 1~3 已实现
    ├── MainActivity          宿主、按键路由、全屏、failover、皮肤开关与告警
    ├── TvWebViewClient       导航边界、注入挂钩、失败上报
    ├── TvChromeClient        全屏回调、控制台、进度兜底
    ├── NativeBridge          RPC 路由 + 会话令牌 + 能力上报 + 健康回包
    ├── TvFocusEngine         注入器 + 按键映射 + 焦点找回 + VERIFY 自检
    ├── ShellConfig           线路、可信 host、UA
    ├── BridgeLog             logcat + 落盘双写
    └── WebView               React SPA
        ├── bridge.js          RPC 桥 + 环境标记 + 3 个 polyfill
        ├── focus.js/css       候选集 / 轴向最近邻 / refind / inline 焦点环
        └── tv-skin.css/js     1200px 全宽版式 / 6 列网格 / 今晚首选 / 锚点自检  ← 阶段 3
        └── tv-overlay.js      工具栏 / 搜索浮层 / 手机输入回传 / 媒体嗅探          ← 阶段 4+5
    ├── LocalInputServer      手机扫码输入（局域网 HTTP + 配对码）                 ← 阶段 4
    └── PlayerActivity        系统 MediaPlayer 原生播放器                          ← 阶段 5
```

### 模块清单（阶段 1~3 已落地，其余为待做）

| 文件 | 职责 | 状态 |
|---|---|---|
| `MainActivity.java` | 宿主、生命周期、`dispatchKeyEvent` 按键路由、全屏、failover 编排 | ✅ 已实现 |
| `TvWebViewClient.java` | 导航边界、注入挂钩、主 frame 失败上报 | ✅ 已实现 |
| `TvChromeClient.java` | `onShowCustomView` 全屏、控制台、进度兜底 | ✅ 已实现 |
| `NativeBridge.java` | RPC 路由、会话令牌、能力如实上报 | ✅ 已实现 |
| `TvFocusEngine.java` | assets 注入器、按键映射、`VERIFY` 自检 | ✅ 已实现 |
| `ShellConfig.java` / `BridgeLog.java` | 线路 / 可信 host / UA / 日志双写 | ✅ 已实现 |
| `assets/bridge.js` | RPC 桥 + Android 环境标记 + 3 个 polyfill | ✅ 已实现 |
| `assets/focus.js` + `focus.css` | 候选集、轴向最近邻、宽元素特例、`refind`、inline 焦点环 | ✅ 已实现 |
| `assets/tv-skin.css` | 1200px 全宽版式、6 列网格、24px 级字号、深色令牌层 | ✅ 阶段 3 |
| `assets/tv-skin.js` | `data-*` 标记、首屏排序、今晚首选卡、锚点自检 + `reportHealth` | ✅ 阶段 3 |
| `LocalInputServer` + `QrGen` | 二维码 + 输入回传（配对码隔离） | ✅ 已实现（阶段 4） |
| `PlayerActivity` | 系统 MediaPlayer + 遥控器播放条 | ✅ 已实现（阶段 5） |

**当前实现刻意用 Java + 手工 aapt2 构建**：7 个类、零第三方依赖、2 秒出 44KB APK。
估时按「改一行立刻装机实测」的反馈速度算，比上 Gradle 拉 AGP 依赖更划算。
等阶段 5 引入 media3 时再切 Gradle + Kotlin。

**构建约束**：`minSdk 21` / `targetSdk 30+`，只能打 `armeabi-v7a`。不要引入 arm64-only 的 `.so`（某些版本的 media3 decoder 扩展、X5 内核需要核对架构）。media3-exoplayer 主库是纯 Kotlin + 系统 MediaCodec，32 位可用。

### 与 iOS 版的复用关系

**能搬的（设计资产，不是代码）**

- 16 个桥方法的语义与回包结构（已在 README 固定）
- 线路 failover 策略、`effectiveDomains` 概念
- 深色派生思路（结构一份 + 12 条色值映射 + 介质层）
- 皮肤自检的锚点清单（哪些选择器是关键路径）
- 站点 BEM 类名的重排手法（`.movie-home-page-shell` 等）

**不能搬的**：Swift 代码本身，0 行直接可用。UIKit/WKWebView 与 Android/WebView 的相似只到"都是 WebView"这一层。

**TV 版攻击面反而更小**：iOS 版之所以要做 origin 白名单，是因为工具箱允许用户填任意域名。
电视上没有键盘，**任意 URL 入口直接砍掉**；调试期换 URL 只走 `adb --es url`，不进产品 UI。
但站点本身会 302 到中转域，所以「导航放行」和「桥授权」必须分开——详见下面实测后的修正。

### 桥的 Android 实现要点

| | iOS | Android（本机 WebView 83，阶段 1 实测） |
|---|---|---|
| 上行 | `webkit.messageHandlers.nativeBridge.postMessage` | **`@JavascriptInterface`**（`addWebMessageListener` 要 WebView 88+，本机不可用） |
| 下行 | `evaluateJavaScript` | `evaluateJavascript` |
| 来源校验 | `frameInfo.securityOrigin.host` | **可信 host 才下发会话令牌** + 导航 scheme 拦截 |
| 注入时机 | `WKUserScript(.atDocumentStart)` | `evaluateJavascript` ×3 幂等注入 + 站点四轮等桥重试 |
| UA | 系统默认 | **必须覆盖**，但**不加** `AIMovieAndroidBrowser/1` 标记 |

`addWebMessageListener` 需要 WebView 88 以上，本机 83 只能走 JS 接口。而 `@JavascriptInterface` 对该 WebView 里
**所有 frame** 都暴露 —— 实测在 `file:///android_asset/security-probe.html` 上
`typeof window.SoujuTvNative === "object"` 成立。所以必须同时做两件事：

1. `shouldOverrideUrlLoading` 拦掉非 http(s) 导航、子 frame 越界跳转；SSL 错误一律 `cancel()`
2. **只有 `ShellConfig.isTrustedHost()` 命中的主 frame 才注入桥与会话令牌**；
   令牌每次主文档开始加载时轮换，`NativeBridge.post(json, token)` 校验通过才路由

**这里修正了初版方案的一处判断**：原文写「拦掉白名单外的所有跳转」，实测不可行 —— 站点是域名轮换架构，
顶层导航一旦严格拦截，中转域换了就打不开。所以「导航白名单」与「桥白名单」刻意分成两套：
导航宽松（顶层 https 放行）、桥严格（可信 host + 令牌）。安全等价性反而更强，因为令牌才是权限边界；
不可信页面即使拿到 Java 对象也调不动任何方法（实测 3 种伪造令牌全部 `REJECT`）。

另一处协议细节：站点 `native-environment` 会检查 `window.AiMovieAndroidBridge.postMessage` 是否为函数，
但全量 bundle 里它**只是环境探针**，真正 RPC 一律走 `H5ShellNativeBridge.call`。我们补了这个对象作兼容，
同时**刻意不在 UA 里加** `AIMovieAndroidBrowser/1` —— 那个标记会让站点走原生更新检查与午夜剧场原生全屏分支，
A 阶段两者都没实现。`capabilities.platform:"android"` 已足够让 insets 解析器与评论区走正确分支。

站点还会探测 `auth.getState` / `auth.restoreSession`：它靠 `capabilities.actions` 里有没有 `auth.*`
判定原生登录态同步是否支持。如实不报、回 `NOT_IMPL`，站点即回退 web 登录态 —— **不要去实现这两个方法**。

**能力上报要改**：B 阶段实现 ExoPlayer 后，`supportsNativePlayer` 才能报 `true`。A 阶段仍然报 `false`，
让站点走 H5 播放器——和 iOS 版同样的取舍。

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
A 阶段用 `WebChromeClient.onShowCustomView` 判定全屏，全屏期间 `dispatchKeyEvent` 把按键完整交回系统。

**阶段 2 实机踩出的四个坑**（都已修，实现在 `tv/assets/focus.js`）：

| 现象 | 根因 | 修法 |
|---|---|---|
| 三个按钮里两个的焦点环是白 / 深墨色，只有第三个橙色 | 站点 `.movie-button-secondary:focus` 等规则特异性高于 `.tv-focused`，样式表里的 `!important` 仍会输 | JS 侧给焦点元素写 **inline `!important`**，切换时还原原值；CSS 留 `html body .tv-focused` 兜底 |
| 弹窗打开后焦点跑进遮罩底下，用户看到「焦点不见了」 | 遮罩是兄弟节点，底下元素的 `getBoundingClientRect` 和 `visibility` 依然可见 | 候选集加 `elementFromPoint` **最上层命中**检查；视口外候选跳过该检查，否则永远滚不到下一行 |
| 按键后头 120ms 焦点环颜色不对 | `transition: outline-color 120ms` 让颜色渐变 | 只过渡 `box-shadow`，outline 即时生效 |
| 第一次按方向键没有任何高亮 | 站点自己 `focus` 过的元素没有 `.tv-focused` 标记 | `ensureMarked()` 给 `document.activeElement` 补标记 |

另外两条实测结论：**滚动用直接改 `scrollTop` + `requestAnimationFrame` 合并**，`scrollIntoView({behavior:'smooth'})`
在这颗 SoC 上确实会抖；**候选集要过滤嵌套**（`a` 里套 `button` 时只留内层），否则一次按键跳两级。
`elementFromPoint` 过滤在弹窗打开时把候选从 83 收敛到 4–16 个，正好把焦点约束在模态内。

按键轨迹取证（`adb logcat -s SoujuTV | grep I/key`）：连续右键 y=16→16→19，
向下 x 偏移 26–27px，说明轴向加权（主方向 1、侧向 2.6）确实消掉了斜跳。

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
TV 皮肤也必须避开 Chrome 83 不支持的 CSS。**这层已于阶段 3 落地**：3 个 polyfill 在
`bridge.js`（`VERIFY` 实测全生效），版式皮肤按下面的 83 基线写，不单列里程碑。

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

| 项 | iOS（竖屏） | TV 初版设想 | **阶段 3 实机落地** |
|---|---|---|---|
| 导航 | 底部 tab | 顶部横向或左侧竖栏（推荐左侧） | **满宽顶部导航**（1200×58，26px）；站点 272px 左侧栏实测是用户信息抽屉，隐藏 |
| 海报网格 | 2–3 列 | 6 列，每张约 185 CSS px | **6 列 `190px`、卡片 `190×287`**；`padding-bottom:150%` 替代 `aspect-ratio` |
| 今晚首选卡 | 1.42:1 竖版 | 16:9 横幅，约 1140×270 | **1200×148 宽幅卡**（8:1）；数据取自首张 feed 卡，无额外请求 |
| 最小字号 | 13px | 24 CSS px | **主交互 26px**（输入 / 导航 / 标题），热词 19px、卡片标题 20px、徽章 16px |
| 焦点态 | 无 | 2px 描边 + 1.06 缩放 | inline `!important` 3px 橙环 + 海报 `scale(1.04)`；宽幅卡有方向导航特例 |
| 默认皮肤 | 深色 | 深色 | 深色，重映射 `--movie-*` 令牌与 iOS souju-dark 对齐 |

**字号为什么没有一刀切 24px**：190px 宽的海报卡放 24px 中文一行只有 7 个字，
「Doctor X:白色黑手党时代」会被截得没人看得懂。阶段 3 按信息层级分档：
主交互（要读、要点）26px，卡片标题 20px，徽章 / 元信息 16–18px，并统一用
`white-space:nowrap + text-overflow:ellipsis` 兜底。实测在 2.5m 距离全部可读。

**左侧竖栏的设想被实机推翻**：见 §0.4 第 1 条。代价是 TV 端暂不提供扫码 / 分享 /
账号登录入口，阶段 4 做手机输入时一并补。

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
| 1 | WebView 壳 + 桥 + 线路 failover | 2 天 | ✅ **已完成**，见 §0.3：站点调用 `getCapabilities`、令牌隔离、failover 全通过 |
| 2 | **遥控器焦点引擎** | 2–3 天 | ✅ **已完成**，见 §0.3：83 个候选、无斜跳、橙色焦点环实机截图可见 |
| **3** | TV 版式皮肤（1280×720 坐标系）+ 兼容层 + 锚点自检 | 2–3 天 | ✅ **已完成**，见 §0.4：6 列 190px 网格、无横向溢出、26px 主字号、避开 5 个失效 CSS 特性、焦点连续 |
| 4 | 手机扫码输入 | 1 天 | ✅ **已完成**，见 §0.5：配对码隔离 403 实测、回传 ~100ms |
| 5 | 原生播放 | 2–3 天 | ✅ **已完成**，见 §0.5：MediaPlayer 续播 1s 起播、遥控器全接管、伪装直链识破 |
| 6 | 四项可选增强（选集 UI / 进度回写 / 登录入口 / 远程线路配置） | 1 天 | ✅ **已完成**，见 §0.6：换集全链路、resume 落库、手机输入登录、LAN+公网配置下发 |
| **7** | 首屏体验六项（揭幕门 / 下划线导航 / 紧凑主推条 / 首屏排序 / 焦点放大 / 滚动缓动） | 0.5 天 | ✅ **已完成**，见 §0.7：开机不闪版、首屏无位移、焦点 190→209、滚动 9 帧补间 |
| **8** | 首屏取舍 + 「追剧」菜单 + 直通播放（点海报直达全屏播放器） | 0.5 天 | ✅ **已完成**，见 §0.8 / §0.8.1：首屏只剩继续观看+海报墙、`/updates` 页面菜单直达、起播遮罩全程不撤（13s 仍在遮罩，换集 9.6s 重开、只开一次播放器）、退出自动回首页 |
| **9** | 起播提速（自建签名通道 + 线路并行预检 + chunk 预热） | 0.5 天 | ✅ **已完成**，见 §0.9：点海报 19.6~25.3s → **1.16~2.60s**、换集 9.6s → 5.1s、续播位置/集数不再错、`video=1920x1080` 取证出图 |
| **10** | 四条沙发反馈（bar 自动隐藏 / 上键回首屏 / 导航下划线跟随 / AI 搜索修复 + 换集兜底补强） | 0.5 天 | ✅ **已完成**，见 §0.10：四条全部实机验证，`0.10.1` / build 16 |

阶段 0~9 **全部完成**。「能装、能显示、遥控器能走、沙发上能看清、能输入、能播片、
能换集、能记住看到哪、能登录、能远程换域名、开机不闪版、焦点一眼可见、滚动有补间、
点海报一步进播放器、点海报 1.5 秒起播、播放器 bar 自动隐藏、上键回首屏不跳菜单」十六件事都有实机证据。

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
| **构建脚本** | ✅ `tools/build-tv-apk.sh`：aapt2 → javac → d8 → zipalign → apksigner，阶段 5 产物 336KB（含 zxing） |
| **实机 CSS 试跑** | ✅ `tools/tv-skin-preview.py`：CDP 注入本地皮肤 + 截图 + 几何报告，不用重装 |
| **实机 JS 量取** | ✅ `tools/tv-cdp.py`：纯标准库 WebSocket 客户端（Chrome 83 只回整数 id，见注释） |
| **签名证书** | ✅ `~/.souju-tv/tv.jks`，30 年有效；v1/v2/v3 全通过，覆盖安装签名不变 |
| **安装链路** | ✅ `adb install -r` → `Success`；两个 verifier 开关为 `null` 并未拦截 |
| **桌面可见** | ✅ 「我的应用」列表共 10 项，搜剧TV 排第一位 |

三条最常用的命令：

```bash
# 一次构建 + 安装
bash tools/build-tv-apk.sh && adb install -r tv/build/souju-tv-debug.apk

# 取证：App 自己打的全部日志（BOOT / TOKEN / INJECT / VERIFY / STATE / DOM / KEY / bridge）
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

下一步是**阶段 4**：手机扫码输入（局域网 HTTP 服务 + 二维码 + 输入回传），顺带补回
TV 端账号登录 / 扫码入口。改皮肤不用重装：`python3 tools/tv-skin-preview.py` 会把本地
`tv-skin.css/js` 通过 CDP 注入正在运行的 WebView 并截图；`tools/tv-cdp.py` 是通用的
实机 JS 执行 / 几何量取工具。完整调试参数、按键表与日志前缀见 `tv/README.md`。

---

## 9. 风险清单

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| **Chromium 83 缺运行时 API / CSS 特性** | **能力缺失已确认，首页未受影响** | 懒加载页可能报错、站点 CSS 版式塌陷 | ✅ 阶段 3 已落地：3 个 polyfill + 皮肤避开 5 个失效特性 + 关键容器显式覆盖 |
| **站点未来改版用上 Chrome 85+ 语法** | 中 | 解析级白屏，polyfill 补不了 | §5.6 升级系统 WebView；或保留远程注入 CSS/JS 通道做应急 |
| ~~遥控器焦点手感差，做不出"顺"~~ | **已排除** | — | 阶段 2 实机通过：轴向加权消掉斜跳、inline 焦点环清晰、模态约束生效 |
| 站点域名轮换导致线路失效 | 高（已知） | App 打不开 | 两条内置线路 + MENU 手动切换 + `--es trusted` 临时补域；阶段 3 另给了 `--es tvskin off` A/B 开关与 CDP 热注入通道，**远程配置下发推迟到阶段 4**（与手机输入服务合并） |
| ~~桥被任意页面调用~~ | **已排除** | — | 令牌隔离实测 3 种伪造调用全 REJECT；`security-probe.html` 可重跑 |
| ~~`adb install` 被安装校验拦截~~ | **已排除**（实测 `Success`） | — | 两条 `settings put global` 与 U 盘兜底留作备用 |
| 32 位 ABI 导致某个依赖装不上 | 中（空壳已验证通过） | 编译/运行时失败 | 空壳不含 `.so`，天然兼容；将来引入 ExoPlayer 时核对 `.so` 架构 |
| 杜比视界未必对三方 App 开放 | 中 | B 阶段只能拿到 HDR10/HLG | 实测；不承诺 DV，UI 上不标 DV 角标 |
| WebView 内 HEVC 不支持 | 已确认 | HEVC 片源播不了 | ✅ 阶段 5 已缓解：原生 MediaPlayer 走系统 MediaCodec（H.264/HEVC 由芯片决定）；H.264 直链实测可播 |
| 4GB 内存跑 SPA + hls.js 吃紧 | 低–中 | 卡顿/被系统杀 | 限制海报预载数；B 阶段把播放挪出 WebView |
| 语音键不可用 | 确定 | 少一个输入入口 | 用手机扫码输入替代 |

---

## 10. 一句话建议

**阶段 0~10 全部完成**（`0.10.1` / build 16 / 381KB）。电视版搜剧AI 已经是一个完整的可用产品：
遥控器逛片、扫码输入搜索、原生播放器看片（自动续播 H5 进度）、点海报**约 1.5 秒**直进全屏播放器。
`docs/tv-stage8-home.png` 是当前首屏，`docs/tv-stage8-updates.png` 是「追剧」页，
`docs/tv-stage8-directplay.png` 是点海报后的起播遮罩。

- 伪装直链（`.jpg` / `.image` 路径下 532MB mp4、content-type 谎报 image/jpeg）与
  「`video.duration>0` 即可信」的判据已写进 `tv/README.md` 与代码注释，
  站点换 CDN 域名也不影响。
- 系统 WebView 维持不动（§5.6），无待拍板事项。
- 起播延迟已从「站点侧问题」变成「我们侧可控」：`0.9.1` 起用自建签名通道直接取
  第三方 m3u8 交给原生播放器，不再等站点播放器 UI 就位（§0.9）；方案 A 的
  `resolve` 钩子作为兜底保留，**最坏退回 12~14 秒，不比优化前差**。
- 唯一不能自己掌控的变动是站点发版：签名密钥与 `build-version` 头都可能变，
  密钥失效时自动降级到兜底路径，不会白屏。
