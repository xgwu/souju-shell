#!/usr/bin/env python3
"""生成电视版启动图标，只用 Python 标准库（zlib + struct），不依赖 Pillow。

设计：墨玉底圆角方 → 橙色圆盘 → 暖白播放三角。与 iOS 版深色皮肤的色板一致。
输出 192×192 RGBA PNG，供 aapt2 作为 @mipmap/ic_launcher 编译。
"""
import math
import pathlib
import struct
import zlib

W = H = 192
R_CORNER = 42
BG = (14, 14, 16)        # #0E0E10 墨玉
ORANGE = (255, 138, 61)  # #FF8A3D
WARM = (242, 241, 237)   # #F2F1ED 暖白

# 播放三角顶点
TRI = ((80.0, 62.0), (80.0, 130.0), (134.0, 96.0))


def in_rounded_rect(x, y):
    dx = max(R_CORNER - x, x - (W - 1 - R_CORNER), 0)
    dy = max(R_CORNER - y, y - (H - 1 - R_CORNER), 0)
    return dx * dx + dy * dy <= R_CORNER * R_CORNER


def sign(p1, p2, p3, x, y):
    return ((p1[0] - p3[0]) * (y - p3[1])
            - (x - p3[0]) * (p2[1] - p3[1]))


def in_triangle(x, y):
    a, b, c = TRI
    d1, d2, d3 = sign(a, b, c, x, y), sign(b, c, a, x, y), sign(c, a, b, x, y)
    has_neg = d1 < 0 or d2 < 0 or d3 < 0
    has_pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (has_neg and has_pos)


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def build():
    rows = []
    for y in range(H):
        row = bytearray()
        for x in range(W):
            if not in_rounded_rect(x, y):
                row.extend((0, 0, 0, 0))
                continue
            rgb = BG
            if math.hypot(x - 96, y - 96) <= 62:
                rgb = ORANGE
            if in_triangle(x, y):
                rgb = WARM
            row.extend((*rgb, 255))
        rows.append(bytes(row))

    raw = b"".join(b"\x00" + r for r in rows)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


if __name__ == "__main__":
    out = pathlib.Path(__file__).resolve().parents[1] / "tv/res/mipmap-mdpi/ic_launcher.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(build())
    print(f"✓ {out}  {out.stat().st_size} bytes  {W}×{H} RGBA")
