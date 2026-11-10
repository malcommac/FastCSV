#!/usr/bin/env python3
"""Draws the README benchmark charts from results.json, in light and dark variants.

Usage: python3 charts.py   (writes charts/*.svg next to this script)
"""
import json, pathlib
from html import escape

root = pathlib.Path(__file__).parent
report = json.loads((root / "results.json").read_text())

THEMES = {
    "light": {"primary": "#0b0b0b", "secondary": "#52514e", "muted": "#6b6a66",
              "highlight": "#2a78d6", "other": "#898781"},
    "dark": {"primary": "#f0efec", "secondary": "#c3c2b7", "muted": "#a3a29b",
             "highlight": "#3987e5", "other": "#898781"},
}
FONT = 'system-ui, -apple-system, "Segoe UI", Helvetica, Arial, sans-serif'
WIDTH, LABEL_X, BAR_X, BAR_MAX = 760, 176, 188, 380
ROW, BAR_H, TITLE_H = 28, 16, 50


def bar(x, y, w, h, r=4):
    """A bar anchored on the left, rounded only at its data end."""
    w = max(w, 2)
    r = min(r, w / 2, h / 2)
    return (f"M{x},{y} h{w - r:.2f} a{r},{r} 0 0 1 {r},{r} v{h - 2 * r} "
            f"a{r},{r} 0 0 1 {-r},{r} h{-(w - r):.2f} z")


def panel(rows, title, subtitle, value, theme, top):
    """Rows sorted fastest first, FastCSV highlighted, every bar labeled directly."""
    colors = THEMES[theme]
    peak = max(v for _, v, _ in rows)
    out = [
        f'<text x="0" y="{top + 16}" font-size="15" font-weight="600" fill="{colors["primary"]}">{escape(title)}</text>',
        f'<text x="0" y="{top + 35}" font-size="12.5" fill="{colors["muted"]}">{escape(subtitle)}</text>',
    ]
    for i, (name, v, label) in enumerate(rows):
        y = top + TITLE_H + i * ROW
        mine = name == "FastCSV"
        weight = ' font-weight="600"' if mine else ""
        ink = colors["primary"] if mine else colors["secondary"]
        fill = colors["highlight"] if mine else colors["other"]
        w = BAR_MAX * v / peak
        out.append(f'<text x="{LABEL_X}" y="{y + 12.5}" font-size="13" text-anchor="end" fill="{ink}"{weight}>{escape(name)}</text>')
        out.append(f'<path d="{bar(BAR_X, y, w, BAR_H)}" fill="{fill}"><title>{escape(name)}: {escape(label)}</title></path>')
        out.append(f'<text x="{BAR_X + max(w, 2) + 8:.2f}" y="{y + 12.5}" font-size="13" fill="{ink}"{weight}>{escape(label)}</text>')
    return out, TITLE_H + len(rows) * ROW


def svg(panels, theme, description):
    body, top = [], 0
    for rows, title, subtitle, value in panels:
        part, height = panel(rows, title, subtitle, value, theme, top)
        body += part
        top += height + 22
    height = top - 22 + 4
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{height}" '
            f'viewBox="0 0 {WIDTH} {height}" role="img" font-family=\'{FONT}\'>\n'
            f'<title>{escape(description)}</title>\n' + "\n".join(body) + "\n</svg>\n")


def time_rows(entry):
    fastest = next(r["seconds"] for r in entry["results"] if r["parser"] == "FastCSV")
    rows = []
    for r in sorted(entry["results"], key=lambda r: r["seconds"]):
        ratio = "" if r["parser"] == "FastCSV" else f'  ·  {r["seconds"] / fastest:.1f}× slower'
        rows.append((r["parser"], r["seconds"], f'{r["seconds"]:.3f} s{ratio}'))
    return rows


def memory_rows(entry):
    rows = sorted(entry["results"], key=lambda r: (r["memory_mb"], r["parser"] != "FastCSV"))
    return [(r["parser"], r["memory_mb"], f'{r["memory_mb"]:,} MB') for r in rows]


stop_times, trips = report["files"]
charts = {
    "time": ([
        (time_rows(stop_times), "stop_times.txt",
         f'{stop_times["size_mb"]} MB, 5 million rows, no quotes  ·  time to read every field, lower is better', "s"),
        (time_rows(trips), "trips.txt",
         f'{trips["size_mb"]} MB, 165,520 rows, with quoted fields  ·  time to read every field, lower is better', "s"),
    ], "Time to read every field as a String, per parser"),
    "memory": ([
        (memory_rows(stop_times), "Peak memory reading stop_times.txt",
         "Peak resident size, lower is better", "MB"),
    ], "Peak memory while reading stop_times.txt, per parser"),
}

out_dir = root / "charts"
out_dir.mkdir(exist_ok=True)
for name, (panels, description) in charts.items():
    for theme in THEMES:
        (out_dir / f"{name}-{theme}.svg").write_text(svg(panels, theme, description))
        print(out_dir / f"{name}-{theme}.svg")
