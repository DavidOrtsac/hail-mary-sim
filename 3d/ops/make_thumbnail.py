#!/usr/bin/env python3
# EARTHSHINE YouTube thumbnail. Full-bleed Earth, heavy condensed wordmark in the
# black headroom, short tagline, small LIVE pill. No clutter, no AI-cheese.
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os

SRC = "/Users/davidcastro/.claude/image-cache/1d9b425f-05d3-4b03-879d-3b4833b88a02/11.png"
OUT = "/Users/davidcastro/Desktop/hail-mary-sim/3d/ops/earthshine_thumbnail.png"
W, H = 1280, 720
AMBER = (255, 186, 92)
WHITE = (250, 252, 255)

FC = "/System/Library/Fonts/Avenir Next Condensed.ttc"
F_MARK = ImageFont.truetype(FC, 116, index=8)   # Heavy
F_TAG  = ImageFont.truetype(FC, 32,  index=2)   # Demi Bold
F_LIVE = ImageFont.truetype(FC, 26,  index=8)   # Heavy

# Base: scale source to full width, paste bottom-aligned so the (black) space at
# the top gives clean headroom for the wordmark. Top pad is pure black = seamless.
src = Image.open(SRC).convert("RGB")
sw, sh = src.size
img_h = round(sh * (W / sw))
base = Image.new("RGB", (W, H), (0, 0, 0))
base.paste(src.resize((W, img_h), Image.LANCZOS), (0, H - img_h))

def width_tracked(text, font, tr):
    return sum(font.getlength(c) for c in text) + tr * (len(text) - 1)

def draw_tracked(d, cx, y, text, font, fill, tr):
    x = cx - width_tracked(text, font, tr) / 2
    for c in text:
        d.text((x, y), c, font=font, fill=fill, anchor="lt")
        x += font.getlength(c) + tr

MARK_Y, TAG_Y = 30, 158

# Soft shadow for legibility in case text grazes the limb glow.
sh_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
sd = ImageDraw.Draw(sh_layer)
draw_tracked(sd, 640 + 2, MARK_Y + 3, "EARTHSHINE",       F_MARK, (0, 0, 0, 165), 14)
draw_tracked(sd, 640 + 2, TAG_Y + 2,  "EARTH FROM SPACE", F_TAG,  (0, 0, 0, 150), 12)
base.paste(sh_layer.filter(ImageFilter.GaussianBlur(8)), (0, 0), sh_layer.filter(ImageFilter.GaussianBlur(8)))

d = ImageDraw.Draw(base)
draw_tracked(d, 640, MARK_Y, "EARTHSHINE",       F_MARK, WHITE, 14)
draw_tracked(d, 640, TAG_Y,  "EARTH FROM SPACE", F_TAG,  AMBER, 12)

# LIVE pill, top-right.
ltxt, tr = "LIVE", 2
twid = width_tracked(ltxt, F_LIVE, tr)
dot_r, gap, padx, pill_h = 7, 11, 17, 40
pill_w = padx * 2 + dot_r * 2 + gap + twid
px2, py1 = W - 30, 30
px1, py2 = px2 - pill_w, 30 + pill_h
cy = (py1 + py2) // 2
d.rounded_rectangle([px1, py1, px2, py2], radius=pill_h // 2, fill=(226, 43, 37))
dx = px1 + padx + dot_r
d.ellipse([dx - dot_r, cy - dot_r, dx + dot_r, cy + dot_r], fill=(255, 255, 255))
x = dx + dot_r + gap
for c in ltxt:
    d.text((x, cy), c, font=F_LIVE, fill=(255, 255, 255), anchor="lm")
    x += F_LIVE.getlength(c) + tr

base.save(OUT, "PNG", optimize=True)
# JPG fallback in case the PNG tops YouTube's 2 MB thumbnail cap.
base.save(OUT.replace(".png", ".jpg"), "JPEG", quality=90)
print("PNG", round(os.path.getsize(OUT) / 1024 / 1024, 2), "MB",
      "| JPG", round(os.path.getsize(OUT.replace('.png', '.jpg')) / 1024, 0), "KB", "|", base.size)
