package com.wuxiaogang.soujutv;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;

/**
 * 全局常量与「本次进程」的可变配置。
 *
 * 刻意不用 SharedPreferences：阶段 1 只验证桥与遥控器手感，配置全部走
 * `adb shell am start --es url/--es domains` 注入，改一次不用重装、不用清理数据。
 * 等阶段 4 做远程配置时再换存储。
 */
public final class ShellConfig {

    public static final String TAG = "SoujuTV";
    public static final String APP_VERSION = "0.5.0";
    public static final int APP_BUILD = 5;
    public static final String BRIDGE_VERSION = "1.2.0-tv";
    /** 阶段 4 手机输入服务端口；换端口只改这里，二维码会同步变化。 */
    public static final int INPUT_SERVER_PORT = 8088;

    /** 内置线路。与 iOS 版 ShellConfig.builtinDomains 对齐。 */
    public static final String[] BUILTIN_LINES = {
            "https://souju.ai",
            "https://hctd4.com"
    };

    /**
     * 允许调用原生桥的 host。
     *
     * 与「允许导航的 host」刻意分成两套：
     *  - 导航必须宽松：站点是域名轮换架构，会 302 到 bpz2.com / bpz3.top 这类中转域，
     *    写死白名单会导致某天突然打不开。
     *  - 桥必须严格：只有这些 host 上的主 frame 才下发会话令牌。
     *    页面被导到第三方站点时拿不到令牌，调桥一律拒绝。
     *
     * 中转域列进来的理由是它们同属站点运营方、且是首页的正常落点；
     * 若日志里出现新的中转域，用 --es trusted "a.com,b.com" 临时补，不必重新编译。
     */
    private static final Set<String> TRUSTED_HOSTS = new HashSet<>(Arrays.asList(
            "souju.ai", "hctd4.com",
            "bpz2.com", "bpz3.top", "bpz3.com"
    ));

    /** 站内探测发现的中转域，运行时补充，仅本次进程有效。 */
    private static final Set<String> EXTRA_TRUSTED = new HashSet<>();

    /**
     * 系统浏览器把 UA 伪造成 iPad Safari 5.0.2，会让站点走错误的移动版分支。
     * 覆盖成与真实内核相符的值。刻意不加 `AIMovieAndroidBrowser/1`：
     * 站点的 native-environment 用这个标记判断是否「Android 原生壳」，一旦命中，
     * 侧边栏会尝试调起原生更新检查 / 午夜剧场原生全屏，而 A 阶段两者都没实现。
     * capabilities.platform 报 android 已足够让 insets 与评论区走正确分支。
     */
    public static final String UA =
            "Mozilla/5.0 (X11; Linux armv7l) AppleWebKit/537.36 (KHTML, like Gecko) "
                    + "Chrome/83.0.4103.120 Safari/537.36 SoujuTV/" + APP_VERSION;

    /** 主线路连续失败几次才切换；避免一次抖动就换线路。 */
    public static final int FAILOVER_THRESHOLD = 1;
    public static final int LOAD_TIMEOUT_MS = 15000;

    private ShellConfig() {}

    public static String normalize(String raw) {
        if (raw == null) return null;
        String s = raw.trim();
        if (s.isEmpty()) return null;
        // file:///android_asset/ 是本地探针 / 错误页，不能当裸域名补 https://
        if (!s.startsWith("http://") && !s.startsWith("https://")
                && !s.startsWith("file://")) s = "https://" + s;
        return s;
    }

    public static String hostOf(String url) {
        if (url == null) return "";
        try {
            return android.net.Uri.parse(url).getHost().toLowerCase(Locale.US);
        } catch (Throwable t) {
            return "";
        }
    }

    public static boolean isTrustedHost(String host) {
        if (host == null || host.isEmpty()) return false;
        String h = host.toLowerCase(Locale.US);
        for (String base : TRUSTED_HOSTS) {
            if (h.equals(base) || h.endsWith("." + base)) return true;
        }
        for (String base : EXTRA_TRUSTED) {
            if (h.equals(base) || h.endsWith("." + base)) return true;
        }
        return false;
    }

    public static void addTrustedHosts(String csv) {
        if (csv == null) return;
        for (String part : csv.split(",")) {
            String h = hostOf(normalize(part));
            if (!h.isEmpty()) EXTRA_TRUSTED.add(h);
        }
    }

    /** 主 frame 是否允许导航。资源请求不走这里，所以图片 CDN 不受影响。 */
    public static boolean allowNavigation(String url) {
        if (url == null) return false;
        if (url.startsWith("about:") || url.startsWith("file:///android_asset/")) return true;
        return url.startsWith("https://") || url.startsWith("http://");
    }
}
