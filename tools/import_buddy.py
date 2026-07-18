#!/usr/bin/env python3
"""Convert AI-generated (or any) PNG art into 1-bit Buddy sprites.

Takes a PNG (color or grayscale, any size), converts it to 1-bit black &
white and writes 128x128 frames into source/images/buddies/. No external
dependencies (pure-Python PNG decoder).

Single frame:
    python3 tools/import_buddy.py art/dog-happy.png --animal dog --frame happy

Sprite sheet (grid of poses, frames taken in reading order):
    python3 tools/import_buddy.py art/dog-sheet.png --animal dog --sheet 3x2

Default frame order for sheets: idle1 idle2 blink talk1 talk2 happy
Override with:  --frames idle1,blink,talk1  (unused cells are skipped)

Options:
    --threshold N   luminance cutoff 0-255 (default 140); pixels darker than
                    N become black
    --dither        Floyd-Steinberg dithering instead of a hard threshold
                    (for shaded art; cartoon/flat art looks better without)
    --ordered       ordered (Bayer 8x8) dithering: slightly coarser than
                    --dither but stable across animation frames (no
                    background shimmer)
    --invert        invert black/white after conversion
    --white N       force pixels lighter than N (0-255) to pure white before
                    dithering; removes light checkerboard/gray backgrounds
    --clearbg N     flood-fill from the frame edges through pixels lighter
                    than N (0-255), forcing them white: removes background
                    textures without touching the character (dark outlines
                    stop the fill). Try 220 for checkerboard backgrounds.
    --no-trim       don't auto-crop each frame to its content bounding box
    --pad N         padding in output pixels around trimmed content (default 4)

Sheet frames are auto-aligned: one common scale for all frames, each frame
anchored to the bottom (ground) and centered horizontally on its center of
mass, so the character does not jump around between animation frames.
    --out DIR       output directory (default source/images/buddies)
    --preview       print an ASCII preview instead of writing files
"""

import argparse
import os
import struct
import sys
import zlib

from gen_assets import FB, WHITE, BLACK

DEFAULT_OUT = os.path.join(os.path.dirname(__file__), "..", "source",
                           "images", "buddies")
FRAME_ORDER = ["idle1", "idle2", "blink", "talk1", "talk2", "happy"]
OUT_SIZE = 128


# ----------------------------------------------------------------------
# Minimal PNG decoder (8-bit gray / gray+alpha / RGB / RGBA / palette,
# non-interlaced). Returns a luminance grid 0-255 composited over white.
# ----------------------------------------------------------------------

def read_png_luminance(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"{path}: not a PNG file")

    pos = 8
    ihdr = None
    plte = None
    trns = None
    idat = b""
    while pos < len(data):
        length, tag = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", chunk)
        elif tag == b"PLTE":
            plte = chunk
        elif tag == b"tRNS":
            trns = chunk
        elif tag == b"IDAT":
            idat += chunk
        elif tag == b"IEND":
            break
    if ihdr is None:
        sys.exit(f"{path}: missing IHDR")

    w, h, depth, ctype, comp, filt, interlace = ihdr
    if interlace != 0:
        sys.exit(f"{path}: interlaced PNG not supported (re-export it)")
    if depth == 16:
        # accept but truncate 16-bit to high byte
        pass
    elif depth != 8:
        if ctype == 3 and depth in (1, 2, 4):
            sys.exit(f"{path}: palette bit depth {depth} not supported; "
                     "re-export as 8-bit PNG")
        sys.exit(f"{path}: bit depth {depth} not supported; "
                 "re-export as 8-bit PNG")

    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(ctype)
    if channels is None:
        sys.exit(f"{path}: unsupported color type {ctype}")
    bytes_per_sample = 2 if depth == 16 else 1
    bpp = channels * bytes_per_sample
    stride = w * bpp

    raw = zlib.decompress(idat)
    if len(raw) < h * (stride + 1):
        sys.exit(f"{path}: truncated image data")

    # un-filter scanlines
    out = bytearray(h * stride)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        ftype = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if ftype == 1:      # Sub
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:    # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:    # Average
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:    # Paeth
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                if pa <= pb and pa <= pc:
                    pr = a
                elif pb <= pc:
                    pr = b
                else:
                    pr = c
                line[i] = (line[i] + pr) & 0xFF
        elif ftype != 0:
            sys.exit(f"{path}: bad filter type {ftype}")
        out[y * stride:(y + 1) * stride] = line
        prev = line

    # to luminance, alpha composited over white
    lum = [[255] * w for _ in range(h)]
    for y in range(h):
        row = out[y * stride:(y + 1) * stride]
        for x in range(w):
            o = x * bpp
            if ctype == 0:
                v = row[o]
                a = 255
            elif ctype == 4:
                v = row[o]
                a = row[o + bytes_per_sample]
            elif ctype == 2:
                r, g, b = row[o], row[o + bytes_per_sample], \
                    row[o + 2 * bytes_per_sample]
                v = (r * 299 + g * 587 + b * 114) // 1000
                a = 255
            elif ctype == 6:
                r, g, b = row[o], row[o + bytes_per_sample], \
                    row[o + 2 * bytes_per_sample]
                v = (r * 299 + g * 587 + b * 114) // 1000
                a = row[o + 3 * bytes_per_sample]
            else:  # palette
                idx = row[o]
                r, g, b = plte[idx * 3], plte[idx * 3 + 1], plte[idx * 3 + 2]
                v = (r * 299 + g * 587 + b * 114) // 1000
                a = trns[idx] if trns is not None and idx < len(trns) else 255
            if a < 255:
                v = (v * a + 255 * (255 - a)) // 255
            lum[y][x] = v
    return lum


