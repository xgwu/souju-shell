package com.wuxiaogang.soujutv;

import android.content.Context;
import android.util.Log;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/** logcat + 落盘双写。电视可能开 FLAG_SECURE 导致截屏全黑，日志是唯一可靠的取证通道。 */
public final class BridgeLog {

    private static final SimpleDateFormat STAMP =
            new SimpleDateFormat("HH:mm:ss.SSS", Locale.US);
    private static File file;

    private BridgeLog() {}

    public static void init(Context ctx) {
        File dir = ctx.getExternalFilesDir(null);
        if (dir != null) {
            file = new File(dir, "bridge.log");
            try {
                // 每次启动截断，避免日志无限增长；要看历史用 logcat -d
                new FileWriter(file, false).close();
            } catch (IOException ignored) {}
        }
    }

    public static void i(String tag, String msg) { write("I", tag, msg); }
    public static void w(String tag, String msg) { write("W", tag, msg); }
    public static void e(String tag, String msg) { write("E", tag, msg); }

    private static synchronized void write(String level, String tag, String msg) {
        String line = STAMP.format(new Date()) + " " + level + "/" + tag + ": " + msg;
        switch (level) {
            case "E": Log.e(ShellConfig.TAG, line); break;
            case "W": Log.w(ShellConfig.TAG, line); break;
            default:  Log.i(ShellConfig.TAG, line); break;
        }
        if (file == null) return;
        try {
            FileWriter w = new FileWriter(file, true);
            w.write(line + "\n");
            w.close();
        } catch (IOException ignored) {}
    }

    public static String path() {
        return file == null ? "(不可用)" : file.getAbsolutePath();
    }
}
