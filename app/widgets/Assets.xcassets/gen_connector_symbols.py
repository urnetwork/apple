#!/usr/bin/env python3
"""
Generate custom SF Symbol templates for the URnetwork connector mark.

The source artwork (control/Assets.xcassets/QuickOn.imageset/QuickOn.svg) is a
128x128 square whose corners are replaced by a staircase of five quarter-circle
arcs of radius 8, alternating convex/concave. The outline variant (QuickOff)
was a hairline stroke, which SF Symbols cannot use: symbols must be filled
paths. So this script rebuilds the mark analytically and offsets it inward to
produce true outline rings per weight (lines shift by w, convex arcs shrink to
8-w, concave arcs grow to 8+w; tangency is preserved).

Output: two symbol template SVGs (Template v.6.0, i.e. SF Symbols 6 / Xcode
16) with the interpolation sources Ultralight-S, Regular-S, Black-S plus
Regular-M.

The version has to stay at 6.0: CI pins Xcode 16.4, and its actool rejects a
newer template outright -- "Template format 7.0 is newer than the version that
this software supports (6.0)" -- before it reads any of the artwork. The SF
Symbols app on a current machine exports 7.0, so if you re-export from it,
re-apply the 6.0 changes here rather than committing its output.
"""
import math
import os
import sys

K = 0.5522847498  # cubic approximation of a quarter circle
R = 8.0

# Outer contour, counter-clockwise on screen (y down): top edge right->left,
# then top-left corner, left edge, bottom-left, bottom edge, bottom-right,
# right edge, top-right. Each corner is five arcs: (center, start, end, convex).
CORNERS = [
    # top-left: (40,0) -> (0,40)
    [((40, 8), (40, 0), (32, 8), True),
     ((24, 8), (32, 8), (24, 16), False),
     ((24, 24), (24, 16), (16, 24), True),
     ((8, 24), (16, 24), (8, 32), False),
     ((8, 40), (8, 32), (0, 40), True)],
    # bottom-left: (0,88) -> (40,128)
    [((8, 88), (0, 88), (8, 96), True),
     ((8, 104), (8, 96), (16, 104), False),
     ((24, 104), (16, 104), (24, 112), True),
     ((24, 120), (24, 112), (32, 120), False),
     ((40, 120), (32, 120), (40, 128), True)],
    # bottom-right: (88,128) -> (128,88)
    [((88, 120), (88, 128), (96, 120), True),
     ((104, 120), (96, 120), (104, 112), False),
     ((104, 104), (104, 112), (112, 104), True),
     ((120, 104), (112, 104), (120, 96), False),
     ((120, 88), (120, 96), (128, 88), True)],
    # top-right: (128,40) -> (88,0)
    [((120, 40), (128, 40), (120, 32), True),
     ((120, 24), (120, 32), (112, 24), False),
     ((104, 24), (112, 24), (104, 16), True),
     ((104, 8), (104, 16), (96, 8), False),
     ((88, 8), (96, 8), (88, 0), True)],
]


def offset_arc(arc, w):
    (cx, cy), (sx, sy), (ex, ey), convex = arc
    r = R - w if convex else R + w
    if r <= 0.05:
        raise ValueError("inset too large for the convex arcs")
    f = r / R
    return ((cx, cy), (cx + (sx - cx) * f, cy + (sy - cy) * f),
            (cx + (ex - cx) * f, cy + (ey - ey) * f + (ey - cy) * f), convex)


def arc_beziers(center, start, end):
    """Cubic control points for a quarter arc from start to end around center."""
    cx, cy = center
    v0 = (start[0] - cx, start[1] - cy)
    v1 = (end[0] - cx, end[1] - cy)
    r = math.hypot(*v0)
    cross = v0[0] * v1[1] - v0[1] * v1[0]
    if cross > 0:
        t0 = (-v0[1] / r, v0[0] / r)
        t3 = (-v1[1] / r, v1[0] / r)
    else:
        t0 = (v0[1] / r, -v0[0] / r)
        t3 = (v1[1] / r, -v1[0] / r)
    p1 = (start[0] + K * r * t0[0], start[1] + K * r * t0[1])
    p2 = (end[0] - K * r * t3[0], end[1] - K * r * t3[1])
    return p1, p2