# ----------------------------------------------------------------------
# Processing
# ----------------------------------------------------------------------

def crop(lum, x0, y0, x1, y1):
    return [row[x0:x1] for row in lum[y0:y1]]


def content_bbox(lum, threshold):
    """Bounding box of pixels darker than threshold."""
    h, w = len(lum), len(lum[0])
    minx, miny, maxx, maxy = w, h, -1, -1
    for y in range(h):
        for x in range(w):
            if lum[y][x] < threshold:
                if x < minx: minx = x
                if x > maxx: maxx = x
                if y < miny: miny = y
                if y > maxy: maxy = y
    if maxx < 0:
        return None
    return minx, miny, maxx + 1, maxy + 1


def centroid_dark(lum, threshold):
    """Center of mass of pixels darker than threshold, or None."""
    sx, sy, n = 0, 0, 0
    for y in range(len(lum)):
        for x in range(len(lum[0])):
            if lum[y][x] < threshold:
                sx += x
                sy += y
                n += 1
    if n == 0:
        return None
    return sx / n, sy / n


def apply_white_cutoff(lum, white):
    if white <= 0:
        return lum
    return [[255 if v >= white else v for v in row] for row in lum]


def clear_background(lum, tol, min_speck=None):
    """Remove textured backgrounds (checkerboards, halftone dots) from a
    full-resolution frame:
      1. flood-fill from the edges through light pixels (>= tol) -> white;
         the character's dark outline stops the fill
      2. whiten small non-flooded islands (stray dark background dots the
         fill went around), keeping any component >= min_speck pixels
    Works in place, returns lum."""
    if tol <= 0:
        return lum
    h, w = len(lum), len(lum[0])
    if min_speck is None:
        min_speck = max(30, (w * h) // 500)

    flooded = [[False] * w for _ in range(h)]
    stack = []
    for x in range(w):
        stack.append((x, 0))
        stack.append((x, h - 1))
    for y in range(h):
        stack.append((0, y))
        stack.append((w - 1, y))
    while stack:
        x, y = stack.pop()
        if x < 0 or y < 0 or x >= w or y >= h or flooded[y][x]:
            continue
        if lum[y][x] < tol:
            continue
        flooded[y][x] = True
        lum[y][x] = 255
        stack.append((x + 1, y))
        stack.append((x - 1, y))
        stack.append((x, y + 1))
        stack.append((x, y - 1))

    # label non-flooded components; whiten the small ones
    seen = [[False] * w for _ in range(h)]
    for sy in range(h):
        for sx in range(w):
            if seen[sy][sx] or flooded[sy][sx]:
                continue
            comp = []
            stack = [(sx, sy)]
            seen[sy][sx] = True
            while stack:
                x, y = stack.pop()
                comp.append((x, y))
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1),
                               (x, y - 1)):
                    if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] \
                            and not flooded[ny][nx]:
                        seen[ny][nx] = True
                        stack.append((nx, ny))
            if len(comp) < min_speck:
                for x, y in comp:
                    lum[y][x] = 255
    return lum


