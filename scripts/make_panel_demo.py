"""Animated demo of the OpenFortiMac menu bar panel, with example data.

Draws every frame as SVG (same layout as MenuPanelView.swift: 320pt wide, 12pt padding,
40pt status circle), rasterizes them at 2x with Quick Look and assembles the GIF with ffmpeg.
Story: click the menu bar icon, the panel opens, Connect on "Office VPN", connecting, connected.

Requires macOS (qlmanage) and ffmpeg (brew install ffmpeg).

    python3 scripts/make_panel_demo.py [output.gif]

Default output: docs/assets/openfortimac-panel-demo.gif (used by the README and the site).
"""
import math
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

W = 320
M = 18
ARROW_H = 10
ARROW_HALF = 12
CANVAS_W = W + 2 * M
MENU_H = 24             # macOS menu bar
PANEL_TOP = MENU_H + 4  # popover arrow tip, just below the menu bar
CANVAS_H = PANEL_TOP + ARROW_H + 283 + 18   # tallest panel (connected) plus bottom margin
ICON_X = M + W / 2      # status item centred above the popover arrow
ICON_Y = MENU_H / 2

FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif"
PAGE = "#0c0e12"        # site background
BG = "#2c2c2e"
STROKE = "rgba(255,255,255,0.14)"
DIVIDER = "rgba(255,255,255,0.10)"
INK = "#f5f5f7"
DIM = "#98989d"
GREEN = "#30d158"
ORANGE = "#ff9f0a"
BLUE = "#0a84ff"

SERVERS = [
    ("Office VPN", "vpn.example.com", "building"),
    ("Home Lab", "home.example.net", "house"),
    ("Customer Acme", "ssl.acme.example", "briefcase"),
]


def text(x, y, s, size, color=INK, weight=400, anchor="start", extra=""):
    return (f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{color}" '
            f'text-anchor="{anchor}" {extra}>{s}</text>')


def gear_path(teeth=8, r_out=7.0, r_in=5.3):
    pts = []
    step = 360 / teeth
    for k in range(teeth):
        a = k * step
        for r, da in ((r_in, -15), (r_out, -8), (r_out, 8), (r_in, 15)):
            t = math.radians(a + da)
            pts.append(f"{8 + r * math.cos(t):.2f} {8 + r * math.sin(t):.2f}")
    return "M" + " L".join(pts) + " Z"


def icon(name, cx, cy, color, sw=1.5, scale=1.0):
    g = (f'<g transform="translate({cx} {cy}) scale({scale}) translate(-8 -8)" fill="none" stroke="{color}" '
         f'stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round">')
    shapes = {
        "lock": f'<rect x="3" y="7" width="10" height="7.5" rx="1.8" fill="{color}" stroke="none"/><path d="M5 7V5a3 3 0 0 1 6 0v2"/>',
        "lock-open": f'<rect x="3" y="7" width="10" height="7.5" rx="1.8" fill="{color}" stroke="none"/><path d="M5 7V4.5a3 3 0 0 1 5.6-1.5"/>',
        "globe": '<circle cx="8" cy="8" r="6.2"/><ellipse cx="8" cy="8" rx="2.6" ry="6.2"/><path d="M1.8 8h12.4M2.8 4.8h10.4M2.8 11.2h10.4"/>',
        "building": '<rect x="2.5" y="2" width="7" height="12.5" rx="0.8"/><path d="M9.5 6.5h3.2a0.8 0.8 0 0 1 0.8 0.8v7.2M5 5h2M5 8h2M5 11h2M11.5 9.5h0.01M11.5 12h0.01"/>',
        "house": '<path d="M2 8.2 8 2.8l6 5.4"/><path d="M3.8 7v7h8.4V7"/><path d="M6.6 14v-3.6h2.8V14"/>',
        "briefcase": '<rect x="1.8" y="5" width="12.4" height="8.8" rx="1.6"/><path d="M5.8 5V3.6a1 1 0 0 1 1-1h2.4a1 1 0 0 1 1 1V5M1.8 8.8h12.4"/>',
        "plus": '<path d="M8 2.5v11M2.5 8h11"/>',
        "gear": f'<path d="{gear_path()}"/><circle cx="8" cy="8" r="2.2"/>',
        "doc": '<path d="M4 1.8h5.2l3 3V14a0.6 0.6 0 0 1-0.6 0.6H4a0.6 0.6 0 0 1-0.6-0.6V2.4A0.6 0.6 0 0 1 4 1.8z"/><path d="M9 1.8v3.2h3.2M5.6 8h4.8M5.6 10.5h4.8"/>',
        "power": '<path d="M8 1.8v6"/><path d="M4.6 4.2a5.2 5.2 0 1 0 6.8 0"/>',
    }
    return g + shapes[name] + "</g>"


