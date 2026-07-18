#!/usr/bin/env python3
"""Generate PlayAgent launcher assets (1-bit pixel art) without external deps.

Outputs into source/launcher/:
  icon.png (32x32), icon-pressed.png, icon-highlighted/{1..4}.png + animation.txt
  card.png (350x155), card-pressed.png
  launchImage.png (400x240)

Run:  python3 tools/gen_assets.py
"""

import os
import struct
import zlib

ROOT = os.path.join(os.path.dirname(__file__), "..", "source", "launcher")

WHITE, BLACK = 255, 0


# ----------------------------------------------------------------------
# Tiny framebuffer + PNG writer (8-bit grayscale)
# ----------------------------------------------------------------------

class FB:
    def __init__(self, w, h, fill=WHITE):
        self.w, self.h = w, h
        self.px = bytearray([fill] * (w * h))

    def set(self, x, y, v=BLACK):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y * self.w + x] = v

    def get(self, x, y):
        return self.px[y * self.w + x]

    def rect(self, x, y, w, h, v=BLACK):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                self.set(xx, yy, v)

    def frame(self, x, y, w, h, t=1, v=BLACK):
        self.rect(x, y, w, t, v)
        self.rect(x, y + h - t, w, t, v)
        self.rect(x, y, t, h, v)
        self.rect(x + w - t, y, t, h, v)

    def invert(self):
        for i, p in enumerate(self.px):
            self.px[i] = 255 - p

    def blit_scaled(self, src, dx, dy, scale):
        for y in range(src.h):
            for x in range(src.w):
                if src.get(x, y) == BLACK:
                    self.rect(dx + x * scale, dy + y * scale, scale, scale, BLACK)

    def save(self, path):
        raw = b""
        for y in range(self.h):
            raw += b"\x00" + bytes(self.px[y * self.w:(y + 1) * self.w])

        def chunk(tag, data):
            c = tag + data
            return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

        ihdr = struct.pack(">IIBBBBB", self.w, self.h, 8, 0, 0, 0, 0)
        png = (b"\x89PNG\r\n\x1a\n"
               + chunk(b"IHDR", ihdr)
               + chunk(b"IDAT", zlib.compress(raw, 9))
               + chunk(b"IEND", b""))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(png)
        print("wrote", os.path.relpath(path, os.path.join(ROOT, "..", "..")))


# ----------------------------------------------------------------------
# 3x5 pixel font
# ----------------------------------------------------------------------

FONT = {
    "A": ["010", "101", "111", "101", "101"],
    "B": ["110", "101", "110", "101", "110"],
    "C": ["111", "100", "100", "100", "111"],
    "D": ["110", "101", "101", "101", "110"],
    "E": ["111", "100", "110", "100", "111"],
    "F": ["111", "100", "110", "100", "100"],
    "G": ["111", "100", "101", "101", "111"],
    "H": ["101", "101", "111", "101", "101"],
    "I": ["111", "010", "010", "010", "111"],
    "J": ["111", "001", "001", "101", "010"],
    "K": ["101", "101", "110", "101", "101"],
    "L": ["100", "100", "100", "100", "111"],
    "M": ["101", "111", "111", "101", "101"],
    "N": ["110", "101", "101", "101", "101"],
    "O": ["111", "101", "101", "101", "111"],
    "P": ["110", "101", "110", "100", "100"],
    "Q": ["010", "101", "101", "101", "011"],
    "R": ["110", "101", "110", "101", "101"],
    "S": ["011", "100", "010", "001", "110"],
    "T": ["111", "010", "010", "010", "010"],
    "U": ["101", "101", "101", "101", "111"],
    "V": ["101", "101", "101", "101", "010"],
    "W": ["101", "101", "111", "111", "101"],
    "X": ["101", "101", "010", "101", "101"],
    "Y": ["101", "101", "010", "010", "010"],
    "Z": ["111", "001", "010", "100", "111"],
    "0": ["111", "101", "101", "101", "111"],
    "1": ["010", "110", "010", "010", "111"],
    " ": ["000", "000", "000", "000", "000"],
    "-": ["000", "000", "111", "000", "000"],
    ".": ["000", "000", "000", "000", "010"],
    ":": ["000", "010", "000", "010", "000"],
}


def draw_text(fb, text, x, y, scale=1, v=BLACK):
    cx = x
    for ch in text.upper():
        glyph = FONT.get(ch, FONT[" "])
        for gy, row in enumerate(glyph):
            for gx, bit in enumerate(row):
                if bit == "1":
                    fb.rect(cx + gx * scale, y + gy * scale, scale, scale, v)
        cx += (3 + 1) * scale
    return cx - scale  # end x