def scale_box(lum, tw, th):
    """Box-filter resize to tw x th."""
    h, w = len(lum), len(lum[0])
    out = [[255] * tw for _ in range(th)]
    for ty in range(th):
        sy0 = ty * h / th
        sy1 = max(sy0 + 1e-6, (ty + 1) * h / th)
        for tx in range(tw):
            sx0 = tx * w / tw
            sx1 = max(sx0 + 1e-6, (tx + 1) * w / tw)
            total = 0.0
            weight = 0.0
            for y in range(int(sy0), min(h, int(sy1) + 1)):
                wy = min(sy1, y + 1) - max(sy0, y)
                if wy <= 0:
                    continue
                for x in range(int(sx0), min(w, int(sx1) + 1)):
                    wx = min(sx1, x + 1) - max(sx0, x)
                    if wx <= 0:
                        continue
                    total += lum[y][x] * wx * wy
                    weight += wx * wy
            out[ty][tx] = total / weight if weight > 0 else 255
    return out


BAYER8 = [
    [0, 32, 8, 40, 2, 34, 10, 42],
    [48, 16, 56, 24, 50, 18, 58, 26],
    [12, 44, 4, 36, 14, 46, 6, 38],
    [60, 28, 52, 20, 62, 30, 54, 22],
    [3, 35, 11, 43, 1, 33, 9, 41],
    [51, 19, 59, 27, 49, 17, 57, 25],
    [15, 47, 7, 39, 13, 45, 5, 37],
    [63, 31, 55, 23, 61, 29, 53, 21],
]


def to_1bit(lum, threshold, dither, ordered=False):
    h, w = len(lum), len(lum[0])
    fb = FB(w, h, WHITE)
    if ordered:
        # Bayer matrix remapped so `threshold` is the 50% gray cutoff while
        # pure white stays white and pure black stays black.
        for y in range(h):
            for x in range(w):
                b = (BAYER8[y % 8][x % 8] + 0.5) * 4  # 2..254
                if b <= 128:
                    t = b * threshold / 128.0
                else:
                    t = 255 - (255 - b) * (255 - threshold) / 127.0
                if lum[y][x] < t:
                    fb.set(x, y, BLACK)
        return fb
    if not dither:
        for y in range(h):
            for x in range(w):
                if lum[y][x] < threshold:
                    fb.set(x, y, BLACK)
        return fb
    # Floyd-Steinberg
    err = [[float(v) for v in row] for row in lum]
    for y in range(h):
        for x in range(w):
            old = err[y][x]
            new = 0 if old < threshold else 255
            if new == 0:
                fb.set(x, y, BLACK)
            e = old - new
            if x + 1 < w:
                err[y][x + 1] += e * 7 / 16
            if y + 1 < h:
                if x > 0:
                    err[y + 1][x - 1] += e * 3 / 16
                err[y + 1][x] += e * 5 / 16
                if x + 1 < w:
                    err[y + 1][x + 1] += e * 1 / 16
    return fb


def render_at(scaled, args, ox, oy):
    """1-bit convert `scaled` and blit onto a fresh OUT_SIZE canvas."""
    bit = to_1bit(scaled, args.threshold, args.dither, args.ordered)
    if args.invert:
        bit.invert()
    fb = FB(OUT_SIZE, OUT_SIZE, WHITE)
    for y in range(len(scaled)):
        for x in range(len(scaled[0])):
            if bit.get(x, y) == BLACK:
                fb.set(ox + x, oy + y, BLACK)
    return fb