def spinner(cx, cy, angle):
    # macOS-like activity indicator: 8 spokes fading around the circle
    out = []
    for k in range(8):
        a = math.radians(angle + k * 45)
        opacity = 0.25 + 0.75 * (k / 7)
        x1, y1 = cx + 4 * math.cos(a), cy + 4 * math.sin(a)
        x2, y2 = cx + 8 * math.cos(a), cy + 8 * math.sin(a)
        out.append(f'<path d="M{x1:.2f} {y1:.2f}L{x2:.2f} {y2:.2f}" stroke="{ORANGE}" stroke-width="2.2" '
                   f'stroke-linecap="round" opacity="{opacity:.2f}"/>')
    return "".join(out)


def row_top(index, mode):
    base = 88 if mode == "connected" else 64
    return base + 27 + index * 42


def panel(mode, hover=False, pressed=False, angle=0, elapsed="00:00:01"):
    out = []
    tint = {"connected": GREEN, "connecting": ORANGE}.get(mode, DIM)
    out.append(f'<circle cx="32" cy="32" r="20" fill="{tint}" fill-opacity="0.18"/>')
    if mode == "connecting":
        out.append(spinner(32, 32, angle))
    else:
        out.append(icon("lock" if mode == "connected" else "lock-open", 32, 32, tint, sw=1.6, scale=1.3))

    if mode == "disconnected":
        out.append(text(64, 28, "Not connected", 14, weight=600))
        out.append(text(64, 45, "Choose a server to connect", 11.5, DIM))
        y = 64
    else:
        out.append(text(64, 28, "Office VPN", 14, weight=600))
        sub = "Connecting…" if mode == "connecting" else f"Connected · {elapsed}"
        out.append(text(64, 45, sub, 11.5, DIM, extra='font-variant-numeric="tabular-nums"'))
        label, bw = ("Cancel", 64) if mode == "connecting" else ("Disconnect", 84)
        bx = W - 12 - bw
        out.append(f'<rect x="{bx}" y="21" width="{bw}" height="22" rx="5.5" fill="rgba(255,255,255,0.14)" stroke="rgba(255,255,255,0.08)"/>')
        out.append(text(bx + bw / 2, 36, label, 12.5, INK, 500, "middle"))
        y = 64
        if mode == "connected":
            out.append(icon("globe", 20, 69, DIM, sw=1.3))
            out.append(text(32, 73, "10.212.134.5", 11.5, DIM))
            out.append(icon("globe", 124, 69, DIM, sw=1.3))
            out.append(text(136, 73, "vpn.example.com:443", 11.5, DIM))
            y = 88

    out.append(f'<path d="M0 {y}H{W}" stroke="{DIVIDER}"/>')
    out.append(text(16, y + 20, "Servers", 11, DIM))
    for i, (name, host, glyph) in enumerate(SERVERS):
        top = row_top(i, mode)
        active = mode in ("connecting", "connected") and i == 0
        dimmed = mode in ("connecting", "connected") and not active
        g = f'<g opacity="{0.45 if dimmed else 1}">'
        if mode == "disconnected" and i == 0 and (hover or pressed):
            fill = 0.16 if pressed else 0.08
            g += f'<rect x="8" y="{top}" width="{W - 16}" height="40" rx="6" fill="rgba(255,255,255,{fill})"/>'
        g += icon(glyph, 26, top + 20, GREEN if active else DIM)
        g += text(46, top + 18, name, 13.5)
        g += text(46, top + 33, host, 11.5, DIM)
        if active:
            g += f'<circle cx="{W - 20}" cy="{top + 20}" r="4" fill="{GREEN}"/>'
        if mode == "disconnected" and i == 0 and (hover or pressed):
            g += text(W - 18, top + 24, "Connect", 11.5, BLUE, 500, "end")
        out.append(g + "</g>")
    y = row_top(len(SERVERS), mode) - 2 + 8

    out.append(f'<path d="M0 {y}H{W}" stroke="{DIVIDER}"/>')
    fy = y + 18
    for cx, glyph in ((22, "plus"), (54, "gear"), (86, "doc"), (W - 22, "power")):
        out.append(icon(glyph, cx, fy, DIM, sw=1.4))
    return out, y + 36


