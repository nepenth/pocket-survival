#!/usr/bin/env python3
"""Turns an OSM extract of roads and paths (OPL text from `osmium cat -f opl`) into routing.bin,
the routing graph Pocket Mirror loads with mmap (PocketMirror/Routing/RouteGraph.swift).

Ways are split at junctions (nodes shared by two ways, plus way ends); each piece becomes one
edge with its length, road class, name, car/foot access, car speed and simplified shape.
Junctions are sorted into a 0.01-degree grid so the phone can find the nearest one quickly.

File layout (little endian; every section starts on a 4-byte boundary):
  header   'PMRT', u32 version, u32 nodes, u32 edges, u32 geomPoints, u32 names, u32 nameBytes,
           u32 rows, u32 cols, f64 minLat, f64 minLon, f64 cellDeg
  nodes    i32 lat[N], i32 lon[N]                       (degrees * 1e7)
  adjacency u32 first[N+1], u32 adj[2E]                 (edge id; bit 31 set = walking it v -> u)
  edges    u32 u[E], u32 v[E], f32 meters[E], u32 name[E] (0xFFFFFFFF = none),
           u32 geomStart[E], u16 geomCount[E], u8 class[E], u8 flags[E], u8 kmh[E]
  geometry i32 lat[G], i32 lon[G]                      (inner points of each edge, u -> v order)
  flags: 1 car u->v, 2 car v->u, 4 foot, 8 part of a large connected network (>= 1000 edges)
  classes: 0 motorway .. 7 service, 8 track, 9 path, 10 footway, 11 steps, 12 ramp (any *_link)
  names    u32 offset[names+1], utf8 bytes
  grid     u32 cellStart[rows*cols+1]                  (nodes are sorted by cell)
"""
import array, math, re, struct, sys
import numpy as np
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components

src, out = sys.argv[1], sys.argv[2]

# class ids (the app's turn list and costs use these)
CLASS = {
    "motorway": 0, "motorway_link": 0, "trunk": 1, "trunk_link": 1, "primary": 2, "primary_link": 2,
    "secondary": 3, "secondary_link": 3, "tertiary": 4, "tertiary_link": 4, "unclassified": 5, "road": 5,
    "residential": 6, "living_street": 6, "service": 7, "track": 8, "path": 9, "bridleway": 9,
    "footway": 10, "pedestrian": 10, "cycleway": 10, "steps": 11,
}
KMH = {0: 100, 1: 80, 2: 65, 3: 55, 4: 50, 5: 40, 6: 35, 7: 20, 12: 50}
CAR_FWD, CAR_BACK, FOOT, MAJOR = 1, 2, 4, 8
RAMP = 12
NO = {"no", "private"}
YES = {"yes", "designated", "permissive", "destination"}

def unescape(s):
    return re.sub(r"%([0-9a-fA-F]+)%", lambda m: chr(int(m.group(1), 16)), s)

def tags_of(field):
    t = {}
    if field:
        for kv in field.split(","):
            k, _, v = kv.partition("=")
            t[unescape(k)] = unescape(v)
    return t

def speed(t, cls):
    m = re.match(r"(\d+)\s*(mph)?", t.get("maxspeed", ""))
    if m:
        v = int(m.group(1)) * (1.609 if m.group(2) else 1)
        return max(10, min(120, int(v * 0.9)))
    return KMH.get(cls, 0)

def access(t, cls):
    a = t.get("access", "")
    car = cls <= 7 and a not in NO and t.get("motor_vehicle") not in NO and t.get("motorcar") not in NO
    if cls == 7 and a == "" and t.get("service") in ("emergency_access",):
        car = False
    foot_tag = t.get("foot", "")
    foot = cls >= 1 and foot_tag not in NO and (a not in NO or foot_tag in YES)
    if cls == 1 and foot_tag == "":       # US trunks are often expressways: allowed, but costed high
        foot = True
    flags = FOOT if foot else 0
    if car:
        ow = t.get("oneway", "")
        if ow in ("yes", "1", "true") or t.get("junction") in ("roundabout", "circular") or (cls == 0 and ow != "no"):
            flags |= CAR_FWD
        elif ow == "-1":
            flags |= CAR_BACK
        else:
            flags |= CAR_FWD | CAR_BACK
    return flags

