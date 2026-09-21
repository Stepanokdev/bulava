#!/usr/bin/env python3
"""Cut the three detail frames out of one capture of the application window.

    crop.py <window.png> <out-dir> <language>

Why cut rather than photograph three times: the page says something specific under each of these
pictures, and a whole three-column application shrunk to the width of a phone says nothing at all
— it is a rectangle with grey in it. Each crop is the part of the real window the sentence above
it is about, taken from the same real moment, so nothing here is staged.

The regions are proportions of the window rather than pixel counts: the window is whatever size
the fixture's Bulava opened at, and a hard-coded rectangle would silently slide off it.

Pillow rather than `sips`, after `sips --cropOffset` was measured and found to mean two different
things: with a zero offset it crops around the centre, with a non-zero one it measures from the
top-left. The first version of this file believed the second reading, produced rectangles
straddling the middle of the window padded out with black, and they looked enough like
screenshots to publish.
"""

import os
import sys

try:
    from PIL import Image
except ImportError:
    print("crop: needs Pillow — python3 -m pip install --user Pillow", file=sys.stderr)
    raise SystemExit(3)

# left, top, right, bottom — as fractions of the window
REGIONS = {
    # The composer and the card above it: how work is described, and what was agreed for it.
    "shot-compose.png": (0.20, 0.42, 0.74, 1.00),
    # The sidebar's meters beside the card's own steps: what is running and what it is spending.
    "shot-running.png": (0.00, 0.06, 0.62, 0.72),
    # The inspector: the changed files and the verifier's evidence for this run.
    "shot-review.png": (0.52, 0.04, 1.00, 0.96),
}


def main():
    if len(sys.argv) != 4:
        print("usage: crop.py <window.png> <out-dir> <language>", file=sys.stderr)
        return 2
    src, out_dir, lang = sys.argv[1], sys.argv[2], sys.argv[3]
    if not os.path.exists(src):
        print(f"crop: there is no {src} to cut", file=sys.stderr)
        return 1

    window = Image.open(src)
    width, height = window.size
    if width < 800 or height < 500:
        print(f"crop: {src} is {width}×{height} — that is not a window", file=sys.stderr)
        return 1

    for name, (l, t, r, b) in sorted(REGIONS.items()):
        box = (round(width * l), round(height * t), round(width * r), round(height * b))
        piece = window.crop(box)
        stem, ext = os.path.splitext(name)
        dest = os.path.join(out_dir, f"{stem}-{lang}{ext}")
        piece.save(dest)
        print(f"  {os.path.basename(dest)}  {piece.width}×{piece.height}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
