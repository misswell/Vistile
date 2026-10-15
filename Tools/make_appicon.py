#!/usr/bin/env python3
"""生成 Resources/Assets.xcassets/AppIcon.appiconset 的位图与 Contents.json。

纯标准库实现（zlib + struct），不引入外部依赖。图形沿用方案 §13 的方向：
2×2 格子里有一格向外扩成窗口轮廓，深色底、无厚渐变、无 3D 光影。
"""
import json
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "Resources", "Assets.xcassets", "AppIcon.appiconset")
CANVAS = 1024

BG_TOP = (30, 36, 52)
BG_BOTTOM = (14, 17, 26)
CELL = (226, 231, 242)
EXPANDED = (96, 158, 255)
TITLEBAR = (58, 116, 214)


def mix(a, b, t):
    if t >= 1:
        return b
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def coverage(x, y, rect, radius):
    """圆角矩形覆盖率，边缘 1px 渐变用于抗锯齿。"""
    left, top, right, bottom = rect
    if x < left or x > right or y < top or y > bottom:
        return 0.0
    cx = min(max(x, left + radius), right - radius)
    cy = min(max(y, top + radius), bottom - radius)
    dx = abs(x - cx) - radius
    dy = abs(y - cy) - radius
    if dx <= 0 or dy <= 0:
        return 1.0
    return max(0.0, min(1.0, (dx * dx + dy * dy) ** 0.5 - radius + 0.5))


def render(size):
    s = float(size)
    pad = 0.085 * s
    body = (pad, pad, s - pad, s - pad)
    radius = 0.225 * s
    gap = 0.035 * s
    inset = 0.135 * s
    inner = (pad + inset, pad + inset, s - pad - inset, s - pad - inset)
    cell_w = (inner[2] - inner[0] - gap) / 2
    cell_h = (inner[3] - inner[1] - gap) / 2
    corner = min(gap, cell_w * 0.14)
    cells = [
        (inner[0], inner[1], inner[0] + cell_w, inner[1] + cell_h),
        (inner[0], inner[1] + cell_h + gap, inner[0] + cell_w, inner[3]),
        (inner[0] + cell_w + gap, inner[1] + cell_h + gap, inner[2], inner[3]),
    ]
    # 右上角扩出的窗口：比格子更大并压在网格之上，表示"这一格被放大成真实窗口"。
    expanded = (inner[0] + cell_w + gap, inner[1] - 0.055 * s, inner[2] + 0.02 * s, inner[1] + cell_h + 0.02 * s)
    title_bar = (expanded[0], expanded[1], expanded[2], expanded[1] + 0.05 * s)

    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            color = mix(BG_TOP, BG_BOTTOM, y / s)
            alpha = coverage(x, y, body, radius)
            for rect in cells:
                cover = coverage(x, y, rect, corner)
                if cover > 0:
                    color = mix(color, CELL, cover * alpha)
            cover = coverage(x, y, expanded, corner)
            if cover > 0:
                color = mix(color, EXPANDED, cover * alpha)
            bar = coverage(x, y, title_bar, corner * 0.6)
            if bar > 0:
                color = mix(color, TITLEBAR, bar * alpha)
            row.append(tuple(max(0, min(255, round(v))) for v in color) + (round(255 * alpha),))
        rows.append(row)
    return rows


def downsample(image, size):
    src = len(image)
    factor = src / size
    result = []
    for y in range(size):
        row = []
        y0 = int(y * factor)
        y1 = max(y0 + 1, int((y + 1) * factor))
        for x in range(size):
            x0 = int(x * factor)
            x1 = max(x0 + 1, int((x + 1) * factor))
            count = (y1 - y0) * (x1 - x0)
            acc = [0, 0, 0, 0]
            for yy in range(y0, min(y1, src)):
                for xx in range(x0, min(x1, src)):
                    pixel = image[yy][xx]
                    for i in range(4):
                        acc[i] += pixel[i]
            row.append([v / count for v in acc])
        result.append(row)
    return result


def write_png(path, image):
    size = len(image)
    raw = bytearray()
    for row in image:
        raw.append(0)
        raw += bytes(int(v) for pixel in row for v in pixel)

    def chunk(kind, data):
        payload = kind + data
        return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
                     + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


SPEC = [
    (16, "icon_16x16.png", "16x16", 1),
    (32, "icon_16x16@2x.png", "16x16", 2),
    (32, "icon_32x32.png", "32x32", 1),
    (64, "icon_32x32@2x.png", "32x32", 2),
    (128, "icon_128x128.png", "128x128", 1),
    (256, "icon_128x128@2x.png", "128x128", 2),
    (256, "icon_256x256.png", "256x256", 1),
    (512, "icon_256x256@2x.png", "256x256", 2),
    (512, "icon_512x512.png", "512x512", 1),
    (1024, "icon_512x512@2x.png", "512x512", 2),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    full = render(CANVAS)
    cache = {CANVAS: full}
    entries = []
    for size, name, subtype, scale in SPEC:
        if size not in cache:
            cache[size] = downsample(full, size)
        write_png(os.path.join(OUT, name), cache[size])
        entries.append({"size": subtype, "scale": "%dx" % scale, "filename": name, "idiom": "mac"})
    with open(os.path.join(OUT, "Contents.json"), "w", encoding="utf-8") as handle:
        json.dump({"images": entries, "info": {"version": 1, "author": "Xcode"}}, handle, indent=2)
        handle.write("\n")
    catalog = os.path.dirname(os.path.dirname(OUT))
    with open(os.path.join(catalog, "Contents.json"), "w", encoding="utf-8") as handle:
        json.dump({"info": {"version": 1, "author": "Xcode"}}, handle, indent=2)
        handle.write("\n")
    print("AppIcon ->", OUT)


if __name__ == "__main__":
    main()
