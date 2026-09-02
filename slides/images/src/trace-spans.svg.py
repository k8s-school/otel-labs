#!/usr/bin/env python3
"""Génère images/trace-spans.svg — une trace, c'est des spans dans le temps.

Deux règles que le dessin doit respecter :
  - un span enfant tient dans les bornes de son parent (il commence après et
    finit avant) ;
  - deux frères séquentiels ne se recouvrent pas — ils ne se recouvriraient
    que s'ils étaient exécutés en parallèle.
Les opérations sont celles de la démo, pour que le schéma se superpose à la
capture Jaeger du slide suivant.
"""
import io

TEXT, MUTED = "#333b45", "#9aa0a6"
FONT = "Segoe UI, Roboto, Helvetica, Arial, sans-serif"

# (label, début, fin, index du parent, fond, couleur du texte)
SPANS = [
    ("frontend · HTTP POST",  250, 1180, None, "#1a73e8", "#ffffff"),
    ("checkout · PlaceOrder", 290, 1130, 0,    "#4285f4", "#ffffff"),
    ("cart · GetCart",        325,  560, 1,    "#6ba3f7", "#ffffff"),
    ("catalog · GetProduct",  600,  835, 1,    "#8db8f9", TEXT),
    ("currency · Convert",    875, 1090, 1,    "#b3d0fb", TEXT),
]
TOP, H, GAP = 78, 46, 14
LEFT, RIGHT = 250, 1180

def top(i):
    return TOP + i * (H + GAP)

o = []
a = o.append
a('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1240 470" width="100%" '
  f'style="background-color:transparent" font-family="{FONT}">')
a(f'<defs><marker id="t" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
  f'markerHeight="7" orient="auto"><path d="M 0 0 L 10 5 L 0 10 z" '
  f'fill="{MUTED}"/></marker></defs>')

# axe du temps
a(f'<path d="M {LEFT} 40 L {RIGHT} 40" stroke="{MUTED}" stroke-width="2" '
  f'stroke-dasharray="8 6" marker-end="url(#t)"/>')
a(f'<text x="{(LEFT + RIGHT) / 2}" y="30" text-anchor="middle" font-size="21" '
  f'fill="{MUTED}">temps</text>')

# rattachement à l'appelant : trait vertical au début de l'enfant
for i, (_, x, _, parent, _, _) in enumerate(SPANS):
    if parent is not None:
        a(f'<path d="M {x} {top(parent) + H} L {x} {top(i)}" stroke="{MUTED}" '
          f'stroke-width="1.5" stroke-dasharray="4 4"/>')

# les spans
for i, (label, x, end, _, fill, color) in enumerate(SPANS):
    y = top(i)
    a(f'<rect x="{x}" y="{y}" width="{end - x}" height="{H}" rx="5" fill="{fill}"/>')
    a(f'<text x="{x + 16}" y="{y + 30}" font-size="21" fill="{color}">{label}</text>')

bottom = top(len(SPANS) - 1) + H

# accolade « Trace » à gauche
a(f'<path d="M 218 {TOP} L 205 {TOP} L 205 {bottom} L 218 {bottom}" '
  f'fill="none" stroke="{TEXT}" stroke-width="2"/>')
a(f'<text x="185" y="{(TOP + bottom) / 2 + 2}" text-anchor="end" font-size="24" '
  f'font-weight="700" fill="{TEXT}">Trace</text>')
a(f'<text x="185" y="{(TOP + bottom) / 2 + 30}" text-anchor="end" font-size="19" '
  f'fill="{MUTED}">un même trace_id</text>')

# accolade « Spans » en bas
yb = bottom + 26
a(f'<path d="M {LEFT} {yb - 12} L {LEFT} {yb} L {RIGHT} {yb} L {RIGHT} {yb - 12}" '
  f'fill="none" stroke="{TEXT}" stroke-width="2"/>')
a(f'<text x="{(LEFT + RIGHT) / 2}" y="{yb + 32}" text-anchor="middle" '
  f'font-size="24" font-weight="700" fill="{TEXT}">Spans</text>')
a(f'<text x="{(LEFT + RIGHT) / 2}" y="{yb + 58}" text-anchor="middle" '
  f'font-size="19" fill="{MUTED}">chacun : un parent, un début, une durée</text>')
a('</svg>')

io.open("../images/trace-spans.svg", "w", encoding="utf-8").write("\n".join(o))