def cursor(x, y, pressed=False):
    # macOS arrow pointer, hotspot at the tip
    s = 0.88 if pressed else 1.0
    ripple = (f'<circle cx="{x}" cy="{y}" r="12" fill="none" stroke="{BLUE}" stroke-width="1.5" opacity="0.45"/>'
              if pressed else "")
    return (ripple + f'<g transform="translate({x} {y}) scale({s})">'
            '<path d="M0 0V16.5L3.9 12.9L6.4 18.8L9.1 17.7L6.6 11.9H12Z" fill="#000" stroke="#fff" '
            'stroke-width="1.3" stroke-linejoin="round"/></g>')


def status_glyph(name, cx, cy, color):
    """Small menu bar glyphs drawn in a 16x16 box."""
    g = (f'<g transform="translate({cx - 8} {cy - 8})" fill="none" stroke="{color}" '
         f'stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">')
    shapes = {
        "circlepath": '<path d="M12.8 6.4A5 5 0 0 0 3.5 6"/><path d="M2.6 3.4L3.5 6L6.1 5.3"/>'
                      '<path d="M3.2 9.6A5 5 0 0 0 12.5 10"/><path d="M13.4 12.6L12.5 10L9.9 10.7"/>',
        "wifi": f'<circle cx="8" cy="12.4" r="1.1" fill="{color}" stroke="none"/><path d="M5.5 9.9a3.5 3.5 0 0 1 5 0"/>'
                '<path d="M3.4 7.7a6.3 6.3 0 0 1 9.2 0"/><path d="M1.3 5.5a9.2 9.2 0 0 1 13.4 0"/>',
        "battery": f'<rect x="1" y="4.5" width="13" height="7" rx="2"/><rect x="2.6" y="6.1" width="8.4" height="3.8" rx="1" fill="{color}" stroke="none"/><path d="M15.4 7v2"/>',
        "cloud": '<path d="M4.6 12.4h7a2.7 2.7 0 0 0 .3-5.4 4 4 0 0 0-7.6 1.1A2.2 2.2 0 0 0 4.6 12.4z"/>',
    }
    return g + shapes[name] + "</g>"


def menubar(state, highlighted):
    out = [f'<rect width="{CANVAS_W}" height="{MENU_H}" fill="#1c1e23"/>',
           f'<path d="M0 {MENU_H - 0.5}H{CANVAS_W}" stroke="rgba(255,255,255,0.07)"/>']
    if highlighted:
        # macOS highlights a status item while its popover is open
        out.append(f'<rect x="{ICON_X - 14}" y="2" width="28" height="20" rx="5" fill="rgba(255,255,255,0.22)"/>')
    if state == "connected":
        out.append(icon("lock", ICON_X, ICON_Y, GREEN, sw=1.4, scale=0.95))
    elif state == "connecting":
        out.append(status_glyph("circlepath", ICON_X, ICON_Y, INK))
    else:
        out.append(icon("lock-open", ICON_X, ICON_Y, INK, sw=1.4, scale=0.95))
    out.append(status_glyph("cloud", ICON_X - 34, ICON_Y, INK))
    out.append(status_glyph("wifi", ICON_X + 34, ICON_Y, INK))
    out.append(status_glyph("battery", ICON_X + 66, ICON_Y, INK))
    out.append(text(CANVAS_W - 10, 16.5, "Mon 22:58", 12.5, INK, 500, "end"))
    return "".join(out)


def popover_svg(mode, opacity=1.0, dy=0.0, **kw):
    body, h = panel(mode, **kw)
    ax = W / 2
    r = 12
    outline = (f"M{r} {ARROW_H} H{ax - ARROW_HALF} L{ax} 0 L{ax + ARROW_HALF} {ARROW_H} H{W - r} "
               f"A{r} {r} 0 0 1 {W} {ARROW_H + r} V{ARROW_H + h - r} A{r} {r} 0 0 1 {W - r} {ARROW_H + h} "
               f"H{r} A{r} {r} 0 0 1 0 {ARROW_H + h - r} V{ARROW_H + r} A{r} {r} 0 0 1 {r} {ARROW_H} Z")
    return (f'<g transform="translate({M} {PANEL_TOP + dy})" opacity="{opacity}">'
            f'<path d="{outline}" fill="{BG}" stroke="{STROKE}" filter="url(#shadow)"/>'
            f'<g transform="translate(0 {ARROW_H})">{"".join(body)}</g></g>')


def frame_svg(bar="disconnected", open_=False, popover=None, cur=None, pressed=False):
    pop = popover_svg(**popover) if popover else ""
    cursor_svg = cursor(*cur, pressed=pressed) if cur else ""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS_W}" height="{CANVAS_H}" viewBox="0 0 {CANVAS_W} {CANVAS_H}" font-family="{FONT}">
