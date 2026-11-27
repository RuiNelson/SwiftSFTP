#!/usr/bin/env python3
"""Generate the animated benchmark charts of the README (Documentation/benchmark-{upload,download}.svg).

Each configuration is a dot running back and forth along a track. The dot's speed is proportional to the measured
throughput: a dot makes one round trip (there and back) per second for every 10 MiB/s. Update the numbers in CHARTS from a new
benchmark run, then run this script from anywhere:

    python3 Scripts/generate-benchmark-charts.py [output-directory]
"""

import sys
from pathlib import Path

OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "Documentation"

FONT = '-apple-system,BlinkMacSystemFont,"SF Pro Display","SF Pro Text","Helvetica Neue",Arial,sans-serif'

# name, throughput label, delta label (None = baseline), seconds per run, series class
CHARTS = {
    "upload": ("Upload Throughput", [
        ("CITADEL", "5.05 MiB/s", None, 19.820, "blue"),
        ("SWIFTSFTP · 1 WORKER", "26.55 MiB/s", "+426%", 3.766, "orange"),
        ("SWIFTSFTP · 2 WORKERS", "25.29 MiB/s", "+401%", 3.954, "orange"),
        ("SWIFTSFTP · 2 WORKERS · RESUMABLE", "24.96 MiB/s", "+394%", 4.006, "orange"),
    ]),
    "download": ("Download Throughput", [
        ("CITADEL", "7.94 MiB/s", None, 12.589, "blue"),
        ("SWIFTSFTP · 1 WORKER", "22.36 MiB/s", "+182%", 4.473, "orange"),
        ("SWIFTSFTP · 2 WORKERS", "20.97 MiB/s", "+164%", 4.768, "orange"),
        ("SWIFTSFTP · 2 WORKERS · RESUMABLE", "20.74 MiB/s", "+161%", 4.821, "orange"),
    ]),
}

# The card is at most 380 px wide; everything else is laid out from this width.
WIDTH, HEIGHT = 380, 544
MARGIN = 8  # between the SVG's edge and the card
PAD = 24  # between the card's edge and its content
LEFT, RIGHT = MARGIN + PAD, WIDTH - MARGIN - PAD
TRACK_X, TRACK_W, TRACK_H = LEFT, RIGHT - LEFT, 20
ROW_TOP, ROW_PITCH = 116, 108
FILE_MIB = 100
# A dot makes one round trip (there and back) per second at this throughput; faster transfers are proportionally faster.
ROUND_TRIP_MIB_PER_SECOND = 10
DOT_R = 7
# The dot's centre runs from the track's left cap to its right cap.
TRAVEL = TRACK_W - TRACK_H


def text(x, y, cls, size, weight, body, anchor=None, spacing=None):
    a = f' text-anchor="{anchor}"' if anchor else ""
    s = f' letter-spacing="{spacing}"' if spacing else ""
    return (f'<text x="{x}" y="{y}"{a} font-family=\'{FONT}\' font-size="{size}" '
            f'font-weight="{weight}"{s} class="{cls}">{body}</text>')


def build(title, rows):
    out = []
    out.append(f'<svg viewBox="0 0 {WIDTH} {HEIGHT}" width="{WIDTH}" height="{HEIGHT}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="{title}">')
    out.append("""<style>    .surface { fill: #fcfcfb; }
    .card-stroke { stroke: rgba(11,11,11,0.10); }
    .ink { fill: #0b0b0b; }
    .secondary { fill: #52514e; }
    .muted { fill: #898781; }
    .good { fill: #006300; }
    .track { fill: #eeede7; }
    .series-orange { fill: #eb6834; }
    .series-blue { fill: #2a78d6; }
    .dot { animation-name: cross; animation-timing-function: linear; animation-iteration-count: infinite; animation-direction: alternate; }
    @keyframes cross { from { transform: translateX(0); } to { transform: translateX(%(travel)dpx); } }
    @media (prefers-reduced-motion: reduce) { .dot { animation: none; transform: translateX(%(travel)dpx); } }
    @media (prefers-color-scheme: dark) {
      .surface { fill: #1a1a19; }
      .card-stroke { stroke: rgba(255,255,255,0.10); }
      .ink { fill: #ffffff; }
      .secondary { fill: #c3c2b7; }
      .muted { fill: #898781; }
      .good { fill: #0ca30c; }
      .track { fill: #2c2c2a; }
      .series-orange { fill: #d95926; }
      .series-blue { fill: #3987e5; }
    }</style>""" % {"travel": TRAVEL})
    out.append(f'<rect x="{MARGIN}" y="{MARGIN}" width="{WIDTH - 2 * MARGIN}" height="{HEIGHT - 2 * MARGIN}" rx="24" ry="24" class="surface card-stroke" stroke-width="1"/>')
    mid = WIDTH / 2
    out.append(text(mid, 42, "ink", 21, 700, title, "middle", "-0.02em"))
    out.append(text(mid, 61, "muted", 10.5, 600, "100 MiB FILE · BEST OF 3 RUNS", "middle", "0.09em"))
    out.append(text(mid, 76, "muted", 10.5, 600, f"1 ROUND TRIP PER SECOND = {ROUND_TRIP_MIB_PER_SECOND} MiB/s", "middle", "0.09em"))

    for i, (name, rate, delta, secs, series) in enumerate(rows):
        y = ROW_TOP + i * ROW_PITCH
        out.append(text(LEFT, f"{y:.2f}", "secondary", 11, 700, name, spacing="0.07em"))
        out.append(text(LEFT, f"{y + 24:.2f}", "ink", 17, 700, rate, spacing="-0.01em"))
        if delta:
            out.append(text(RIGHT, f"{y + 24:.2f}", "good", 12, 700, delta, "end"))
        else:
            out.append(text(RIGHT, f"{y + 24:.2f}", "muted", 11, 700, "BASELINE", "end", "0.06em"))
        ty = y + 36
        out.append(f'<rect x="{TRACK_X}" y="{ty:.2f}" width="{TRACK_W}" height="{TRACK_H}" '
                   f'rx="{TRACK_H // 2}" ry="{TRACK_H // 2}" class="track"/>')
        # The animation alternates direction, so its duration is one crossing: half a round trip.
        crossing = ROUND_TRIP_MIB_PER_SECOND / (FILE_MIB / secs) / 2
        cx = TRACK_X + TRACK_H // 2
        cy = ty + TRACK_H / 2
        out.append(f'<circle cx="{cx}" cy="{cy:.2f}" r="{DOT_R}" class="dot series-{series}" '
                   f'style="animation-duration:{crossing:.3f}s"/>')
        out.append(text(LEFT, f"{ty + 40:.2f}", "muted", 11.5, 500, f"{secs:.3f} s per run"))
    out.append("</svg>")
    return "\n".join(out) + "\n"


for key, (title, rows) in CHARTS.items():
    (OUT / f"benchmark-{key}.svg").write_text(build(title, rows))
    print("wrote", OUT / f"benchmark-{key}.svg")