def contour(w, reverse):
    """List of ('M'|'L'|'C', points) in 128-space, inset by w."""
    arcs = []
    for corner in CORNERS:
        for arc in corner:
            (cx, cy), (sx, sy), (ex, ey), convex = arc
            r = R - w if convex else R + w
            if r <= 0.05:
                raise ValueError("inset %.2f too large for the convex arcs" % w)
            f = r / R
            s = (cx + (sx - cx) * f, cy + (sy - cy) * f)
            e = (cx + (ex - cx) * f, cy + (ey - cy) * f)
            arcs.append(((cx, cy), s, e))
    if reverse:
        arcs = [(c, e, s) for (c, s, e) in reversed(arcs)]
    cmds = []
    first = arcs[0][1]
    cmds.append(("M", [first]))
    prev_end = first
    for (c, s, e) in arcs:
        if abs(s[0] - prev_end[0]) > 1e-9 or abs(s[1] - prev_end[1]) > 1e-9:
            cmds.append(("L", [s]))
        p1, p2 = arc_beziers(c, s, e)
        cmds.append(("C", [p1, p2, e]))
        prev_end = e
    cmds.append(("Z", []))
    return cmds


def to_d(cmds, scale, ox, oy):
    """Map 128-space to symbol space: x' = ox + x*scale, y' = oy + y*scale."""
    out = []
    for op, pts in cmds:
        if op == "Z":
            out.append("Z")
            continue
        coords = " ".join("%.4f %.4f" % (ox + x * scale, oy + y * scale) for x, y in pts)
        out.append("%s%s" % (op, coords))
    return " ".join(out)


def glyph(size, inset, y_center):
    """Path data for a mark of `size` template units, vertically centered on
    y_center (baseline is y=0, up is negative)."""
    scale = size / 128.0
    ox = 0.0
    oy = y_center - size / 2.0
    d = to_d(contour(0.0, False), scale, ox, oy)
    if inset is not None:
        d += " " + to_d(contour(inset, True), scale, ox, oy)
    return d


# Artboard geometry as exported by the SF Symbols app (viewBox 3300x2200).
# Only the version banner and the v7-only style metadata (see STYLE below)
# were changed to target 6.0; these coordinates are left exactly as exported.
BASELINE = {"S": 696.0, "M": 1126.0, "L": 1556.0}
CAPLINE = {"S": 625.541, "M": 1055.54, "L": 1485.54}
CAP_HEIGHT = BASELINE["M"] - CAPLINE["M"]  # 70.46
COLUMN_X = {"Ultralight": 513.816, "Regular": 1403.95, "Black": 2884.5}
REGULAR_M_X = 1392.45

SIZE_M = 76.0            # a little taller than the cap height, like square.fill
SIZE_S = SIZE_M * 0.8    # the S row is drawn at 0.8x, matching Apple's exports
Y_CENTER = -CAP_HEIGHT / 2.0

# outline thickness per weight in 128-space (must stay below the 8-unit arcs)
INSET = {"Ultralight": 2.2, "Regular": 5.6, "Black": 7.6}

H_REFERENCE = ("M0.7 0L0.7-70.5L11.4-70.5L11.4-40.7L44.8-40.7L44.8-70.5L55.5-70.5L55.5 0"
               "L44.8 0L44.8-31.8L11.4-31.8L11.4 0Z")

# Style block for a 6.0 template. The four -sfsymbols-* properties a v7 export
# writes here are all v7 vocabulary and are omitted: -sfsymbols-motion-group and
# -sfsymbols-draw-reverses-motion-groups configure the SF Symbols 7 Draw
# animation, -sfsymbols-layer-tags is v7's per-layer identity token, and
# -sfsymbols-variable-value-mode selects between color and draw as the thing
# variable value drives, which is only a choice once draw exists. None of the
# four does anything for this symbol -- it is a single static layer with no
# variable value and no Draw animation -- so dropping them costs nothing.
#
# The three layer classes stay, with empty bodies: they are what each path's
# class attribute binds to, naming the monochrome / hierarchical / multicolor
# layers. .defaults goes entirely -- it carried nothing but the two v7
# document-level properties.
STYLE = """.monochrome-0 {}

.multicolor-0:tintColor {}

.hierarchical-0:primary {}

.SFSymbolsPreviewWireframe {fill:none;opacity:1.0;stroke:black;stroke-width:0.5}
"""