<defs><filter id="shadow" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="6" stdDeviation="8" flood-color="#000" flood-opacity="0.45"/></filter></defs>
<rect width="{CANVAS_W}" height="{CANVAS_H}" fill="{PAGE}"/>
{menubar(bar, open_)}
{pop}
{cursor_svg}
</svg>
"""


def ease(t):
    return t * t * (3 - 2 * t)


def lerp(a, b, t):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def build_frames():
    frames = []  # (svg, duration in seconds)

    icon_pt = (ICON_X + 1, ICON_Y + 2)
    row_y = PANEL_TOP + ARROW_H + row_top(0, "disconnected")
    click = (M + W - 44, row_y + 22)          # on the "Connect" label of Office VPN
    row_box = (M + 8, row_y, M + W - 8, row_y + 40)
    start = (CANVAS_W - 70, CANVAS_H - 90)
    away = (M + 250, PANEL_TOP + ARROW_H + 172)  # empty side of the dimmed Home Lab row

    def inside(p):
        return row_box[0] <= p[0] <= row_box[2] and row_box[1] <= p[1] <= row_box[3]

    # 1. Desktop with the menu bar icon, pointer moves to it and clicks
    frames.append((frame_svg(cur=start), 1.0))
    for k in range(1, 13):
        frames.append((frame_svg(cur=lerp(start, icon_pt, ease(k / 12))), 0.04))
    frames.append((frame_svg(cur=icon_pt), 0.3))
    frames.append((frame_svg(open_=True, cur=icon_pt, pressed=True), 0.15))

    # 2. Popover fades in under the icon
    for opacity, dy in ((0.35, -6), (0.7, -3), (1.0, 0)):
        frames.append((frame_svg(open_=True, popover={"mode": "disconnected", "opacity": opacity, "dy": dy}, cur=icon_pt), 0.05))
    frames.append((frame_svg(open_=True, popover={"mode": "disconnected"}, cur=icon_pt), 0.5))

    # 3. Pointer goes to Office VPN and clicks Connect
    for k in range(1, 15):
        p = lerp(icon_pt, click, ease(k / 14))
        frames.append((frame_svg(open_=True, popover={"mode": "disconnected", "hover": inside(p)}, cur=p), 0.04))
    frames.append((frame_svg(open_=True, popover={"mode": "disconnected", "hover": True}, cur=click), 0.6))
    frames.append((frame_svg(open_=True, popover={"mode": "disconnected", "pressed": True}, cur=click, pressed=True), 0.18))

    # 4. Connecting: spinner turns, menu bar icon shows the progress arrows
    for k in range(14):
        p = lerp(click, away, ease(min(1, k / 8)))
        frames.append((frame_svg(bar="connecting", open_=True, popover={"mode": "connecting", "angle": k * 45}, cur=p), 0.09))

    # 5. Connected: green lock in the menu bar, timer ticks
    for sec in range(1, 5):
        frames.append((frame_svg(bar="connected", open_=True,
                                 popover={"mode": "connected", "elapsed": f"00:00:{sec:02d}"}, cur=away),
                       1.0 if sec < 4 else 1.6))

    return frames


def render(frames, output):
    """Rasterize the SVG frames at 2x with Quick Look and assemble the GIF with ffmpeg."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        sys.exit("ffmpeg not found: brew install ffmpeg")

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        svgs = []
        for i, (svg, _) in enumerate(frames):
            path = tmp / f"f{i:03d}.svg"
            path.write_text(svg)
            svgs.append(path)

        # Quick Look renders SVG with WebKit; it pads the PNG to a square, cropped below
        subprocess.run(["qlmanage", "-t", "-s", str(2 * CANVAS_W), "-o", str(tmp), *map(str, svgs)],
                       check=True, capture_output=True)

        lines = [f"file '{path}.png'\nduration {duration}" for path, (_, duration) in zip(svgs, frames)]
        # The concat demuxer needs the last file repeated to honour its duration
        lines.append(f"file '{svgs[-1]}.png'")
        concat = tmp / "frames.txt"
        concat.write_text("\n".join(lines) + "\n")

        subprocess.run([
            ffmpeg, "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(concat),
            "-vf", (f"crop={2 * CANVAS_W}:{2 * CANVAS_H}:0:0,split[a][b];"
                   "[a]palettegen=stats_mode=full:reserve_transparent=0[p];[b][p]paletteuse=dither=none"),
            "-fps_mode", "vfr", "-loop", "0", str(output),
        ], check=True)


if __name__ == "__main__":
    repo = Path(__file__).resolve().parent.parent
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "docs/assets/openfortimac-panel-demo.gif"
    frames = build_frames()
    render(frames, output)
    print(f"{output}: {len(frames)} frames, {sum(d for _, d in frames):.1f}s, {2 * CANVAS_W}x{2 * CANVAS_H}")
