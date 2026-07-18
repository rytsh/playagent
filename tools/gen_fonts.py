#!/usr/bin/env python3
"""Generate Playdate bitmap fonts from JetBrainsMono Nerd Font Mono."""

import argparse
import math
import os
import subprocess


CELL_W = 10
CELL_H = 18
ADVANCE = 8
POINT_SIZE = 14
BASELINE = 14
COLUMNS = 16

CODEPOINTS = list(range(0x20, 0x180)) + [
    0x2010,
    0x2013,
    0x2014,
    0x2016,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2026,
    0x2030,
    0x2039,
    0x203A,
    0x20AC,
    0x2122,
    0x2190,
    0x2191,
    0x2192,
    0x2193,
    0x25B8,
    0x2713,
    0x2717,
    0xFFFD,
]


def generate(font_path, output_dir, name):
    rows = math.ceil(len(CODEPOINTS) / COLUMNS)
    image_path = os.path.join(
        output_dir, f"{name}-table-{CELL_W}-{CELL_H}.png"
    )
    command = [
        "convert",
        "-size",
        f"{COLUMNS * CELL_W}x{rows * CELL_H}",
        "xc:none",
        "-font",
        font_path,
        "-pointsize",
        str(POINT_SIZE),
        "+antialias",
        "-fill",
        "black",
    ]
    for index, codepoint in enumerate(CODEPOINTS):
        if codepoint == 0x20:
            continue
        x = index % COLUMNS * CELL_W + 1
        y = index // COLUMNS * CELL_H + BASELINE
        command.extend(["-annotate", f"+{x}+{y}", chr(codepoint)])
    command.append(image_path)
    subprocess.run(command, check=True)

    definition_path = os.path.join(output_dir, f"{name}.fnt")
    with open(definition_path, "w", encoding="utf-8") as definition:
        definition.write("tracking=0\n")
        for codepoint in CODEPOINTS:
            glyph = "space" if codepoint == 0x20 else f"U+{codepoint:04X}"
            definition.write(f"{glyph}\t{ADVANCE}\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--nerd-fonts",
        default=os.path.expanduser("~/fonts/nerd-fonts"),
        help="path to the nerd-fonts checkout",
    )
    parser.add_argument(
        "--output",
        default=os.path.join(os.path.dirname(__file__), "..", "source", "fonts"),
    )
    args = parser.parse_args()

    base = os.path.join(
        args.nerd_fonts, "patched-fonts", "JetBrainsMono", "NoLigatures"
    )
    fonts = {
        "PlayAgent-Regular": os.path.join(
            base, "Regular", "JetBrainsMonoNLNerdFontMono-Regular.ttf"
        ),
        "PlayAgent-Bold": os.path.join(
            base, "Bold", "JetBrainsMonoNLNerdFontMono-Bold.ttf"
        ),
    }
    os.makedirs(args.output, exist_ok=True)
    for name, path in fonts.items():
        if not os.path.isfile(path):
            raise SystemExit(f"font not found: {path}")
        generate(path, args.output, name)
        print(f"generated {name}")


if __name__ == "__main__":
    main()
