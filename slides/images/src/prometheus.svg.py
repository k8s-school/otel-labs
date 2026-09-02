#!/usr/bin/env python3
"""Génère images/prometheus.svg — le modèle pull de Prometheus.

Dagre (mermaid) ne sait pas placer trois groupes autour d'un même nœud :
les cibles à gauche, les règles au-dessus, les sorties à droite. D'où ce SVG
écrit à la main, dans la palette des schémas mermaid du cours.
"""
import io

FILL, STROKE = "#eaf1fd", "#4285f4"
ACCENT, LINE = "#1a73e8", "#1a73e8"
TEXT, MUTED = "#333b45", "#e0e0e0"
FONT = "Segoe UI, Roboto, Helvetica, Arial, sans-serif"

out = []
add = out.append

def box(x, y, w, h, lines, fill=FILL, stroke=STROKE, color=TEXT):
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" '
        f'fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>')
    cx, n = x + w / 2, len(lines)
    y0 = y + h / 2 - (n - 1) * 13 + 8
    for i, (txt, style) in enumerate(lines):
        extra = {"b": ' font-weight="700"', "i": ' font-style="italic"',
                 "": ''}[style]
        add(f'<text x="{cx}" y="{y0 + i * 26}" text-anchor="middle" '
            f'font-size="21" fill="{color}"{extra}>{txt}</text>')

def frame(x, y, w, h, title):
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" '
        f'fill="none" stroke="{MUTED}" stroke-width="1.5"/>')
    add(f'<text x="{x + w / 2}" y="{y + 26}" text-anchor="middle" '
        f'font-size="21" fill="{TEXT}">{title}</text>')

def arrow(x1, y1, x2, y2, label=None, lx=None, ly=None):
    add(f'<path d="M {x1} {y1} L {x2} {y2}" stroke="{LINE}" stroke-width="2" '
        f'fill="none" marker-end="url(#head)"/>')
    if label:
        add(f'<text x="{lx}" y="{ly}" text-anchor="middle" font-size="19" '
            f'fill="{TEXT}">{label}</text>')

add('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1240 495" '
    f'width="100%" style="background-color:transparent" font-family="{FONT}">')
add(f'<defs><marker id="head" viewBox="0 0 10 10" refX="9" refY="5" '
    f'markerWidth="7" markerHeight="7" orient="auto">'
    f'<path d="M 0 0 L 10 5 L 0 10 z" fill="{LINE}"/></marker></defs>')

# Cibles (gauche)
frame(30, 105, 265, 370, "Cibles")
for i, name in enumerate(("service", "service", "node exporter")):
    box(55, 150 + i * 105, 215, 72, [(name, ""), ("/metrics", "b")])

# Règles (au-dessus)
box(375, 30, 300, 76, [("règles d'alerte", ""),
                       ("YAML, évaluées ~1 min", "i")])

# Prometheus (centre)
box(390, 245, 270, 104,
    [("Prometheus", "b"), ("base de séries", ""), ("+ PromQL", "")],
    fill=STROKE, stroke=ACCENT, color="#ffffff")

# Sorties (droite)
frame(745, 105, 310, 370, "Sorties")
box(770, 150, 260, 72, [("Web UI · Grafana", "")])
box(770, 300, 260, 104, [("Alertmanager", "b"), ("déduplique · groupe", "i"),
                         ("· route", "i")])
box(1090, 316, 130, 72, [("PagerDuty", ""), ("mail · Slack", "")])

# Flèches : le pull part de Prometheus vers les cibles
arrow(390, 275, 280, 195, "scrape · 15 s", 375, 175)
arrow(390, 297, 280, 297)
arrow(390, 319, 280, 400)
arrow(525, 106, 525, 240)
arrow(660, 275, 762, 195)
arrow(660, 320, 762, 350)
arrow(1032, 352, 1082, 352)
add('</svg>')

io.open("../images/prometheus.svg", "w", encoding="utf-8").write("\n".join(out))
