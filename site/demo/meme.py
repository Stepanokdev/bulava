#!/usr/bin/env python3
"""Put the joke's words on the drawing, in both languages.

    meme.py <base.png> <out-dir>

The joke comes from the presentation, where it ran over a comic somebody else drew. On a slide in
a room that is a quotation; on an indexed commercial page it is an unlicensed illustration, so the
artwork here is our own (generated, prompt in site/assets/README.md) and only the composition is
borrowed from the original gag.

The words are drawn here rather than asked of the image model, for the ordinary reason: an image
model spells "покличу" four different ways in four attempts, and the whole point of the panel is
that the line is exact. The original said «Я зараз Ваню покличу» — a person by name. The version
that goes on a public page says "a human", because the product's argument is about people in
general and not about one of them.
"""

import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("meme: needs Pillow — python3 -m pip install --user Pillow", file=sys.stderr)
    raise SystemExit(3)

BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
BLACK = "/System/Library/Fonts/Supplemental/Arial Black.ttf"

LINES = {
    "en": {
        "shout": "I'll call a human —\ndo it properly!",
        "mumble": "Okay…\nokay…",
    },
    "uk": {
        "shout": "Я зараз людину покличу,\nроби нормально!",
        "mumble": "Добре…\nдобре…",
    },
}
# Fractions of the panel: where each bubble sits and where each label goes. Tuned against the
# generated artwork — the big figure on the right, the small one seated on the left.
SHOUT = (0.045, 0.055, 0.52, 0.215)      # left, top, right, bottom
SHOUT_TAIL = (0.505, 0.20, 0.60, 0.105)  # from the bubble edge towards the speaker
MUMBLE = (0.255, 0.40, 0.50, 0.53)
MUMBLE_TAIL = (0.275, 0.53, 0.20, 0.60)
LABEL_BIG = (0.735, 0.30)
LABEL_SMALL = (0.178, 0.735)


def _fit(draw, text, font_path, box, start):
    """The largest size at which the text still fits the bubble, with a little air."""
    left, top, right, bottom = box
    width, height = (right - left) * 0.84, (bottom - top) * 0.74
    size = start
    while size > 8:
        font = ImageFont.truetype(font_path, size)
        bbox = draw.multiline_textbbox((0, 0), text, font=font, spacing=size * 0.22, align="center")
        if bbox[2] - bbox[0] <= width and bbox[3] - bbox[1] <= height:
            return font
        size -= 1
    return ImageFont.truetype(font_path, 8)


def _bubble(draw, box, tail, panel):
    left, top, right, bottom = [c * panel[i % 2] for i, c in enumerate(box)]
    draw.rounded_rectangle((left, top, right, bottom), radius=(bottom - top) * 0.34,
                           fill="white", outline="black", width=max(2, panel[0] // 220))
    x1, y1, x2, y2 = tail
    draw.polygon([(x1 * panel[0], y1 * panel[1]),
                  (x2 * panel[0], y2 * panel[1]),
                  (x1 * panel[0] + panel[0] * 0.035, y1 * panel[1] - panel[1] * 0.02)],
                 fill="white", outline="black")
    # The outline of the tail crosses the bubble's own edge; painting the seam back in white is
    # what makes the two read as one shape rather than a box with a triangle glued to it.
    draw.line((left + (right - left) * 0.55, bottom, right, bottom - (bottom - top) * 0.18),
              fill="white", width=max(3, panel[0] // 200))
    return (left, top, right, bottom)


def _label(draw, text, at, panel, size_frac):
    font = ImageFont.truetype(BLACK, int(panel[0] * size_frac))
    x, y = at[0] * panel[0], at[1] * panel[1]
    # A white halo, because the shirt it sits on is white and the trousers are not.
    for dx in (-2, 0, 2):
        for dy in (-2, 0, 2):
            draw.text((x + dx, y + dy), text, font=font, fill="white", anchor="mm")
    draw.text((x, y), text, font=font, fill="black", anchor="mm")


def build(base_path, lang, out_path):
    panel = Image.open(base_path).convert("RGB")
    size = panel.size
    draw = ImageDraw.Draw(panel)

    for box, tail, key, start in ((SHOUT, SHOUT_TAIL, "shout", int(size[0] * 0.062)),
                                  (MUMBLE, MUMBLE_TAIL, "mumble", int(size[0] * 0.05))):
        rect = _bubble(draw, box, tail, size)
        text = LINES[lang][key]
        font = _fit(draw, text, BOLD, rect, start)
        cx = (rect[0] + rect[2]) / 2
        cy = (rect[1] + rect[3]) / 2
        draw.multiline_text((cx, cy), text, font=font, fill="black", anchor="mm",
                            align="center", spacing=font.size * 0.22)

    _label(draw, "CODEX", LABEL_BIG, size, 0.030)
    _label(draw, "CLAUDE\nCODE", LABEL_SMALL, size, 0.022)
    panel.save(out_path, quality=88, optimize=True)
    return out_path


def main():
    if len(sys.argv) != 3:
        print("usage: meme.py <base.png> <out-dir>", file=sys.stderr)
        return 2
    base, out_dir = sys.argv[1], sys.argv[2]
    for lang in LINES:
        path = os.path.join(out_dir, f"meme-{lang}.jpg")
        build(base, lang, path)
        print(f"  {os.path.basename(path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
