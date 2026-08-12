#!/usr/bin/env python3
"""Composite the REAL sim status bar (top of a live By-the-Numbers screenshot, over the grey page)
onto the tall ImageRenderer export, then trim the bottom. Result has a status bar matching the
hero shots, not the ImageRenderer mock.

Usage: python3 composite_bynumbers.py <live_strip_px> <export_skip_px>
  live_strip_px : rows taken from the top of the live screenshot (the real status bar)
  export_skip_px: rows skipped at the top of the export (its mock status bar)
"""
import sys
from PIL import Image

LIVE = "/tmp/bn_live4.png"
EXPORT = "/tmp/bn_export3.png"
OUT = "site/assets/bynumbers_full.jpg"
LIVE_STRIP = int(sys.argv[1]) if len(sys.argv) > 1 else 162
EXPORT_SKIP = int(sys.argv[2]) if len(sys.argv) > 2 else 192


def trim_bottom(img):
    w, h = img.size
    px = img.load()
    bg = px[6, h // 2]
    y = h - 1
    while y > h - 80:
        if all(abs(px[x, y][c] - bg[c]) < 12 for x in (6, w // 2, w - 7) for c in range(3)):
            break
        y -= 1
    return img.crop((0, 0, w, y + 1))


def main():
    live = Image.open(LIVE).convert("RGB")
    export = Image.open(EXPORT).convert("RGB")
    ew, eh = export.size
    lw, lh = live.size
    if lw != ew:
        live = live.resize((ew, round(lh * ew / lw)))
        lw, lh = live.size
    print(f"live {lw}x{lh}  export {ew}x{eh}  live_strip={LIVE_STRIP} export_skip={EXPORT_SKIP}")
    top = live.crop((0, 0, ew, LIVE_STRIP))
    body = export.crop((0, EXPORT_SKIP, ew, eh))
    out = Image.new("RGB", (ew, LIVE_STRIP + body.size[1]), (242, 242, 247))
    out.paste(top, (0, 0))
    out.paste(body, (0, LIVE_STRIP))
    out = trim_bottom(out)
    out.save(OUT, quality=92)
    print(f"wrote {OUT}  {out.size[0]}x{out.size[1]}")
    print(f"CSS aspect-ratio: {out.size[0]}/{out.size[1]}")


if __name__ == "__main__":
    main()
