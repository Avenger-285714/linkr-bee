#!/usr/bin/env python3
"""Assert the app shell layout across viewports.

Screenshots from webview_shot are unreliable for anything that changes after
load (WebKit never repaints them in a run-loop-driven process), and even for
static layout the capture can be scaled or taken mid-reflow. The DOM's own
rects are the authority, so this script reads them and checks the invariants
that actually break:

  - the shell fills the viewport
  - the work panel does not overflow to the right
  - the drawer is off screen below 900px, and docked left above it
  - nothing scrolls vertically

Usage:
    # serve web/ first, e.g. python3 -m http.server 8880 --bind 127.0.0.1
    python3 tools/audit_layout.py [url]

Exit code is non-zero when any viewport fails.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE / "webview_shot.swift"
URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8880/index.html"

VIEWPORTS = [
    ("desktop", 1440, 900),
    ("laptop", 1280, 800),
    ("tablet-l", 1024, 768),
    ("tablet-p", 834, 1112),
    ("phone-xl", 430, 932),
    ("phone", 390, 844),
    ("phone-s", 375, 667),
    ("landscape", 844, 390),
]

# The tool must talk to localhost directly; the agent environment injects a
# proxy that would answer 502 for 127.0.0.1.
ENV = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}


def rect(spec):
    size, origin = spec.split("@")
    w, h = size.split("x")
    x, y = origin.split(",")
    return int(w), int(h), int(x), int(y)


def measure(name, w, h):
    out = subprocess.run(
        ["swift", str(TOOL), f"{URL}?audit={name}", f"/tmp/audit-{name}.png",
         str(w), str(h), "dark", "closed"],
        capture_output=True, text=True, env=ENV, timeout=90,
    ).stdout
    line = next((l for l in out.splitlines() if l.startswith("layout:")), None)
    if not line:
        return None
    return json.loads(line[len("layout: "):])


def audit(d):
    vw = d["vw"]
    sw, sh, _, _ = rect(d["shell"])
    ww, _, wx, _ = rect(d["work"])
    cw, _, cx, _ = rect(d["ctl"])
    pad = float(d["padR"].replace("px", ""))

    checks = [
        ("shell==viewport", sw == vw and sh == d["vh"], f"{sw}x{sh} vs {vw}x{d['vh']}"),
        ("work fits", wx + ww <= vw - pad + 1, f"right={wx + ww} limit={vw - pad:.0f}"),
    ]
    if vw <= 900:
        checks.append(("drawer off screen",
                       cx + cw <= 0 or d["ctlVis"] == "hidden",
                       f"{cx}+{cw} vis={d['ctlVis']}"))
    else:
        checks.append(("drawer docked",
                       cx >= 0 and cx + cw <= wx + 1,
                       f"{cx}+{cw} work@{wx}"))
    checks.append(("no vscroll", d["bodyH"] <= d["vh"] + 1, f"{d['bodyH']}/{d['vh']}"))
    return checks


def main():
    failures = []
    print(f"{'viewport':12} {'size':11} {'':6} detail")
    for name, w, h in VIEWPORTS:
        d = measure(name, w, h)
        if d is None:
            failures.append(name)
            print(f"{name:12} {w}x{h:<7} FAIL   no layout output")
            continue
        checks = audit(d)
        bad = [c for c in checks if not c[1]]
        detail = "; ".join(f"{c[0]}: {c[2]}" for c in bad) or "-"
        print(f"{name:12} {w}x{h:<7} {'FAIL' if bad else 'PASS':6} {detail}")
        if bad:
            failures.append(name)

    print()
    if failures:
        print("FAILING:", ", ".join(failures))
        return 1
    print("ALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
