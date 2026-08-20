# XOR the two GDS streamouts (magic vs klayout) of a LibreLane final/
# layer by layer - the flow's own merge-sanity judge, run offline.
import sys

import klayout.db as db

a_path, b_path, top = sys.argv[1], sys.argv[2], sys.argv[3]

la, lb = db.Layout(), db.Layout()
la.read(a_path)
lb.read(b_path)
ta = la.top_cell() if top == "-" else la.cell(top)
tb = lb.top_cell() if top == "-" else lb.cell(top)

layers = {}
for lay, info in [(la, "a"), (lb, "b")]:
    for li in lay.layer_infos():
        layers.setdefault((li.layer, li.datatype), set()).add(info)

total = 0
rows = []
for (l, d), sides in sorted(layers.items()):
    ra = db.Region(ta.begin_shapes_rec(la.layer(db.LayerInfo(l, d)))) \
        if "a" in sides else db.Region()
    rb = db.Region(tb.begin_shapes_rec(lb.layer(db.LayerInfo(l, d)))) \
        if "b" in sides else db.Region()
    ra.merged_semantics = True
    rb.merged_semantics = True
    diff = ra ^ rb
    n = diff.count()
    total += n
    if n:
        rows.append((l, d, n, ra.count(), rb.count()))

for l, d, n, ca, cb in rows:
    print(f"layer {l}/{d}: XOR {n} shapes (a {ca} vs b {cb})")
print(f"XOR TOTAL: {total} shapes across {len(layers)} layers")