def template(name, outline):
    variants = []
    margins = []
    for weight in ("Ultralight", "Regular", "Black"):
        inset = INSET[weight] if outline else None
        x = COLUMN_X[weight]
        variants.append((weight + "-S", x, BASELINE["S"], glyph(SIZE_S, inset, Y_CENTER), SIZE_S))
    variants.append(("Regular-M", REGULAR_M_X, BASELINE["M"],
                     glyph(SIZE_M, INSET["Regular"] if outline else None, Y_CENTER), SIZE_M))
    for vid, x, base, _, width in variants:
        scale = "S" if vid.endswith("-S") else "M"
        y1 = CAPLINE[scale] - 25.0
        y2 = BASELINE[scale] + 24.0
        margins.append(
            '  <line id="left-margin-%s" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" '
            'x1="%.3f" x2="%.3f" y1="%.3f" y2="%.3f"/>' % (vid, x, x, y1, y2))
        margins.append(
            '  <line id="right-margin-%s" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" '
            'x1="%.3f" x2="%.3f" y1="%.3f" y2="%.3f"/>' % (vid, x + width, x + width, y1, y2))

    guides = []
    for scale in ("S", "M", "L"):
        guides.append('  <g id="H-reference" style="fill:#27AAE1;stroke:none;" transform="matrix(1 0 0 1 339 %.3f)">\n'
                      '   <path d="%s"/>\n  </g>' % (BASELINE[scale], H_REFERENCE))
        guides.append('  <line id="Baseline-%s" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" '
                      'x1="263" x2="3036" y1="%.3f" y2="%.3f"/>' % (scale, BASELINE[scale], BASELINE[scale]))
        guides.append('  <line id="Capline-%s" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" '
                      'x1="263" x2="3036" y1="%.3f" y2="%.3f"/>' % (scale, CAPLINE[scale], CAPLINE[scale]))

    symbols = []
    for vid, x, base, d, _ in variants:
        symbols.append('  <g id="%s" transform="matrix(1 0 0 1 %.3f %.3f)">\n'
                       '   <path class="monochrome-0 multicolor-0:tintColor hierarchical-0:primary SFSymbolsPreviewWireframe" d="%s"/>\n'
                       '  </g>' % (vid, x, base, d))

    return """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg
PUBLIC "-//W3C//DTD SVG 1.1//EN"
       "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 3300 2200">
 <!--URnetwork connector mark, generated by gen_symbols.py from QuickOn.svg-->
 <style>%s</style>
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;font-weight:bold;" transform="matrix(1 0 0 1 263 322)">Weight/Scale Variations</text>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:middle;" transform="matrix(1 0 0 1 559.711 322)">Ultralight</text>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:middle;" transform="matrix(1 0 0 1 1449.84 322)">Regular</text>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:middle;" transform="matrix(1 0 0 1 2933.4 322)">Black</text>
  <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.6.0</text>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1951)">Requires Xcode 16 or greater</text>
  <text id="descriptive-name" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1969)">Generated from %s</text>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1987)">Typeset at 100.0 points</text>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 726)">Small</text>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 1156)">Medium</text>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 1586)">Large</text>
 </g>
 <g id="Guides">
%s
%s
 </g>
 <g id="Symbols">
%s
 </g>
</svg>
""" % (STYLE, name, "\n".join(guides), "\n".join(margins), "\n".join(symbols))


CONTENTS = """{
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "symbols" : [
    {
      "filename" : "%s.svg",
      "idiom" : "universal"
    }
  ]
}
"""


def main():
    out_root = sys.argv[1]
    for name, outline in (("ur.symbols.connector.fill", False), ("ur.symbols.connector", True)):
        d = os.path.join(out_root, name + ".symbolset")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, name + ".svg"), "w") as f:
            f.write(template(name, outline))
        with open(os.path.join(d, "Contents.json"), "w") as f:
            f.write(CONTENTS % name)
        print("wrote", d)


if __name__ == "__main__":
    main()
