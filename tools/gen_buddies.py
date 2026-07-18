#!/usr/bin/env python3
"""Generate Buddy mode animal sprites (1-bit pixel art) without external deps.

Style: solid black silhouettes with white carved details (reads well at 1-bit).
Each animal gets 6 frames drawn at 32x32 and saved pre-scaled 4x (128x128)
into source/images/buddies/<animal>-<frame>.png:
    idle1, idle2, blink, talk1, talk2, happy

Run:      python3 tools/gen_buddies.py
Preview:  python3 tools/gen_buddies.py --preview [animal] [frame]
"""

import os
import sys

from gen_assets import FB, WHITE, BLACK

ROOT = os.path.join(os.path.dirname(__file__), "..", "source", "images",
                    "buddies")

SIZE = 32
SCALE = 4
FRAMES = ["idle1", "idle2", "blink", "talk1", "talk2", "happy"]


# ----------------------------------------------------------------------
# Shape helpers on FB
# ----------------------------------------------------------------------

def disc(fb, cx, cy, rx, ry, v=BLACK):
    """Filled ellipse."""
    for y in range(cy - ry, cy + ry + 1):
        for x in range(cx - rx, cx + rx + 1):
            dx = (x - cx) / rx if rx else 0
            dy = (y - cy) / ry if ry else 0
            if dx * dx + dy * dy <= 1.0:
                fb.set(x, y, v)


def tri(fb, p1, p2, p3, v=BLACK):
    """Filled triangle."""
    xs = [p1[0], p2[0], p3[0]]
    ys = [p1[1], p2[1], p3[1]]

    def edge(a, b, x, y):
        return (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0])

    for y in range(min(ys), max(ys) + 1):
        for x in range(min(xs), max(xs) + 1):
            d1 = edge(p1, p2, x, y)
            d2 = edge(p2, p3, x, y)
            d3 = edge(p3, p1, x, y)
            neg = d1 < 0 or d2 < 0 or d3 < 0
            pos = d1 > 0 or d2 > 0 or d3 > 0
            if not (neg and pos):
                fb.set(x, y, v)


def hline(fb, x1, x2, y, v=BLACK):
    for x in range(min(x1, x2), max(x1, x2) + 1):
        fb.set(x, y, v)


def vline(fb, x, y1, y2, v=BLACK):
    for y in range(min(y1, y2), max(y1, y2) + 1):
        fb.set(x, y, v)


def happy_eyes(fb, positions, y, v=WHITE):
    """Little ^ ^ arcs carved in white."""
    for x0 in positions:
        fb.set(x0, y, v)
        fb.set(x0 + 1, y - 1, v)
        fb.set(x0 + 2, y - 1, v)
        fb.set(x0 + 3, y, v)


# ----------------------------------------------------------------------
# Dog: front view, floppy ears, white snout patch, wagging tail
# ----------------------------------------------------------------------

def dog(frame):
    fb = FB(SIZE, SIZE, WHITE)
    talk = frame in ("talk1", "talk2")
    happy = frame == "happy"
    blink = frame == "blink"
    wag = frame in ("idle2", "talk2", "happy")

    # body
    disc(fb, 16, 26, 9, 6, BLACK)
    # tail
    if wag:
        fb.rect(25, 20, 5, 2)
    else:
        fb.rect(25, 23, 5, 2)

    # head
    disc(fb, 16, 12, 11, 10, BLACK)
    # floppy ears sticking out
    disc(fb, 4, 10, 3, 7, BLACK)
    disc(fb, 28, 10, 3, 7, BLACK)

    # eyes (white on black)
    if blink:
        hline(fb, 9, 12, 10, WHITE)
        hline(fb, 19, 22, 10, WHITE)
    elif happy:
        happy_eyes(fb, (9, 19), 10)
    else:
        fb.rect(9, 7, 3, 4, WHITE)
        fb.rect(20, 7, 3, 4, WHITE)

    # white snout patch + nose + mouth
    disc(fb, 16, 17, 6, 4, WHITE)
    fb.rect(15, 14, 3, 2, BLACK)          # nose
    if talk or happy:
        disc(fb, 16, 18, 2, 1, BLACK)     # open mouth
        if happy:
            fb.rect(15, 19, 3, 2, BLACK)  # tongue
    else:
        hline(fb, 14, 18, 18, BLACK)

    # carve legs into the body
    vline(fb, 12, 28, 31, WHITE)
    vline(fb, 19, 28, 31, WHITE)

    return fb


