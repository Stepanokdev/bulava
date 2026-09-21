"""The logo, for the documents the engine renders in Python.

The curves live in the app (`Night Shift/Design/BulavaGlyph.swift`) and are written out as an SVG by
`tools/icongen`. Python reads that asset rather than carrying a second copy of the path: two hand-kept
copies of a logo drift, and the drift always shows up in the artefact a client sees.

If the asset is missing, the header simply loses its mark. A report without a logo is still a report.
"""
import os
import re

ASSET = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "brand-mark.svg")


def mark(height_css="14px"):
    """The bare `<svg>`, sized by CSS. Returns "" when the asset is not there."""
    try:
        with open(ASSET, encoding="utf-8") as fh:
            svg = fh.read().strip()
    except OSError:
        return ""
    # Drop the intrinsic size: the asset's numbers are whatever the generator last wrote, and a
    # document header wants its own size.
    svg = re.sub(r'\s(?:width|height)="[^"]*"', "", svg, count=2)
    return svg.replace("<svg", f'<svg style="height:{height_css};width:auto"', 1)


def lockup():
    """Plate, mark and wordmark — the same lockup the app's sidebar shows."""
    glyph = mark()
    if not glyph:
        return ""
    return ('<div class="brand"><span class="plate">' + glyph
            + '</span><span class="word">bulava<em>.app</em></span></div>')


CSS = """
.brand { display:flex; align-items:center; gap:9px; margin:0 0 22px; }
.brand .plate { width:24px; height:24px; border-radius:7px; background:var(--brand-field);
                display:flex; align-items:center; justify-content:center; flex:0 0 auto; }
.brand .plate svg { display:block; color:var(--brand); }
.brand .word { font-size:14px; font-weight:640; letter-spacing:-.36px; }
.brand .word em { font-style:normal; color:var(--t3); }
"""