def text_width(text, scale=1):
    return len(text) * 4 * scale - scale


# ----------------------------------------------------------------------
# The mascot: a speech bubble with a robot face (32x32)
# eyes: "open" | "half" | "closed"
# ----------------------------------------------------------------------

def mascot(eyes="open"):
    fb = FB(32, 32, WHITE)

    # antenna sticking out above the bubble
    fb.rect(14, 0, 4, 3)            # knob
    fb.rect(15, 3, 2, 3)            # stem

    # Speech bubble outline (rounded rect 1..30 x 5..23)
    fb.rect(4, 5, 24, 2)            # top
    fb.rect(4, 22, 24, 2)           # bottom
    fb.rect(1, 8, 2, 13)            # left
    fb.rect(29, 8, 2, 13)           # right
    # corners
    fb.rect(2, 6, 3, 3)
    fb.rect(27, 6, 3, 3)
    fb.rect(2, 19, 3, 3)
    fb.rect(27, 19, 3, 3)

    # tail (bottom-left, pointing down-left)
    fb.rect(7, 24, 6, 2)
    fb.rect(7, 26, 4, 2)
    fb.rect(7, 28, 2, 2)

    # eyes
    ex1, ex2, ey, ew = 9, 19, 10, 4
    if eyes == "open":
        fb.rect(ex1, ey, ew, 4)
        fb.rect(ex2, ey, ew, 4)
    elif eyes == "half":
        fb.rect(ex1, ey + 2, ew, 2)
        fb.rect(ex2, ey + 2, ew, 2)
    else:  # closed
        fb.rect(ex1, ey + 3, ew, 1)
        fb.rect(ex2, ey + 3, ew, 1)

    # mouth
    fb.rect(12, 17, 8, 2)

    return fb


# ----------------------------------------------------------------------
# Assets
# ----------------------------------------------------------------------

def gen_icons():
    icon = mascot("open")
    icon.save(os.path.join(ROOT, "icon.png"))

    pressed = mascot("open")
    pressed.invert()
    pressed.save(os.path.join(ROOT, "icon-pressed.png"))

    # blink animation
    frames = {1: "open", 2: "half", 3: "closed", 4: "half"}
    for n, eyes in frames.items():
        mascot(eyes).save(os.path.join(ROOT, "icon-highlighted", f"{n}.png"))
    anim = os.path.join(ROOT, "icon-highlighted", "animation.txt")
    with open(anim, "w") as f:
        f.write("frames = 1x22, 2, 3x2, 4\n")
    print("wrote source/launcher/icon-highlighted/animation.txt")


def compose(fb, border=True):
    """Shared card/launch composition onto an arbitrary-size fb."""
    if border:
        fb.frame(0, 0, fb.w, fb.h, 2)
        fb.frame(4, 4, fb.w - 8, fb.h - 8, 1)


def gen_card():
    fb = FB(350, 155, WHITE)
    compose(fb)

    fb.blit_scaled(mascot("open"), 22, 15, 4)

    title = "PLAYAGENT"
    ts = 5
    tx = 165
    draw_text(fb, title, tx, 45, ts)
    fb.rect(tx, 45 + 6 * ts, text_width(title, ts), 2)   # underline

    draw_text(fb, "LLM - MCP - VOICE", tx, 45 + 6 * ts + 10, 2)

    fb.save(os.path.join(ROOT, "card.png"))

    fb.invert()
    fb.save(os.path.join(ROOT, "card-pressed.png"))


def gen_launch():
    fb = FB(400, 240, WHITE)
    fb.frame(0, 0, fb.w, fb.h, 3)
    fb.frame(6, 6, fb.w - 12, fb.h - 12, 1)

    fb.blit_scaled(mascot("open"), 36, 48, 5)

    title = "PLAYAGENT"
    ts = 5
    tx = 210
    draw_text(fb, title, tx, 82, ts)
    fb.rect(tx, 82 + 6 * ts, text_width(title, ts), 3)

    sub = "LLM - MCP - VOICE"
    draw_text(fb, sub, tx, 82 + 6 * ts + 12, 2)

    msg = "WAKING THE AGENT..."
    draw_text(fb, msg, (fb.w - text_width(msg, 2)) // 2, 210, 2)

    fb.save(os.path.join(ROOT, "launchImage.png"))


if __name__ == "__main__":
    gen_icons()
    gen_card()
    gen_launch()
