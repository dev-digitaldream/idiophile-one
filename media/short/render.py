#!/usr/bin/env python3
"""Idiophile One — YouTube Short (1080x1920, 30 fps).

Frames are drawn with Pillow and piped to ffmpeg with the soundtrack.
Usage: python3 render.py [--preview SECONDS] [--out FILE]
"""
import math, random, subprocess, sys
from functools import lru_cache
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops

HERE = Path(__file__).resolve().parent
SHOTS = HERE / "shots"
ROOT = HERE.parent.parent
W, H, FPS = 1080, 1920, 30
DURATION = 53.0
MUSIC = Path(next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--music=")), HERE.parent / "triomphe-final.m4a"))
DROP = float(next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--drop=")), 47.0))   # end-card hit
# Soundtrack: one continuous excerpt of the piece, starting so that its big hit (3:01.3)
# lands on the end card. No edit: a crossfade between distant passages sounded wrong.
MUSIC_START = float(next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--music-start=")), 181.3 - DROP))

GREEN = (124, 255, 178)
AMBER = (255, 168, 76)
WHITE = (245, 242, 236)
DIM = (170, 166, 158)

COND = "/System/Library/Fonts/Avenir Next Condensed.ttc"
AVEN = "/System/Library/Fonts/Avenir Next.ttc"
HEAVY, BOLD, DEMI, MEDIUM, REGULAR, ULTRA = 8, 0, 2, 5, 7, 10


@lru_cache(None)
def font(path, index, size):
    return ImageFont.truetype(path, size, index=index)


# ---------------------------------------------------------------- easing
def clamp(x, a=0.0, b=1.0): return max(a, min(b, x))
def out_cubic(x): x = clamp(x); return 1 - (1 - x) ** 3
def out_expo(x): x = clamp(x); return 1 if x >= 1 else 1 - 2 ** (-10 * x)
def in_out(x): x = clamp(x); return x * x * (3 - 2 * x)
def out_back(x, s=1.7):
    x = clamp(x) - 1
    return 1 + (s + 1) * x ** 3 + s * x ** 2
def spring(x):
    x = clamp(x)
    return 1 - math.exp(-6 * x) * math.cos(10 * x)
def window(t, start, end, fade=0.35):
    """1 inside [start, end], with eased fades at both ends."""
    return out_cubic((t - start) / fade) * out_cubic((end - t) / fade)
def lerp(a, b, x): return a + (b - a) * x


# ---------------------------------------------------------------- assets
def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(ImageChops.multiply(out.getchannel("A"), mask))
    return out


def with_shadow(img, blur=40, offset=24, opacity=170, glow=None):
    pad = blur * 2 + offset
    canvas = Image.new("RGBA", (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
    alpha = img.getchannel("A")
    shadow = Image.new("RGBA", img.size, (0, 0, 0, opacity))
    shadow.putalpha(alpha.point(lambda a: a * opacity // 255))
    canvas.alpha_composite(shadow, (pad, pad + offset))
    if glow:
        g = Image.new("RGBA", img.size, glow + (0,))
        g.putalpha(alpha.point(lambda a: a * 90 // 255))
        canvas.alpha_composite(g, (pad, pad))
    canvas = canvas.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(img, (pad, pad))
    return canvas, pad


def load(name):
    return Image.open(SHOTS / name).convert("RGBA")


def blur_box(img, box, radius=26):
    region = img.crop(box).filter(ImageFilter.GaussianBlur(radius))
    img.paste(region, box[:2])
    return img


FACADES = {                                          # unit boxes in the 2240x1808 window capture
    "player": (50, 50, 2190, 498),
    "amp": (50, 549, 2190, 1260),
    "eq": (50, 1308, 2190, 1719),
}
FINISHES = [("champagne", "Champagne"), ("black", "Black"), ("blue-glass", "Blue Glass")]

# Each finish was filmed while playing (app muted: the meters read the signal before the volume).
# The window capture gives the exact shape; filmed pixels are used only where the window is
# fully opaque, so nothing of the desktop behind it can show.
STILL, MASK, LIVE = {}, {}, {}
for slug, _ in FINISHES:
    STILL[slug] = load(f"still-{slug}.png")
    MASK[slug] = STILL[slug].getchannel("A").point(lambda v: 255 if v == 255 else 0).filter(ImageFilter.MinFilter(7))
    LIVE[slug] = sorted((SHOTS / f"live-{slug}").glob("*.jpg"))


@lru_cache(maxsize=6)
def _live(slug, i):
    img = STILL[slug].copy()
    img.paste(Image.open(LIVE[slug][i]).convert("RGBA"), (0, 0), MASK[slug])
    return img


def live_window(slug, t):
    n = len(LIVE[slug])
    k = int(t * FPS) % (2 * n - 2)            # ping-pong: no jump when the recording loops
    return _live(slug, k if k < n else 2 * n - 2 - k)


def live_unit(name, t, slug="blue-glass"):
    return live_window(slug, t).crop(FACADES[name])


COMPACT = blur_box(load("compact.png"), (56, 120, 208, 272), 30)
COMPACT = COMPACT.crop((20, 80, 1076, 310))
EQEDIT = rounded(load("eqeditor-11985.png"), 22)
PATHWIN = rounded(load([p.name for p in SHOTS.glob("audiopath*.png")][0]) if list(SHOTS.glob("audiopath*.png")) else load("eqeditor-11985.png"), 22)
NETWIN = rounded(load("network.png"), 22)
ICON = Image.open(ROOT / "Design/Icon/Icon-Dark-1024.png").convert("RGBA")

# ---------------------------------------------------------------- background
random.seed(7)
_bg_base = Image.new("RGB", (W, H), (8, 8, 10))
_glow = Image.new("RGBA", (W * 2, H * 2), (0, 0, 0, 0))
d = ImageDraw.Draw(_glow)
for r, a in [(900, 18), (700, 26), (500, 34), (320, 40)]:
    d.ellipse((W - r, H - r, W + r, H + r), fill=AMBER + (a,))
_glow = _glow.filter(ImageFilter.GaussianBlur(160))
_glow2 = Image.new("RGBA", (W * 2, H * 2), (0, 0, 0, 0))
d = ImageDraw.Draw(_glow2)
for r, a in [(700, 16), (420, 26)]:
    d.ellipse((W - r, H - r, W + r, H + r), fill=GREEN + (a,))
_glow2 = _glow2.filter(ImageFilter.GaussianBlur(170))
_grain = []
for i in range(6):
    n = Image.effect_noise((W // 2, H // 2), 40).resize((W, H), Image.NEAREST)
    g = Image.new("RGBA", (W, H), (255, 255, 255, 0))
    g.putalpha(n.point(lambda v: max(0, v - 128) // 10))
    _grain.append(g)
# faint horizontal lines, like a brushed faceplate
_lines = Image.new("RGBA", (W, H), (0, 0, 0, 0))
d = ImageDraw.Draw(_lines)
for y in range(0, H, 6):
    d.line((0, y, W, y), fill=(255, 255, 255, 5))


def background(t):
    frame = _bg_base.convert("RGBA")
    x = int(W / 2 + math.sin(t * 0.35) * 260)
    y = int(H * 0.35 + math.cos(t * 0.27) * 300)
    frame.alpha_composite(_glow, (x - W, y - H))
    x2 = int(W / 2 + math.cos(t * 0.22) * 320)
    y2 = int(H * 0.8 + math.sin(t * 0.31) * 200)
    frame.alpha_composite(_glow2, (x2 - W, y2 - H))
    frame.alpha_composite(_lines)
    return frame


# ---------------------------------------------------------------- drawing helpers
def text_img(text, f, fill, tracking=0):
    if tracking == 0:
        box = f.getbbox(text)
        img = Image.new("RGBA", (box[2] - box[0] + 8, box[3] - box[1] + 8), (0, 0, 0, 0))
        ImageDraw.Draw(img).text((4 - box[0], 4 - box[1]), text, font=f, fill=fill)
        return img
    widths = [f.getlength(c) for c in text]
    total = int(sum(widths) + tracking * (len(text) - 1)) + 8
    asc, desc = f.getmetrics()
    img = Image.new("RGBA", (total, asc + desc + 8), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x = 4
    for c, w in zip(text, widths):
        d.text((x, 4), c, font=f, fill=fill)
        x += w + tracking
    return img.crop(img.getbbox() or (0, 0, 1, 1))


def place(frame, img, cx, cy, alpha=1.0, scale=1.0, blur=0.0, anchor="center"):
    if alpha <= 0.004:
        return
    if abs(scale - 1) > 0.003:
        img = img.resize((max(1, int(img.width * scale)), max(1, int(img.height * scale))), Image.BICUBIC)
    if blur > 0.3:
        pad = int(blur * 3)
        big = Image.new("RGBA", (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
        big.alpha_composite(img, (pad, pad))
        img = big.filter(ImageFilter.GaussianBlur(blur))
    if alpha < 0.999:
        a = img.getchannel("A").point(lambda v: int(v * alpha))
        img = img.copy()
        img.putalpha(a)
    x = int(cx - img.width / 2) if anchor == "center" else int(cx)
    y = int(cy - img.height / 2)
    frame.alpha_composite(img, (x, y)) if 0 <= x and 0 <= y and x + img.width <= W and y + img.height <= H \
        else paste_clipped(frame, img, x, y)


def paste_clipped(frame, img, x, y):
    left, top = max(0, -x), max(0, -y)
    right, bottom = min(img.width, W - x), min(img.height, H - y)
    if right <= left or bottom <= top:
        return
    frame.alpha_composite(img.crop((left, top, right, bottom)), (x + left, y + top))


def reveal_text(frame, t, start, text, f, fill, cx, cy, tracking=0, end=None, rise=40):
    """Slides up out of a blur, fades out at `end`."""
    img = cached_text(text, f, fill, tracking)
    p = out_expo((t - start) / 0.7)
    a = p * (out_cubic((end - t) / 0.35) if end else 1)
    place(frame, img, cx, cy + (1 - p) * rise, alpha=a, blur=(1 - p) * 14)


_text_cache = {}
def cached_text(text, f, fill, tracking=0):
    key = (text, id(f), fill, tracking)
    if key not in _text_cache:
        _text_cache[key] = text_img(text, f, fill, tracking)
    return _text_cache[key]


_chip_cache = {}
def chip(label, color=GREEN, size=34):
    key = (label, color, size)
    if key not in _chip_cache:
        f = font(COND, DEMI, size)
        t = text_img(label, f, color, tracking=3)
        w, h = t.width + 56, t.height + 30
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle((0, 0, w - 1, h - 1), h // 2, fill=(14, 16, 15, 215), outline=color + (200,), width=3)
        img.alpha_composite(t, ((w - t.width) // 2, (h - t.height) // 2))
        _chip_cache[key] = img
    return _chip_cache[key]


def camera(frame, img, cx, cy, k, dest=(W / 2, H / 2), alpha=1.0):
    """Draws `img` scaled by k so that its point (cx, cy) lands on `dest`."""
    sx0 = cx - dest[0] / k; sy0 = cy - dest[1] / k
    sx1 = cx + (W - dest[0]) / k; sy1 = cy + (H - dest[1]) / k
    box = (max(0, sx0), max(0, sy0), min(img.width, sx1), min(img.height, sy1))
    if box[2] <= box[0] or box[3] <= box[1]:
        return
    region = img.crop(tuple(int(v) for v in box))
    size = (max(1, int((box[2] - box[0]) * k)), max(1, int((box[3] - box[1]) * k)))
    region = region.resize(size, Image.BICUBIC)
    if alpha < 0.999:
        region.putalpha(region.getchannel("A").point(lambda v: int(v * alpha)))
    x = int((box[0] - sx0) * k); y = int((box[1] - sy0) * k)
    paste_clipped(frame, region, x, y)


# ---------------------------------------------------------------- scenes
def scene_title(f, t):
    """0 – 4.3 s: the name, letter by letter."""
    if t > 4.4:
        return
    out = out_cubic((4.3 - t) / 0.5)
    word = "IDIOPHILE"
    big = font(COND, HEAVY, 190)
    widths = [big.getlength(c) + 10 for c in word]
    x = W / 2 - sum(widths) / 2
    for i, c in enumerate(word):
        p = spring((t - 0.25 - i * 0.07) / 0.9)
        place(f, cached_text(c, big, WHITE), x + widths[i] / 2, 760 + (1 - p) * 120,
              alpha=clamp(p * 1.4) * out, blur=(1 - clamp(p)) * 10)
        x += widths[i]
    p = out_expo((t - 1.0) / 0.9)
    place(f, cached_text("ONE", font(COND, ULTRA, 150), AMBER, tracking=40), W / 2, 935,
          alpha=p * out, scale=lerp(1.25, 1, p), blur=(1 - p) * 12)
    p = out_expo((t - 1.4) / 1.0)
    if p > 0:
        ImageDraw.Draw(f).line((W / 2 - 300 * p, 1040, W / 2 + 300 * p, 1040), fill=GREEN + (int(220 * out),), width=3)
    reveal_text(f, t, 1.8, "The audiophile player", font(AVEN, DEMI, 58), WHITE, W / 2, 1130, end=4.3)
    reveal_text(f, t, 2.05, "free and open source, for Mac", font(AVEN, REGULAR, 54), DIM, W / 2, 1205, end=4.3)


def scene_rack(f, t):
    """4 – 10.4 s: the whole stack, live."""
    s, e = 4.0, 10.4
    if not (s - 0.1 <= t <= e + 0.4):
        return
    a = window(t, s, e, 0.45)
    p = out_expo((t - s) / 1.2)
    k = lerp(0.36, 0.45, in_out((t - s) / (e - s)))
    rack = live_window("blue-glass", t)
    camera(f, rack, rack.width / 2, rack.height / 2, k, dest=(W / 2, 1010 + (1 - p) * 220), alpha=a)
    reveal_text(f, t, s + 0.4, "A real hi-fi stack", font(COND, HEAVY, 112), WHITE, W / 2, 330, end=e)
    reveal_text(f, t, s + 0.65, "on your screen", font(COND, MEDIUM, 80), AMBER, W / 2, 440, end=e)
    for i, label in enumerate(["NETWORK PLAYER", "INTEGRATED AMP · VU METERS", "EQUALIZER"]):
        st = s + 1.6 + i * 0.35
        q = out_back((t - st) / 0.6)
        place(f, chip(label), W / 2, 1530 + i * 92, alpha=clamp((t - st) / 0.3) * a, scale=lerp(0.6, 1, clamp(q)))


FACADE_TEXT = {
    "player": ("Network player", "Library · internet radio · DLNA / UPnP"),
    "amp": ("Integrated amp", "Moving-needle VU meters · DAC volume"),
    "eq": ("Equalizer", "10-band graphic or parametric"),
}


def scene_facades(f, t):
    """10.2 – 20.25 s: the camera flies over each unit."""
    s, span = 10.2, 3.35
    if not (s - 0.2 <= t <= s + span * 3 + 0.4):
        return
    i = min(2, max(0, int((t - s) // span)))
    lt = t - s - i * span
    name = ["player", "amp", "eq"][i]
    unit = live_unit(name, t)
    k = 1750 / unit.width
    cx = lerp(W / 2 / k - 30, unit.width - W / 2 / k + 30, in_out(lt / span))
    a = window(t, s + i * span, s + (i + 1) * span, 0.3)
    p = out_expo(lt / 0.7)
    camera(f, unit, cx, unit.height / 2, k * lerp(1.08, 1.0, p), dest=(W / 2 + (1 - p) * 120, 1020), alpha=a)
    place(f, cached_text(f"0{i + 1}", font(COND, ULTRA, 170), GREEN, tracking=6), W / 2, 330 + (1 - p) * 40,
          alpha=p * a, blur=(1 - p) * 10)
    title, sub = FACADE_TEXT[name]
    reveal_text(f, t, s + i * span + 0.15, title, font(COND, HEAVY, 112), WHITE, W / 2, 500, end=s + (i + 1) * span)
    reveal_text(f, t, s + i * span + 0.35, sub, font(AVEN, MEDIUM, 42), AMBER, W / 2, 600, end=s + (i + 1) * span)
    d = ImageDraw.Draw(f)
    for j in range(3):
        x = W / 2 - 150 + j * 105
        d.rounded_rectangle((x, 1500, x + 90, 1508), 4,
                            fill=GREEN + (int(230 * a),) if j <= i else (255, 255, 255, int(50 * a)))


def scene_finishes(f, t):
    """20.2 – 26.6 s: three finishes, each one live, sliding in."""
    s, span = 20.2, 2.1
    e = s + span * 3
    if not (s - 0.1 <= t <= e + 0.4):
        return
    a = window(t, s, e, 0.35)
    reveal_text(f, t, s + 0.1, "Pick your finish", font(COND, HEAVY, 116), WHITE, W / 2, 330, end=e)
    i = min(2, max(0, int((t - s) // span)))
    lt = t - s - i * span
    k = 0.47
    for j in (i - 1, i):                      # outgoing one slides left while the next arrives
        if j < 0:
            continue
        slug, label = FINISHES[j]
        img = live_window(slug, t)
        if j == i:
            p = out_expo(lt / 0.7) if i > 0 else 1.0
            x = W / 2 + (1 - p) * W
        else:
            p = out_expo(lt / 0.7)
            x = W / 2 - p * W
        camera(f, img, img.width / 2, img.height / 2, k, dest=(x, 1000), alpha=a)
    slug, label = FINISHES[i]
    q = out_back(lt / 0.55)
    place(f, chip(label.upper(), AMBER if slug != "blue-glass" else GREEN, 42), W / 2, 1530,
          alpha=clamp(lt / 0.25) * a, scale=lerp(0.6, 1, clamp(q)))


@lru_cache(None)
def card(name):
    img = {"compact": COMPACT, "eq": EQEDIT, "path": PATHWIN, "net": NETWIN}[name]
    return with_shadow(img, blur=36, offset=26, glow=AMBER if name == "eq" else GREEN)


def float_card(f, t, name, start, end, width, cy):
    img, pad = card(name)
    k = width / (img.width - pad * 2)
    p = out_expo((t - start) / 0.9)
    drift = math.sin((t - start) * 0.9) * 10
    place(f, img, W / 2, cy + (1 - p) * 260 + drift, alpha=window(t, start, end, 0.4), scale=k * lerp(0.9, 1, p))


def pop_chips(f, t, start, end, labels, y, color=GREEN, size=30, spacing=320):
    x0 = W / 2 - spacing * (len(labels) - 1) / 2
    for i, label in enumerate(labels):
        st = start + i * 0.3
        place(f, chip(label, color, size), x0 + i * spacing, y, alpha=clamp((t - st) / 0.3) * window(t, start - 1, end),
              scale=lerp(0.5, 1, clamp(out_back((t - st) / 0.6))))


def scene_compact(f, t):
    s, e = 26.5, 29.9
    if not (s - 0.1 <= t <= e + 0.4):
        return
    float_card(f, t, "compact", s, e, 1000, 980)
    reveal_text(f, t, s + 0.2, "Compact mode", font(COND, HEAVY, 120), WHITE, W / 2, 470, end=e)
    reveal_text(f, t, s + 0.45, "Stays on top while you work", font(AVEN, MEDIUM, 48), DIM, W / 2, 580, end=e)
    pop_chips(f, t, s + 1.0, e, ["≈ 2 % CPU"], 1360, AMBER, 44)


def scene_network(f, t):
    s, e = 29.8, 33.5
    if not (s - 0.1 <= t <= e + 0.4):
        return
    float_card(f, t, "net", s, e, 960, 1080)
    reveal_text(f, t, s + 0.2, "Your NAS, streamed", font(COND, HEAVY, 112), WHITE, W / 2, 330, end=e)
    reveal_text(f, t, s + 0.45, "DLNA / UPnP servers · lossless FLAC", font(AVEN, MEDIUM, 42), AMBER, W / 2, 435, end=e)


def scene_eq(f, t):
    s, e = 33.4, 37.5
    if not (s - 0.1 <= t <= e + 0.4):
        return
    float_card(f, t, "eq", s, e, 960, 1060)
    reveal_text(f, t, s + 0.2, "Parametric EQ", font(COND, HEAVY, 116), WHITE, W / 2, 300, end=e)
    reveal_text(f, t, s + 0.45, "AutoEq headphone profiles · level-matched A/B", font(AVEN, MEDIUM, 38), AMBER, W / 2, 400, end=e)
    pop_chips(f, t, s + 1.3, e, ["20 FILTERS", "DOUBLE PRECISION", "CLICK-FREE"], 1620)


def scene_path(f, t):
    s, e = 37.4, 40.5
    if not (s - 0.1 <= t <= e + 0.4):
        return
    float_card(f, t, "path", s, e, 640, 1080)
    reveal_text(f, t, s + 0.2, "Bit-perfect", font(COND, HEAVY, 130), GREEN, W / 2, 300, end=e)
    reveal_text(f, t, s + 0.45, "proven, not promised", font(COND, MEDIUM, 74), WHITE, W / 2, 410, end=e)


FEATURES = ["FLAC · ALAC · WAV", "Hi-res internet radio", "Exclusive DIRECT mode", "No ads. No account."]


def scene_features(f, t):
    s, step = 40.5, 0.75
    if not (s <= t <= s + step * len(FEATURES) + 0.2):
        return
    i = min(len(FEATURES) - 1, int((t - s) // step))
    lt = t - s - i * step
    p = out_back(lt / 0.35, 2.2)
    a = clamp(lt / 0.12) * clamp((step - lt) / 0.12)
    color = [WHITE, AMBER, GREEN, AMBER][i]
    size = 118 if len(FEATURES[i]) < 18 else 96
    place(f, cached_text(FEATURES[i], font(COND, HEAVY, size), color), W / 2, 960, alpha=a,
          scale=lerp(0.7, 1, clamp(p)) * (1 + 0.04 * lt))
    reveal_text(f, t, s, "AND MORE", font(COND, DEMI, 44), DIM, W / 2, 800, end=s + step * len(FEATURES))


@lru_cache(None)
def ipad_frame():
    """A plain tablet outline around the stack: a concept, labelled as coming soon."""
    shot = STILL["blue-glass"]
    sw = 1400
    screen = shot.resize((sw, int(shot.height * sw / shot.width)), Image.LANCZOS)
    pad = 60
    bw, bh = int(screen.width / 0.85), int(screen.height / 0.85 * 0.96)
    dev = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))
    d = ImageDraw.Draw(dev)
    d.rounded_rectangle((0, 0, bw - 1, bh - 1), 70, fill=(24, 24, 26, 255), outline=(120, 120, 126, 255), width=6)
    d.rounded_rectangle((pad, pad, bw - pad, bh - pad), 26, fill=(4, 4, 6, 255))
    dev.alpha_composite(screen, ((bw - screen.width) // 2, (bh - screen.height) // 2))
    return with_shadow(dev, blur=50, offset=30, glow=GREEN)


def scene_ipad(f, t):
    s, e = DROP - 3.6, DROP - 0.1
    if not (s - 0.1 <= t <= e + 0.3):
        return
    img, pad = ipad_frame()
    p = out_expo((t - s) / 1.0)
    k = 940 / (img.width - pad * 2)
    place(f, img, W / 2, 1060 + (1 - p) * 300 + math.sin(t) * 8, alpha=window(t, s, e, 0.35), scale=k * lerp(0.85, 1, p))
    reveal_text(f, t, s + 0.2, "Coming soon", font(COND, HEAVY, 124), WHITE, W / 2, 380, end=e)
    reveal_text(f, t, s + 0.45, "iPad · USB-C DAC", font(COND, MEDIUM, 80), GREEN, W / 2, 500, end=e)


def scene_end(f, t):
    s = DROP
    if t < s - 0.1:
        return
    lt = t - s
    if lt < 0.5:
        f.alpha_composite(Image.new("RGBA", (W, H), (255, 236, 210, int(170 * (1 - out_cubic(lt / 0.5))))))
    p = spring(lt / 1.1)
    icon_k = 520 / ICON.width
    place(f, glow_icon(), W / 2, 720, alpha=out_cubic(lt / 1.2) * 0.9, scale=icon_k * lerp(0.6, 1.0, clamp(p)))
    place(f, ICON, W / 2, 720, alpha=clamp(lt / 0.25), scale=icon_k * lerp(0.6, 1.0, p))
    reveal_text(f, t, s + 0.45, "IDIOPHILE ONE", font(COND, HEAVY, 128), WHITE, W / 2, 1110, tracking=8)
    reveal_text(f, t, s + 0.75, "Free · Open source · macOS", font(AVEN, DEMI, 46), AMBER, W / 2, 1215)
    q = out_back((t - s - 1.2) / 0.6)
    place(f, chip("GPL-3.0", GREEN, 34), W / 2, 1330, alpha=clamp((t - s - 1.2) / 0.3), scale=lerp(0.5, 1, clamp(q)))
    if t > DURATION - 1.0:
        f.alpha_composite(Image.new("RGBA", (W, H), (0, 0, 0, int(255 * in_out((t - DURATION + 1.0) / 1.0)))))


@lru_cache(None)
def glow_icon():
    g = Image.new("RGBA", (ICON.width + 400, ICON.height + 400), (0, 0, 0, 0))
    layer = Image.new("RGBA", ICON.size, AMBER + (0,))
    layer.putalpha(ICON.getchannel("A").point(lambda v: v * 200 // 255))
    g.alpha_composite(layer, (200, 200))
    return g.filter(ImageFilter.GaussianBlur(90))


SCENES = [scene_title, scene_rack, scene_facades, scene_finishes, scene_compact, scene_network, scene_eq, scene_path,
          scene_features, scene_ipad, scene_end]


def render_frame(t):
    f = background(t)
    for scene in SCENES:
        scene(f, t)
    f.alpha_composite(_grain[int(t * FPS) % len(_grain)])
    return f.convert("RGB")


def main():
    args = sys.argv[1:]
    out = HERE / "idiophile-one-short.mp4"
    if "--out" in args:
        out = Path(args[args.index("--out") + 1])
    if "--still" in args:                     # one PNG per given time, for checking layouts
        for s in args[args.index("--still") + 1].split(","):
            render_frame(float(s)).save(HERE / f"still-{s}.png")
        return
    duration = DURATION
    if "--preview" in args:
        duration = float(args[args.index("--preview") + 1])
    cmd = ["ffmpeg", "-v", "error", "-y",
           "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
           "-ss", "0", "-i", str(MUSIC),
           "-filter_complex",
           f"[1:a]atrim={MUSIC_START}:{MUSIC_START + duration},asetpts=PTS-STARTPTS,"
           f"afade=t=in:d=0.6,afade=t=out:st={duration - 2.5}:d=2.5,loudnorm=I=-14:TP=-1.5:LRA=11[a]",
           "-map", "0:v", "-map", "[a]",
           "-c:v", "libx264", "-preset", "slow", "-crf", "17", "-pix_fmt", "yuv420p", "-profile:v", "high",
           "-movflags", "+faststart", "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-shortest", str(out)]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    frames = int(duration * FPS)
    for n in range(frames):
        proc.stdin.write(render_frame(n / FPS).tobytes())
        if n % 60 == 0:
            print(f"{n / FPS:5.1f}s", file=sys.stderr, flush=True)
    proc.stdin.close()
    proc.wait()
    print(out)


if __name__ == "__main__":
    main()