# --- read nodes and ways -------------------------------------------------------------------
node_id, node_lat, node_lon = array.array("q"), array.array("i"), array.array("i")
ways = []          # (refs list of OSM ids, cls, flags, kmh, name)
with open(src, encoding="utf-8") as f:
    for line in f:
        if line[0] == "n":
            x = y = None
            for p in line.split(" "):
                if p[0] == "x": x = p[1:]
                elif p[0] == "y": y = p[1:].strip()
            if x and y:
                node_id.append(int(line[1:line.index(" ")]))
                node_lat.append(int(round(float(y) * 1e7)))
                node_lon.append(int(round(float(x) * 1e7)))
        elif line[0] == "w":
            tags = refs = ""
            for p in line.rstrip("\n").split(" "):
                if p[:1] == "T": tags = p[1:]
                elif p[:1] == "N": refs = p[1:]
            t = tags_of(tags)
            cls = CLASS.get(t.get("highway"))
            if cls is None or not refs:
                continue
            flags = access(t, cls)
            if not flags:
                continue
            if t.get("highway", "").endswith("_link"):
                cls = RAMP
            ids = [int(r[1:]) for r in refs.split(",")]
            if len(ids) < 2:
                continue
            name = t.get("name") or t.get("ref") or ""
            ways.append((ids, cls, flags, speed(t, cls), name))
print(f"{len(node_id):,} nodes, {len(ways):,} ways read", flush=True)

ids = np.frombuffer(node_id, dtype=np.int64)
order = np.argsort(ids, kind="stable")
ids_sorted = ids[order]
lat_all = np.frombuffer(node_lat, dtype=np.int32)[order]
lon_all = np.frombuffer(node_lon, dtype=np.int32)[order]

def index_of(refs):
    a = np.searchsorted(ids_sorted, np.asarray(refs, dtype=np.int64))
    a[a >= len(ids_sorted)] = 0
    ok = ids_sorted[a] == refs
    return a, ok

# junctions: used by more than one way position, or the end of a way
use = np.zeros(len(ids_sorted), dtype=np.int32)
way_idx = []
for refs, *_ in ways:
    a, ok = index_of(refs)
    a = a[ok]
    way_idx.append(a)
    if len(a) >= 2:
        np.add.at(use, a, 1)
        use[a[0]] += 1
        use[a[-1]] += 1
junction = use >= 2
print(f"{int(junction.sum()):,} junctions", flush=True)

