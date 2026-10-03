# Burrow brand pipeline: pure numpy helpers (no Blender imports), shared by build.py.
# Images are float32 arrays in sRGB [0,1], HxWx4 straight alpha unless noted.
import math, struct, zlib
import numpy as np

# ---------------------------------------------------------------- palette (sRGB 0..1)
def hx(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)], np.float32)

def lin(c):
    c = np.asarray(c, np.float64)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)

NIGHT, BURROW, VELVET = hx("15111B"), hx("231B2B"), hx("3A2E45")
LANTERN, EMBER, MINT, CREAM, INK = hx("FFB23F"), hx("F2703A"), hx("3DDC97"), hx("FFF4E2"), hx("1E1826")
BLACK = np.zeros(3, np.float32)

# ---------------------------------------------------------------- the mark
# One drawing drives everything: a round-topped arch (outer radius Ro, opening radius Ri, both
# centred on the spring point) standing on a baseline, with a round lantern dot of radius Rd
# floating inside the opening, its centre DOT_H of the opening height above the baseline.
# Units: Ro = 0.64. Stroke (crown = legs) = Ro - Ri = 0.31.
MARK = dict(Ro=0.64, Ri=0.33, leg=0.56, Rd=0.125)
DOT_H = 0.47

def sd_door(x, y, r, cy, base):
    """Signed distance to a doorway: half disc of radius r centred at (0, cy), plus the
    rectangle |x|<=r from cy down to base. y grows DOWN (image space), so base > cy."""
    d_circle = np.sqrt(x ** 2 + (y - cy) ** 2) - r
    qx = np.abs(x) - r
    qy = np.maximum(cy - y, y - base)
    d_rect = np.sqrt(np.maximum(qx, 0) ** 2 + np.maximum(qy, 0) ** 2) + np.minimum(np.maximum(qx, qy), 0)
    return np.minimum(d_circle, d_rect)

def dot_y(cy, Ri, base):
    """Centre (y down) of the lantern dot: DOT_H of the way up the opening."""
    return base - DOT_H * (base - (cy - Ri))

def sd_mark_parts(X, Y, cx, cy, Ro, Ri, base, Rd, dy=None):
    """Signed distances (pixels) of the arch ring and the lantern dot. y down."""
    x = X - cx
    dy = dot_y(cy, Ri, base) if dy is None else dy
    ring = np.maximum(sd_door(x, Y, Ro, cy, base), -sd_door(x, Y, Ri, cy, base + 4 * Ro))
    dot = np.sqrt(x ** 2 + (Y - dy) ** 2) - Rd
    return ring, dot

def grid(w, h, ss):
    xs = (np.arange(w * ss) + 0.5) / ss
    ys = (np.arange(h * ss) + 0.5) / ss
    return np.meshgrid(xs, ys)

def down(a, ss):
    h, w = a.shape[0] // ss, a.shape[1] // ss
    return a.reshape(h, ss, w, ss, *a.shape[2:]).mean(axis=(1, 3))

def mark_alpha(w, h, cx, cy, Ro, Ri, base, Rd, dy=None, ss=8, parts=False):
    """Coverage of the mark in a w x h image, geometry given in pixel units.
    Straight edges land exactly where the numbers say, so integer values give crisp pixels."""
    X, Y = grid(w, h, ss)
    ring, dot = sd_mark_parts(X, Y, cx, cy, Ro, Ri, base, Rd, dy)
    r = down((ring <= 0).astype(np.float32), ss)
    s = down((dot <= 0).astype(np.float32), ss)
    if parts:
        return r, s
    return np.clip(r + s, 0, 1)

def mark_fit(size, unit, cx=None, top=None):
    """Mark geometry scaled so Ro = unit*MARK['Ro'], centred in a size x size canvas."""
    m = MARK
    Ro, Ri, leg, Rd = (m[k] * unit for k in ("Ro", "Ri", "leg", "Rd"))
    H = Ro + leg
    cx = size / 2 if cx is None else cx
    top = (size - H) / 2 if top is None else top
    return dict(cx=cx, cy=top + Ro, Ro=Ro, Ri=Ri, base=top + Ro + leg, Rd=Rd)

