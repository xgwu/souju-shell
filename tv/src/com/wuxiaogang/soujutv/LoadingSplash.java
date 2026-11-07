package com.wuxiaogang.soujutv;

import android.animation.ObjectAnimator;
import android.content.Context;
import android.graphics.Color;
import android.os.Build;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

/**
 * 开机加载页（揭幕门期间盖在 WebView 上面）。
 *
 * 为什么不用「纯黑等皮肤就绪」：实测站点首屏要 4.5 秒才铺出骨架，
 * 纯黑 4.5 秒会被当成「应用卡死/黑屏」。这里给一块与皮肤同色的品牌页
 * （搜剧TV + 正在加载 + 细进度条），等待就变成「启动中」而不是「坏了」。
 *
 * 只在整文档加载期显示；站点内 SPA 换页不经过这里。
 */
final class LoadingSplash {

    private final FrameLayout root;
    private final TextView title;
    private ObjectAnimator pulse;

    LoadingSplash(Context ctx) {
        root = new FrameLayout(ctx);
        root.setBackgroundColor(0xFF0E0E10);
        root.setClickable(true);          // 挡住误触，加载期间不让点击落到 WebView
        root.setVisibility(View.GONE);

        LinearLayout col = new LinearLayout(ctx);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setGravity(Gravity.CENTER_HORIZONTAL);

        title = new TextView(ctx);
        title.setText("搜剧TV");
        title.setTextColor(0xFFF2F1ED);
        title.setTypeface(null, android.graphics.Typeface.BOLD);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 40);
        title.setGravity(Gravity.CENTER);
        col.addView(title);

        TextView sub = new TextView(ctx);
        sub.setText("正在加载…");
        sub.setTextColor(0xFF8C8983);
        sub.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18);
        sub.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        slp.topMargin = dp(ctx, 12);
        col.addView(sub, slp);

        ProgressBar bar = new ProgressBar(ctx, null, android.R.attr.progressBarStyleHorizontal);
        bar.setIndeterminate(true);
        bar.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(0xFFFF6B42));
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(dp(ctx, 220), dp(ctx, 3));
        blp.topMargin = dp(ctx, 26);
        col.addView(bar, blp);

        FrameLayout.LayoutParams clp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        clp.gravity = Gravity.CENTER;
        root.addView(col, clp);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            pulse = ObjectAnimator.ofFloat(sub, "alpha", 1f, 0.35f, 1f);
            pulse.setDuration(1600);
            pulse.setRepeatCount(ObjectAnimator.INFINITE);
        }
    }

    View view() { return root; }

    void show() {
        root.setAlpha(1f);
        root.setVisibility(View.VISIBLE);
        if (pulse != null && !pulse.isStarted()) { pulse.start(); }
    }

    /** 淡出 180ms 后隐藏；与 WebView 的 160ms 渐入交叉，避免闪跳。 */
    void hide() {
        if (root.getVisibility() != View.VISIBLE) { return; }
        root.animate().alpha(0f).setDuration(180).withEndAction(new Runnable() {
            @Override public void run() { root.setVisibility(View.GONE); }
        }).start();
        if (pulse != null) { pulse.cancel(); }
    }

    private static int dp(Context ctx, int v) {
        return (int) (v * ctx.getResources().getDisplayMetrics().density + 0.5f);
    }
}