def process_frame(lum, args):
    """Trim, fit into OUT_SIZE with padding, threshold to 1-bit -> FB."""
    if not args.no_trim:
        bbox = content_bbox(lum, args.threshold)
        if bbox is not None:
            lum = crop(lum, *bbox)

    h, w = len(lum), len(lum[0])
    inner = OUT_SIZE - 2 * args.pad
    if w >= h:
        tw, th = inner, max(1, round(inner * h / w))
    else:
        tw, th = max(1, round(inner * w / h)), inner
    scaled = apply_white_cutoff(scale_box(lum, tw, th), args.white)
    return render_at(scaled, args, (OUT_SIZE - tw) // 2, (OUT_SIZE - th) // 2)


def process_sheet(jobs, args):
    """Convert sheet cells with stable alignment across frames: one common
    scale, bottom-anchored, horizontally centered on the center of mass.
    Returns a list of (frame name, FB)."""
    infos = []
    maxdim = 0
    for name, cell in jobs:
        bbox = content_bbox(cell, args.threshold)
        infos.append((name, cell, bbox))
        if bbox is not None:
            x0, y0, x1, y1 = bbox
            maxdim = max(maxdim, x1 - x0, y1 - y0)

    inner = OUT_SIZE - 2 * args.pad
    out = []
    for name, cell, bbox in infos:
        if bbox is None or maxdim == 0:
            out.append((name, FB(OUT_SIZE, OUT_SIZE, WHITE)))
            continue
        x0, y0, x1, y1 = bbox
        s = inner / maxdim
        tw = max(1, min(inner, round((x1 - x0) * s)))
        th = max(1, min(inner, round((y1 - y0) * s)))
        scaled = apply_white_cutoff(scale_box(crop(cell, x0, y0, x1, y1),
                                              tw, th), args.white)
        c = centroid_dark(scaled, args.threshold) or (tw / 2, th / 2)
        ox = min(max(round(OUT_SIZE / 2 - c[0]), 0), OUT_SIZE - tw)
        oy = OUT_SIZE - args.pad - th  # feet/shadow on a fixed ground line
        out.append((name, render_at(scaled, args, ox, oy)))
    return out


def ascii_preview(fb, cols=64):
    """Downsampled ASCII preview."""
    step = max(1, fb.w // cols)
    for y in range(0, fb.h, step * 2):  # terminal chars are ~2x tall
        line = ""
        for x in range(0, fb.w, step):
            dark = 0
            for yy in range(y, min(fb.h, y + step * 2)):
                for xx in range(x, min(fb.w, x + step)):
                    if fb.get(xx, yy) == BLACK:
                        dark += 1
            area = step * step * 2
            line += "#" if dark > area // 2 else ("+" if dark > area // 8
                                                  else ".")
        print(line)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input")
    ap.add_argument("--animal", required=True,
                    help="dog, cat, bird, chameleon, ...")
    ap.add_argument("--frame", help="single-frame mode: frame name")
    ap.add_argument("--sheet", help="sheet mode: COLSxROWS, e.g. 3x2")
    ap.add_argument("--frames", help="comma-separated frame names for sheet "
                    "cells (reading order); default: "
                    + ",".join(FRAME_ORDER))
    ap.add_argument("--threshold", type=int, default=140)
    ap.add_argument("--dither", action="store_true")
    ap.add_argument("--ordered", action="store_true")
    ap.add_argument("--invert", action="store_true")
    ap.add_argument("--white", type=int, default=0)
    ap.add_argument("--clearbg", type=int, default=0)
    ap.add_argument("--no-trim", action="store_true")
    ap.add_argument("--pad", type=int, default=4)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--preview", action="store_true")
    args = ap.parse_args()

    if (args.frame is None) == (args.sheet is None):
        ap.error("use exactly one of --frame or --sheet")

    lum = read_png_luminance(args.input)
    h, w = len(lum), len(lum[0])

    jobs = []  # (frame name, luminance grid)
    if args.frame:
        jobs.append((args.frame, lum))
    else:
        try:
            cols, rows = (int(v) for v in args.sheet.lower().split("x"))
        except ValueError:
            ap.error("--sheet must look like 3x2")
        names = (args.frames.split(",") if args.frames else FRAME_ORDER)
        i = 0
        for r in range(rows):
            for c in range(cols):
                if i >= len(names):
                    break
                cell = crop(lum, c * w // cols, r * h // rows,
                            (c + 1) * w // cols, (r + 1) * h // rows)
                jobs.append((names[i].strip(), cell))
                i += 1

    if args.clearbg > 0:
        # full-resolution background removal before trimming/scaling
        jobs = [(name, clear_background(cell, args.clearbg))
                for name, cell in jobs]

    if args.sheet and not args.no_trim:
        results = process_sheet(jobs, args)
    else:
        results = [(name, process_frame(cell, args)) for name, cell in jobs]

    os.makedirs(args.out, exist_ok=True)
    for name, fb in results:
        if args.preview:
            print(f"--- {args.animal}-{name} ---")
            ascii_preview(fb)
        else:
            fb.save(os.path.join(args.out, f"{args.animal}-{name}.png"))


if __name__ == "__main__":
    main()