# ---------------------------------------------------------------- PNG io
def quantise(img, dither=False, seed=0):
    f = np.asarray(img, np.float64) * 255
    if dither is not False and dither is not None:
        rng = np.random.default_rng(seed)
        n = rng.random(f.shape[:2] + (3,)) - rng.random(f.shape[:2] + (3,))   # -1..1 LSB, triangular
        if not isinstance(dither, bool):
            n *= np.asarray(dither)[..., None]
        if f.ndim == 3:
            f = f.copy()
            f[..., :3] += n
    return np.clip(np.floor(f + 0.5), 0, 255).astype(np.uint8)

def write_png(path, img, dither=False, seed=0):
    """8-bit PNG. dither=True adds triangular (TPDF) noise to the colour channels before
    quantising, so smooth dark gradients do not band; alpha is never dithered. dither may also be
    an (h, w) array that weights the noise per pixel (0 leaves a pixel exact); large images are
    then quantised in strips to bound memory."""
    if isinstance(dither, np.ndarray):
        step = 256
        a = np.concatenate([quantise(img[y:y + step], dither[y:y + step], seed + y)
                            for y in range(0, img.shape[0], step)])
    else:
        a = quantise(img, dither, seed)
    if a.ndim == 2:
        a = a[..., None]
    h, w, c = a.shape
    ct = {1: 0, 2: 4, 3: 2, 4: 6}[c]
    raw = b"".join(b"\x00" + a[y].tobytes() for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    # sRGB chunk so viewers do not colour-manage the values
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ct, 0, 0, 0))
                + chunk(b"sRGB", b"\x00") + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

# ---------------------------------------------------------------- filters and resampling
def box_blur(a, r, axis):
    if r < 1:
        return a
    pad = [(0, 0)] * a.ndim
    pad[axis] = (r + 1, r)
    p = np.pad(a, pad, mode="edge")
    c = np.cumsum(p, axis=axis, dtype=np.float64)
    n = a.shape[axis]
    hi = np.take(c, np.arange(2 * r + 1, 2 * r + 1 + n), axis=axis)
    lo = np.take(c, np.arange(0, n), axis=axis)
    return ((hi - lo) / (2 * r + 1)).astype(np.float32)

def blur(a, sigma):
    """~Gaussian blur (three box passes)."""
    r = max(1, int(round(sigma * 0.93)))
    for _ in range(3):
        a = box_blur(a, r, 0)
        a = box_blur(a, r, 1)
    return a

def squircle(size_w, body, n=5.0, ss=4, cx=None, cy=None, size_h=None):
    """Continuous-corner (superellipse) mask of side `body` (macOS icon shape)."""
    size_h = size_h or size_w
    cx = size_w / 2 if cx is None else cx
    cy = size_h / 2 if cy is None else cy
    X, Y = grid(size_w, size_h, ss)
    m = ((np.abs((X - cx) / (body / 2)) ** n + np.abs((Y - cy) / (body / 2)) ** n) <= 1).astype(np.float32)
    return down(m, ss)

def premul(img):
    o = img.copy()
    o[..., :3] *= o[..., 3:4]
    return o

def unpremul(img):
    o = img.copy()
    a = o[..., 3:4]
    o[..., :3] = np.where(a > 1e-6, o[..., :3] / np.maximum(a, 1e-6), 0)
    return o

def resize(img, w, h=None):
    """High-quality downscale/upscale of a straight-alpha RGBA (or 2D) image: bilinear to an
    integer multiple of the target, then area average, all premultiplied."""
    h = h or w
    two_d = img.ndim == 2
    if two_d:
        img = np.dstack([np.ones(img.shape + (3,), np.float32), img])
    H, W = img.shape[:2]
    p = premul(img)
    fy, fx = max(1, int(math.ceil(H / h))), max(1, int(math.ceil(W / w)))
    if (H, W) != (h * fy, w * fx):
        p = bilinear(p, w * fx, h * fy)
    p = p.reshape(h, fy, w, fx, 4).mean(axis=(1, 3))
    out = unpremul(p).astype(np.float32)
    return out[..., 3] if two_d else out

