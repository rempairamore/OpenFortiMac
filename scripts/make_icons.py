"""The app icon in every size the app and the site use, from scripts/icon/app-icon.svg.

    uv run --with playwright scripts/make_icons.py [path of a Chromium executable]

Without a path Playwright uses its own Chromium (`playwright install chromium`). A browser
does the drawing because the icon has SVG shadows, which macOS's own SVG reader ignores.

Writes OpenFortiMac/Assets.xcassets/AppIcon.appiconset/icon_*.png and, for the site,
docs/assets/icon.png, favicon.png and apple-touch-icon.png.
"""
import sys
from pathlib import Path
from playwright.sync_api import sync_playwright

repo = Path(__file__).resolve().parent.parent
executable = sys.argv[1] if len(sys.argv) > 1 else None
source = (repo / "scripts/icon/app-icon.svg").read_text()

# The app icon: the macOS grid, a tile of 824 in a canvas of 1024, with its shadow
app = source
# For the site: the tile alone fills the picture, without the outer shadow
tight = (source.replace('viewBox="0 0 1024 1024"', 'viewBox="97 97 830 830"')
               .replace('<g filter="url(#drop)"><rect', '<g><rect'))
# For iOS home screens: a full square, the system rounds the corners by itself
square = (tight.replace('viewBox="97 97 830 830"', 'viewBox="100 100 824 824"')
               .replace('rx="186"', 'rx="0"').replace('rx="184.5"', 'rx="0"'))
assert tight != source and square != tight


def small(svg: str) -> str:
    """For 16 and 32 pixels: a larger shield and a thicker check, or the check turns into a smudge."""
    opening = '<g clip-path="url(#tile)">\n'
    start = svg.index(opening) + len(opening)
    end = svg.index('</g>\n<rect x="101.5"')
    grown = ('<g transform="translate(512 521) scale(1.22) translate(-512 -521)">\n'
             + svg[start:end].replace('stroke-width="62"', 'stroke-width="84"') + '</g>\n')
    return svg[:start] + grown + svg[end:]


variants = {"app": app, "tight": tight, "square": square, "app-small": small(app), "tight-small": small(tight)}
assert variants["app-small"] != app
jobs = [("app-small" if size <= 32 else "app", size, repo / f"OpenFortiMac/Assets.xcassets/AppIcon.appiconset/icon_{size}x{size}.png")
        for size in (16, 32, 64, 128, 256, 512, 1024)]
jobs += [("tight", 256, repo / "docs/assets/icon.png"),
         ("tight-small", 32, repo / "docs/assets/favicon.png"),
         ("square", 180, repo / "docs/assets/apple-touch-icon.png")]

with sync_playwright() as p:
    browser = p.chromium.launch(executable_path=executable)
    for name, size, target in jobs:
        page = browser.new_page(viewport={"width": size, "height": size}, device_scale_factor=1)
        drawing = variants[name].replace('width="1024" height="1024"', f'width="{size}" height="{size}" style="display:block"', 1)
        page.set_content(f'<body style="margin:0;background:transparent">{drawing}</body>')
        page.wait_for_timeout(150)
        page.screenshot(path=str(target), omit_background=(name != "square"), clip={"x": 0, "y": 0, "width": size, "height": size})
        page.close()
        print(f"{target.relative_to(repo)}  {size}x{size}")
    browser.close()