# ----------------------------------------------------------------------
# Cat: front view, pointy ears, whiskers, swishing tail
# ----------------------------------------------------------------------

def cat(frame):
    fb = FB(SIZE, SIZE, WHITE)
    talk = frame in ("talk1", "talk2")
    happy = frame == "happy"
    blink = frame == "blink"
    swish = frame in ("idle2", "talk2", "happy")

    # body
    disc(fb, 16, 26, 8, 6, BLACK)
    # tail curling up beside the body
    if swish:
        fb.rect(26, 19, 2, 8)
        fb.rect(24, 17, 3, 2)
    else:
        fb.rect(26, 22, 2, 6)
        fb.rect(24, 26, 3, 2)

    # ears (merge into the head silhouette)
    tri(fb, (6, 0), (14, 7), (4, 10))
    tri(fb, (25, 0), (18, 7), (27, 10))

    # head
    disc(fb, 16, 13, 10, 9, BLACK)

    # inner ears carved white (only the tips outside the head)
    tri(fb, (7, 2), (9, 4), (6, 5), WHITE)
    tri(fb, (24, 2), (22, 4), (25, 5), WHITE)

    # eyes
    if blink:
        hline(fb, 9, 12, 11, WHITE)
        hline(fb, 19, 22, 11, WHITE)
    elif happy:
        happy_eyes(fb, (9, 19), 11)
    else:
        fb.rect(9, 8, 3, 4, WHITE)
        fb.rect(20, 8, 3, 4, WHITE)

    # muzzle + nose + mouth
    disc(fb, 16, 17, 5, 3, WHITE)
    tri(fb, (15, 15), (17, 15), (16, 16), BLACK)
    if talk:
        disc(fb, 16, 18, 2, 1, BLACK)
    elif happy:
        fb.set(14, 18)
        fb.set(15, 19)
        fb.set(16, 18)
        fb.set(17, 19)
        fb.set(18, 18)
    else:
        fb.set(15, 18)
        fb.set(16, 17)
        fb.set(17, 18)

    # whiskers
    hline(fb, 1, 5, 15)
    hline(fb, 1, 5, 18)
    hline(fb, 27, 31, 15)
    hline(fb, 27, 31, 18)

    # carve legs
    vline(fb, 13, 28, 31, WHITE)
    vline(fb, 19, 28, 31, WHITE)

    return fb


# ----------------------------------------------------------------------
# Bird: side profile facing right, beak, tuft, tail feathers
# ----------------------------------------------------------------------

def bird(frame):
    fb = FB(SIZE, SIZE, WHITE)
    talk = frame in ("talk1", "talk2")
    happy = frame == "happy"
    blink = frame == "blink"
    bob = frame in ("idle2", "talk2")

    dy = 1 if bob else 0

    # feet on the ground (y=30)
    vline(fb, 13, 27, 30)
    vline(fb, 18, 27, 30)
    hline(fb, 11, 15, 30)
    hline(fb, 16, 20, 30)

    # tail feathers (back left)
    tri(fb, (8, 15 + dy), (1, 11 + dy), (8, 21 + dy))

    # body + head blob
    disc(fb, 15, 19 + dy, 9, 8, BLACK)
    disc(fb, 19, 11 + dy, 7, 7, BLACK)

    # head tuft
    fb.set(18, 3 + dy)
    fb.set(19, 2 + dy)
    vline(fb, 19, 3 + dy, 4 + dy)

    # beak sticking out to the right
    if talk or happy:
        tri(fb, (25, 10 + dy), (30, 8 + dy), (25, 12 + dy))   # upper
        tri(fb, (25, 13 + dy), (30, 15 + dy), (25, 15 + dy))  # lower
    else:
        tri(fb, (25, 10 + dy), (30, 12 + dy), (25, 14 + dy))
        hline(fb, 26, 29, 12 + dy, WHITE)

    # eye
    if blink:
        hline(fb, 19, 21, 10 + dy, WHITE)
    elif happy:
        happy_eyes(fb, (19,), 11 + dy)
    else:
        fb.rect(20, 9 + dy, 2, 3, WHITE)

    # wing carved as a white arc
    if happy:
        # raised wing
        disc(fb, 10, 13 + dy, 4, 5, WHITE)
        disc(fb, 10, 13 + dy, 3, 4, BLACK)
    else:
        disc(fb, 12, 20 + dy, 4, 5, WHITE)
        disc(fb, 12, 20 + dy, 3, 4, BLACK)

    return fb