R = 6371008.8
def seg_lengths(la, lo):
    p1 = np.radians(la[:-1] / 1e7); p2 = np.radians(la[1:] / 1e7)
    dl = np.radians((lo[1:] - lo[:-1]) / 1e7)
    a = np.sin((p2 - p1) / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(dl / 2) ** 2
    return 2 * R * np.arcsin(np.sqrt(np.minimum(a, 1)))

names, name_ids = [], {}
def name_id(n):
    if not n: return 0xFFFFFFFF
    i = name_ids.get(n)
    if i is None:
        i = name_ids[n] = len(names); names.append(n)
    return i

E_u, E_v, E_len, E_name = array.array("I"), array.array("I"), array.array("f"), array.array("I")
E_gs, E_gc, E_cls, E_flags, E_kmh = array.array("I"), array.array("H"), array.array("B"), array.array("B"), array.array("B")
G_lat, G_lon = array.array("i"), array.array("i")
THIN = 8.0   # metres: inner points closer than this to the last kept one are dropped

for (refs, cls, flags, kmh, name), a in zip(ways, way_idx):
    if len(a) < 2:
        continue
    la, lo = lat_all[a], lon_all[a]
    seg = seg_lengths(la, lo)
    nid = name_id(name)
    start = 0
    for i in range(1, len(a)):
        if not junction[a[i]] and i != len(a) - 1:
            continue
        if a[start] != a[i]:
            gs = len(G_lat); kept = 0; acc = 0.0
            for j in range(start + 1, i):
                acc += seg[j - 1]
                if acc >= THIN and kept < 65535:
                    G_lat.append(int(la[j])); G_lon.append(int(lo[j])); kept += 1; acc = 0.0
            E_u.append(int(a[start])); E_v.append(int(a[i]))
            E_len.append(float(seg[start:i].sum())); E_name.append(nid)
            E_gs.append(gs); E_gc.append(kept); E_cls.append(cls); E_flags.append(flags); E_kmh.append(kmh)
        start = i
print(f"{len(E_u):,} edges, {len(G_lat):,} shape points, {len(names):,} names", flush=True)

# --- renumber junctions, sorted by grid cell ------------------------------------------------
u = np.frombuffer(E_u, dtype=np.uint32).astype(np.int64)
v = np.frombuffer(E_v, dtype=np.uint32).astype(np.int64)
used = np.unique(np.concatenate([u, v]))
CELL = 0.01
jl, jo = lat_all[used], lon_all[used]
min_lat, min_lon = jl.min() / 1e7, jo.min() / 1e7
rows = int((jl.max() / 1e7 - min_lat) / CELL) + 1
cols = int((jo.max() / 1e7 - min_lon) / CELL) + 1
cell = ((jl / 1e7 - min_lat) / CELL).astype(np.int64) * cols + ((jo / 1e7 - min_lon) / CELL).astype(np.int64)
perm = np.argsort(cell, kind="stable")
used, jl, jo, cell = used[perm], jl[perm], jo[perm], cell[perm]
new_of = np.full(len(lat_all), -1, dtype=np.int64)
new_of[used] = np.arange(len(used))
u2, v2 = new_of[u].astype(np.uint32), new_of[v].astype(np.uint32)
N, E = len(used), len(u2)

# Pieces cut off from the rest (a park's paths once the sidewalks are gone, a parking lot) are
# flagged so the app can snap to the main network when a search from them finds nothing.
_, comp = connected_components(coo_matrix((np.ones(E), (u2, v2)), shape=(N, N)), directed=False)
comp_edges = np.bincount(comp[u2], minlength=comp.max() + 1)
major = comp_edges[comp[u2]] >= 1000
flags_arr = np.frombuffer(E_flags, dtype=np.uint8).copy()
flags_arr[major] |= MAJOR
E_flags = flags_arr
print(f"{int(major.sum()):,} of {E:,} edges in large networks", flush=True)
cell_start = np.searchsorted(cell, np.arange(rows * cols + 1)).astype(np.uint32)

# adjacency (CSR): each edge listed at u (forward) and at v (bit 31: reverse)
heads = np.concatenate([u2, v2]).astype(np.int64)
vals = np.concatenate([np.arange(E, dtype=np.uint32), np.arange(E, dtype=np.uint32) | np.uint32(0x80000000)])
o = np.argsort(heads, kind="stable")
adj = vals[o]
first = np.searchsorted(heads[o], np.arange(N + 1)).astype(np.uint32)

name_bytes = [n.encode("utf-8") for n in names]
name_off = np.zeros(len(names) + 1, dtype=np.uint32)
name_off[1:] = np.cumsum([len(b) for b in name_bytes])

def pad(b):
    return b + b"\0" * (-len(b) % 4)

with open(out, "wb") as f:
    f.write(struct.pack("<4s8I3d", b"PMRT", 1, N, E, len(G_lat), len(names), int(name_off[-1]), rows, cols,
                        min_lat, min_lon, CELL))
    for arr in (jl.astype(np.int32), jo.astype(np.int32), first, adj, u2, v2,
                np.frombuffer(E_len, dtype=np.float32), np.frombuffer(E_name, dtype=np.uint32),
                np.frombuffer(E_gs, dtype=np.uint32), np.frombuffer(E_gc, dtype=np.uint16),
                np.frombuffer(E_cls, dtype=np.uint8), E_flags,
                np.frombuffer(E_kmh, dtype=np.uint8),
                np.frombuffer(G_lat, dtype=np.int32), np.frombuffer(G_lon, dtype=np.int32), name_off):
        f.write(pad(np.ascontiguousarray(arr).tobytes()))
    f.write(pad(b"".join(name_bytes)))
    f.write(pad(cell_start.tobytes()))
print(f"{N:,} junctions, {E:,} edges, grid {rows}x{cols} -> {out}")