def bilinear(img, w, h):
    H, W = img.shape[:2]
    ys = (np.arange(h) + 0.5) * H / h - 0.5
    xs = (np.arange(w) + 0.5) * W / w - 0.5
    y0 = np.clip(np.floor(ys).astype(int), 0, H - 1); y1 = np.clip(y0 + 1, 0, H - 1)
    x0 = np.clip(np.floor(xs).astype(int), 0, W - 1); x1 = np.clip(x0 + 1, 0, W - 1)
    fy = np.clip(ys - np.floor(ys), 0, 1)[:, None, None]
    fx = np.clip(xs - np.floor(xs), 0, 1)[None, :, None]
    if img.ndim == 2:
        fy, fx = fy[..., 0], fx[..., 0]
    return (img[y0][:, x0] * (1 - fy) * (1 - fx) + img[y0][:, x1] * (1 - fy) * fx
            + img[y1][:, x0] * fy * (1 - fx) + img[y1][:, x1] * fy * fx).astype(np.float32)

def nearest(img, k):
    return np.repeat(np.repeat(img, k, 0), k, 1)

def over(dst, src, x, y):
    """Composite straight-alpha src onto straight-alpha dst (in place) with top-left at (x, y)."""
    x, y = int(round(x)), int(round(y))
    h, w = src.shape[:2]
    H, W = dst.shape[:2]
    x0, y0, x1, y1 = max(x, 0), max(y, 0), min(x + w, W), min(y + h, H)
    if x1 <= x0 or y1 <= y0:
        return
    s = src[y0 - y:y1 - y, x0 - x:x1 - x]
    d = dst[y0:y1, x0:x1]
    sa, da = s[..., 3:4], d[..., 3:4]
    oa = sa + da * (1 - sa)
    orgb = (s[..., :3] * sa + d[..., :3] * da * (1 - sa)) / np.maximum(oa, 1e-6)
    dst[y0:y1, x0:x1] = np.concatenate([orgb, oa], -1)

def layer(alpha, color, opacity=1.0):
    o = np.zeros(alpha.shape + (4,), np.float32)
    o[..., :3] = color
    o[..., 3] = alpha * opacity
    return o

def solid(h, w, rgb, a=1.0):
    o = np.zeros((h, w, 4), np.float32)
    o[..., :3] = rgb
    o[..., 3] = a
    return o

def screen(base, add):
    return 1 - (1 - base) * (1 - np.clip(add, 0, 1))

def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)

def grain(h, w, amount, seed=7):
    rng = np.random.default_rng(seed)
    return (blur(rng.standard_normal((h, w)).astype(np.float32), 0.7) * amount)[..., None]

def radial(h, w, cx, cy, rx, ry=None):
    """Gaussian falloff (1 at centre)."""
    ry = ry or rx
    X, Y = np.meshgrid(np.arange(w) + 0.5, np.arange(h) + 0.5)
    return np.exp(-(((X - cx) / rx) ** 2 + ((Y - cy) / ry) ** 2)).astype(np.float32)

def stroke_path(w, h, pts, widths, ss=4):
    """Anti-aliased coverage of a variable-width polyline (round caps). pts in pixels."""
    X, Y = grid(w, h, ss)
    d = np.full(X.shape, 1e9, np.float32)
    for (ax, ay), (bx, by), wa, wb in zip(pts[:-1], pts[1:], widths[:-1], widths[1:]):
        x0, x1 = min(ax, bx) - max(wa, wb) - 2, max(ax, bx) + max(wa, wb) + 2
        y0, y1 = min(ay, by) - max(wa, wb) - 2, max(ay, by) + max(wa, wb) + 2
        i0, i1 = max(int(y0 * ss), 0), min(int(y1 * ss) + 1, Y.shape[0])
        j0, j1 = max(int(x0 * ss), 0), min(int(x1 * ss) + 1, X.shape[1])
        if i1 <= i0 or j1 <= j0:
            continue
        px, py = X[i0:i1, j0:j1] - ax, Y[i0:i1, j0:j1] - ay
        vx, vy = bx - ax, by - ay
        t = np.clip((px * vx + py * vy) / max(vx * vx + vy * vy, 1e-9), 0, 1)
        dist = np.sqrt((px - t * vx) ** 2 + (py - t * vy) ** 2) - (wa + (wb - wa) * t) / 2
        d[i0:i1, j0:j1] = np.minimum(d[i0:i1, j0:j1], dist)
    return down((d <= 0).astype(np.float32), ss)
