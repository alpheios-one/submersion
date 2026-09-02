#!/usr/bin/env python3
"""Import the website's screenshots into the README asset directory.

Run from the repo root:  python3 scripts/readme/import_website_shots.py [SRC_DIR]

Source images live in the sibling submersion-website repository
(https://github.com/submersion-app/submersion-website) under `screenshots/`.
Pass SRC_DIR to point at a checkout somewhere else, or set SUBMERSION_WEBSITE.

Requires Pillow (`pip3 install --user Pillow`).
"""

import os
import sys

from PIL import Image

DEFAULT_SRC = "../submersion-website/screenshots"
OUT_DIR = "docs/assets/screenshots/readme"

SHOWCASE_WIDTH = 1600
GALLERY_WIDTH = 900
QUALITY = 85

# (source name, output name, target width). The numeric prefix is the order the
# image appears in README.md; 01-08 are the showcase rows, 09-14 the gallery.
MAPPING = [
    ("dive_detail.png", "01-dive-logging.jpg", SHOWCASE_WIDTH),
    ("tissue_loading.png", "02-profile-deco.jpg", SHOWCASE_WIDTH),
    ("computer_import.png", "03-dive-computers.jpg", SHOWCASE_WIDTH),
    ("sites_map.png", "04-sites-maps.jpg", SHOWCASE_WIDTH),
    ("planner.png", "05-planning.jpg", SHOWCASE_WIDTH),
    ("photo_gallery.png", "06-photos-gear.jpg", SHOWCASE_WIDTH),
    ("statistics.png", "07-statistics.jpg", SHOWCASE_WIDTH),
    ("sync_settings.png", "08-your-data.jpg", SHOWCASE_WIDTH),
    ("profile_player.png", "09-profile-player.jpg", GALLERY_WIDTH),
    ("dive_3d.png", "10-tissue-3d.jpg", GALLERY_WIDTH),
    ("site_detail.png", "11-site-terrain.jpg", GALLERY_WIDTH),
    ("marine_life.png", "12-marine-life.jpg", GALLERY_WIDTH),
    ("gas_blender.png", "13-gas-blender.jpg", GALLERY_WIDTH),
    ("themes.png", "14-themes.jpg", GALLERY_WIDTH),
]

# Alpha at or above this counts as opaque. The macOS window screenshots are
# fully opaque apart from the anti-aliased arc at each rounded corner, so a
# lower threshold would let the black underneath bleed into the fill color.
OPAQUE = 250


def flatten(img):
    """Drop alpha, squaring off rounded corners with the window's own color.

    The transparent corner arcs sit over black. Compositing onto any fixed
    matte leaves four nubs that show against one of GitHub's two themes, so
    each transparent pixel instead takes the color of the nearest opaque pixel
    in its row. Corners end up squared in the titlebar/content color, which
    reads correctly in both light and dark.
    """
    if img.mode not in ("RGBA", "LA") and "transparency" not in img.info:
        return img.convert("RGB")

    img = img.convert("RGBA")
    width, height = img.size
    alpha = img.getchannel("A").load()
    pixels = img.load()

    for y in range(height):
        if alpha[0, y] >= OPAQUE and alpha[width - 1, y] >= OPAQUE:
            continue  # interior row, nothing to extend

        left = next((x for x in range(width) if alpha[x, y] >= OPAQUE), None)
        if left is None:
            continue  # fully transparent row: nothing to extend from
        right = next(x for x in range(width - 1, -1, -1) if alpha[x, y] >= OPAQUE)

        fill = pixels[left, y]
        for x in range(left):
            pixels[x, y] = fill
        fill = pixels[right, y]
        for x in range(right + 1, width):
            pixels[x, y] = fill

    return img.convert("RGB")


def main():
    src_dir = (
        sys.argv[1]
        if len(sys.argv) > 1
        else os.environ.get("SUBMERSION_WEBSITE", DEFAULT_SRC)
    )
    if not os.path.isdir(src_dir):
        sys.exit(
            f"source directory not found: {src_dir}\n"
            "Clone https://github.com/submersion-app/submersion-website next to "
            "this repo, or pass the path to its screenshots/ directory."
        )

    os.makedirs(OUT_DIR, exist_ok=True)
    total = 0

    for src_name, out_name, width in MAPPING:
        src = os.path.join(src_dir, src_name)
        if not os.path.isfile(src):
            sys.exit(f"missing source screenshot: {src}")

        img = flatten(Image.open(src))
        height = round(img.height * width / img.width)
        img = img.resize((width, height), Image.LANCZOS)

        out = os.path.join(OUT_DIR, out_name)
        img.save(out, "JPEG", quality=QUALITY, optimize=True, progressive=True)

        size = os.path.getsize(out)
        total += size
        print(f"wrote {out} ({width}x{height}, {size / 1024:.0f} KB)")

    print(f"\n{len(MAPPING)} images, {total / 1024 / 1024:.2f} MB total")


if __name__ == "__main__":
    main()