# ----------------------------------------------------------------------
# Chameleon: side view on a branch, turret eye, curly tail, crest
# ----------------------------------------------------------------------

def chameleon(frame):
    fb = FB(SIZE, SIZE, WHITE)
    talk = frame in ("talk1", "talk2")
    happy = frame == "happy"
    blink = frame == "blink"
    look_back = frame in ("idle2", "talk2")

    # branch
    hline(fb, 0, 31, 28)
    hline(fb, 0, 31, 29)

    # curled tail (spiral)
    disc(fb, 6, 21, 5, 5, BLACK)
    disc(fb, 6, 21, 3, 3, WHITE)
    disc(fb, 6, 21, 1, 1, BLACK)
    fb.rect(8, 17, 3, 3, BLACK)  # connect tail to body

    # body
    disc(fb, 15, 18, 8, 6, BLACK)

    # crest zigzag on the back
    for x in (10, 14, 18):
        tri(fb, (x, 13), (x + 2, 9), (x + 4, 13))

    # head cone + casque
    tri(fb, (19, 8), (19, 18), (26, 15))
    tri(fb, (19, 8), (24, 11), (21, 4))

    # snout / jaws
    if talk:
        tri(fb, (23, 12), (29, 9), (23, 14))    # upper jaw
        tri(fb, (23, 15), (29, 17), (23, 17))   # lower jaw
    else:
        tri(fb, (23, 12), (29, 15), (23, 17))
        hline(fb, 24, 28, 14, WHITE)            # mouth line

    # turret eye
    disc(fb, 21, 11, 2, 2, WHITE)
    if blink:
        hline(fb, 19, 23, 11, BLACK)
    elif look_back:
        fb.set(20, 11, BLACK)
    else:
        fb.set(22, 11, BLACK)

    # legs gripping the branch
    vline(fb, 12, 24, 27)
    vline(fb, 18, 24, 27)
    fb.set(11, 27)
    fb.set(19, 27)

    # happy: long tongue with a fly at the end
    if happy:
        hline(fb, 27, 31, 13)
        fb.rect(29, 10, 2, 2)
        fb.set(28, 9)
        fb.set(31, 9)

    return fb


# ----------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------

ANIMALS = {
    "dog": dog,
    "cat": cat,
    "bird": bird,
    "chameleon": chameleon,
}


def preview(animal, frame):
    fb = ANIMALS[animal](frame)
    print(f"--- {animal} / {frame} ---")
    for y in range(fb.h):
        print("".join("#" if fb.get(x, y) == BLACK else "."
                      for x in range(fb.w)))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--preview":
        animals = [sys.argv[2]] if len(sys.argv) > 2 else list(ANIMALS)
        frames = sys.argv[3].split(",") if len(sys.argv) > 3 else ["idle1"]
        for a in animals:
            for f in frames:
                preview(a, f)
        return

    os.makedirs(ROOT, exist_ok=True)
    for name, fn in ANIMALS.items():
        for frame in FRAMES:
            small = fn(frame)
            big = FB(SIZE * SCALE, SIZE * SCALE, WHITE)
            big.blit_scaled(small, 0, 0, SCALE)
            big.save(os.path.join(ROOT, f"{name}-{frame}.png"))


if __name__ == "__main__":
    main()
