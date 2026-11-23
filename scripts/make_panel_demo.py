"""Pictures of the README and of the site, drawn from the app's real views with example data.

Compiles scripts/demo/main.swift together with the app's sources (the same views the app
shows, in a debug build that can be put in any state), lets it draw every frame off screen,
and assembles the animated demo. Nothing is taken from the screen and no VPN is involved.

Story of the demo: click the shield in the menu bar, the panel opens, Connect on
"Office VPN", connecting, connected.

Needs macOS with Xcode 26 (swiftc) and Pillow:

    uv run --with pillow scripts/make_panel_demo.py [output dir] [work dir]

Default output dir: docs/assets. It writes

    openfortimac-panel-demo.gif   the animated demo (README and site)
    openfortimac-themes.png       the three themes side by side (README only)

With a work dir the frames and the other stills are kept there (panel-connected.png is the
panel used in the link preview, docs/assets/og-image.png).
"""
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
RENDERER = "openfortimac-demo-renderer"
# The app's entry point and its AppKit delegate stay out: the renderer has its own main
NOT_IN_RENDERER = {"AppDelegate.swift", "OpenFortiMacApp.swift"}


def build_renderer(work: Path) -> Path:
    project = (REPO / "OpenFortiMac.xcodeproj/project.pbxproj").read_text()
    version = re.search(r"MARKETING_VERSION = ([^;]+);", project).group(1)
    # The project has a default and the app target its own, lower one: the app's is the lowest
    deployment = min(re.findall(r"MACOSX_DEPLOYMENT_TARGET = ([^;]+);", project),
                     key=lambda text: [int(part) for part in text.split(".")])

    # A command-line binary has no bundle: this gives it the version the panel shows
    plist = work / "Info.plist"
    plist.write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>{RENDERER}</string>
<key>CFBundleShortVersionString</key><string>{version}</string>
</dict></plist>
""")

    sources = sorted(p for p in (REPO / "OpenFortiMac").glob("*.swift") if p.name not in NOT_IN_RENDERER)
    binary = work / RENDERER
    subprocess.run(
        ["swiftc", "-swift-version", "5", "-default-isolation", "MainActor", "-D", "DEBUG",
         "-target", f"{platform.machine()}-apple-macos{deployment}",
         "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", str(plist),
         "-o", str(binary), *map(str, sources), str(REPO / "scripts/demo/main.swift")],
        check=True,
    )
    return binary


def render(binary: Path, work: Path) -> Path:
    frames = work / "frames"
    frames.mkdir(exist_ok=True)
    # An empty home: the renderer never reads the real config.json
    home = work / "home"
    home.mkdir(exist_ok=True)
    try:
        subprocess.run(
            [str(binary), str(frames), "-AppleLanguages", "(en)", "-AppleLocale", "en_US"],
            check=True, env=dict(os.environ, CFFIXED_USER_HOME=str(home)),
        )
    finally:
        # The theme the renderer switched to is saved in its own preferences: drop them
        subprocess.run(["defaults", "delete", RENDERER], capture_output=True)
    return frames


def write_gif(frames: Path, output: Path) -> str:
    info = json.loads((frames / "frames.json").read_text())
    durations = info["durations"]
    images = [Image.open(frames / f"frame-{index:03d}.png").convert("RGB") for index in range(len(durations))]

    # One palette for the whole film, from a strip of frames spread over it: the same color
    # stays the same from frame to frame, and nothing flickers
    samples = images[::3] + [images[-1]]
    strip = Image.new("RGB", (images[0].width, images[0].height * len(samples)))
    for row, image in enumerate(samples):
        strip.paste(image, (0, row * image.height))
    # Maximum coverage keeps the colors that fill few pixels (the blue of "Connect"), which
    # median cut gives up in a picture that is mostly dark
    palette = strip.quantize(colors=255, method=Image.Quantize.MAXCOVERAGE, dither=Image.Dither.NONE)

    paletted = [image.quantize(palette=palette, dither=Image.Dither.NONE) for image in images]
    paletted[0].save(output, save_all=True, append_images=paletted[1:], loop=0,
                     duration=[round(seconds * 1000) for seconds in durations])
    return f"{len(images)} frames, {sum(durations):.1f} s, {images[0].width}x{images[0].height}"


def main() -> None:
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "docs/assets"
    output.mkdir(parents=True, exist_ok=True)
    keep = Path(sys.argv[2]) if len(sys.argv) > 2 else None

    with tempfile.TemporaryDirectory() as temporary:
        work = keep or Path(temporary)
        work.mkdir(parents=True, exist_ok=True)
        frames = render(build_renderer(work), work)

        gif = output / "openfortimac-panel-demo.gif"
        print(f"{gif}: {write_gif(frames, gif)}, {gif.stat().st_size // 1024} KB")

        themes = output / "openfortimac-themes.png"
        shutil.copyfile(frames / "themes.png", themes)
        with Image.open(themes) as picture:
            print(f"{themes}: {picture.width}x{picture.height}")


if __name__ == "__main__":
    main()
