"""Build assets/fonts/submersion-equipment.ttf from tool/equipment_glyphs.py.

The dive-gear shapes in Submersion's equipment list -- wetsuit, drysuit, BCD,
rebreather, hood, gloves, bootie, reel, DPV, regulator -- exist in no icon
font, so they are drawn here and compiled into a small private font. Shipping
them as a font rather than as SVG or a painter keeps `equipmentTypeIcon`
returning `IconData`, so every call site keeps working and the glyphs inherit
IconTheme size, colour and directionality for free.

Run by hand whenever the glyph geometry changes, then commit the .ttf so no
contributor needs fonttools to build the app:

    pip install fonttools
    python3 tool/build_equipment_icon_font.py

Verify the result with --verify, which reads the glyphs back out of the font
it just wrote and reports their bounds.
"""

import argparse
import os
import sys

from fontTools.fontBuilder import FontBuilder
from fontTools.misc.transform import Transform
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.reverseContourPen import ReverseContourPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import parse_path
from fontTools.ttLib import TTFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from equipment_glyphs import CODE_POINTS, GLYPHS  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "assets", "fonts", "submersion-equipment.ttf")

FAMILY = "Submersion Equipment"
VERSION = "1.000"
UPEM = 1000
GRID = 24
# Cubic-to-quadratic tolerance in font units: half of one 24-grid unit is well
# under a device pixel at any size the app renders icons at.
MAX_ERR = UPEM / GRID / 2

# 2026-01-01T00:00:00Z expressed in the TrueType epoch, which starts at
# 1904-01-01 (Unix time plus 2082844800). Any fixed value works; what matters
# is that it never changes, so the build is reproducible.
FONT_EPOCH_STAMP = 1767225600 + 2082844800


def build_glyph(path_data):
    """Convert one 24-grid SVG path into a TrueType glyph.

    SVG is y-down and the font is y-up, so the transform flips Y and lands the
    icon box exactly on the em box: SVG y=0 maps to the ascender and y=24 to
    the baseline. Reversing the contours afterwards restores TrueType's
    convention of clockwise outer contours, which the Y flip would otherwise
    invert. Nonzero winding would fill correctly either way, but matching the
    convention keeps font validators quiet.
    """
    pen = TTGlyphPen(None)
    chain = TransformPen(
        ReverseContourPen(Cu2QuPen(pen, MAX_ERR)),
        Transform(UPEM / GRID, 0, 0, -UPEM / GRID, 0, UPEM),
    )
    parse_path(path_data, chain)
    return pen.glyph()


def build():
    names = list(GLYPHS)
    fb = FontBuilder(UPEM, isTTF=True)
    fb.setupGlyphOrder([".notdef"] + names)
    fb.setupCharacterMap({CODE_POINTS[name]: name for name in names})

    glyphs = {".notdef": TTGlyphPen(None).glyph()}
    for name in names:
        glyphs[name] = build_glyph(GLYPHS[name]["d"])
    fb.setupGlyf(glyphs)

    # A full-em advance keeps every icon square, which is what Icon() assumes
    # when it sizes the glyph by font size.
    fb.setupHorizontalMetrics({name: (UPEM, 0) for name in glyphs})
    fb.setupHorizontalHeader(ascent=UPEM, descent=0)
    fb.setupNameTable(
        {
            "familyName": FAMILY,
            "styleName": "Regular",
            "uniqueFontIdentifier": f"{FAMILY} {VERSION}",
            "fullName": FAMILY,
            "psName": FAMILY.replace(" ", ""),
            "version": VERSION,
        }
    )
    fb.setupOS2(
        sTypoAscender=UPEM,
        sTypoDescender=0,
        sTypoLineGap=0,
        usWinAscent=UPEM,
        usWinDescent=0,
        achVendID="SUBM",
    )
    fb.setupPost(keepGlyphNames=False)

    # fontTools stamps head.created and head.modified with the current time, so
    # rebuilding unchanged geometry would still produce a byte-different file
    # and churn the committed binary. Pin both to a fixed date (seconds since
    # the 1904 font epoch) to keep the build reproducible: an unchanged rebuild
    # then leaves the .ttf untouched in git.
    head = fb.font["head"]
    head.created = head.modified = FONT_EPOCH_STAMP

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    fb.save(OUT)
    return names


def verify():
    """Read the glyphs back out of the font and report what actually landed.

    A code point that never made it into the cmap, or a path that collapsed to
    nothing, shows up here as a missing entry or an empty bounding box rather
    than as tofu on a device.
    """
    font = TTFont(OUT)
    cmap = font.getBestCmap()
    glyphset = font.getGlyphSet()
    problems = []

    for name in GLYPHS:
        cp = CODE_POINTS[name]
        # Glyph names are dropped from post to keep the font small, so the
        # reloaded font calls them uniXXXX. The cmap is what the app uses, so
        # that is what gets checked.
        mapped = cmap.get(cp)
        if mapped is None:
            problems.append(f"{name}: U+{cp:04X} is not in the cmap")
            continue
        rec = RecordingPen()
        glyphset[mapped].draw(rec)
        if not rec.value:
            problems.append(f"{name}: empty outline")
            continue
        # glyf's own bounds are the ink bounds. Measuring the drawn points
        # instead would flag off-curve control points, which legitimately sit
        # outside the shape they steer.
        glyph = font["glyf"][mapped]
        print(
            f"  {name:12s} U+{cp:04X}  "
            f"x {glyph.xMin:4d}..{glyph.xMax:4d}  y {glyph.yMin:4d}..{glyph.yMax:4d}  "
            f"{glyph.numberOfContours} contours"
        )
        if glyph.xMin < 0 or glyph.xMax > UPEM or glyph.yMin < 0 or glyph.yMax > UPEM:
            problems.append(
                f"{name}: ink escapes the em box "
                f"(x {glyph.xMin}..{glyph.xMax}, y {glyph.yMin}..{glyph.yMax}); "
                f"it would be clipped on device"
            )

    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--verify", action="store_true", help="read the font back and check it")
    args = ap.parse_args()

    names = build()
    size = os.path.getsize(OUT)
    print(f"wrote {OUT} ({size} bytes, {len(names)} glyphs)")

    if args.verify:
        print("verifying:")
        problems = verify()
        if problems:
            for p in problems:
                print(f"FAIL {p}", file=sys.stderr)
            return 1
        print("all glyphs present and inside the em box")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
