package com.wuxiaogang.soujutv;

import android.graphics.Bitmap;
import android.util.Base64;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.EncodeHintType;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel;

import java.io.ByteArrayOutputStream;
import java.util.HashMap;
import java.util.Map;

/**
 * 阶段 4：把「手机输入页」地址生成二维码，作为 data:image/png 下发给 WebView。
 *
 * 走 ZXing core（唯一的第三方依赖，607KB jar，纯 Java、无资源、无 .so），
 * 不联网调第三方二维码服务 —— 局域网地址不该发给外部。
 * 站点 CSP 是 img-src 'self' data: blob: https:，data: 图可以直接显示。
 */
public final class QrGen {

    private QrGen() {}

    public static String pngDataUri(String content) {
        try {
            Map<EncodeHintType, Object> hints = new HashMap<>();
            hints.put(EncodeHintType.CHARACTER_SET, "UTF-8");
            hints.put(EncodeHintType.ERROR_CORRECTION, ErrorCorrectionLevel.M);
            hints.put(EncodeHintType.MARGIN, Integer.valueOf(2));

            // width/height 传 0：让 ZXing 按内容选最小版本，手机相机更容易识别
            BitMatrix matrix = new QRCodeWriter()
                    .encode(content, BarcodeFormat.QR_CODE, 0, 0, hints);
            int modules = matrix.getWidth();
            int scale = 8;
            int size = modules * scale;
            int[] pixels = new int[size * size];
            for (int y = 0; y < size; y++) {
                for (int x = 0; x < size; x++) {
                    pixels[y * size + x] = matrix.get(x / scale, y / scale)
                            ? 0xFF101012 : 0xFFFFFFFF;
                }
            }
            Bitmap bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
            bmp.setPixels(pixels, 0, size, 0, 0, size, size);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            bmp.compress(Bitmap.CompressFormat.PNG, 100, out);
            bmp.recycle();
            return "data:image/png;base64,"
                    + Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP);
        } catch (Throwable t) {
            BridgeLog.e("qr", "QR_GEN_FAIL " + t.getMessage());
            return "";
        }
    }
}
