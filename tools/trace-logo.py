"""Trace the lime mark out of the artwork into smooth contours.

Boundary following on the binary mask (exact, no stitching to get wrong), then Chaikin corner-cutting
to take the pixel staircase off the curves, then Ramer-Douglas-Peucker to drop the points that carry
no shape. Holes are found by flood-filling the background from the border: whatever background is
left is enclosed, and that is the keyhole.
"""
import json, sys
from collections import deque
from PIL import Image

SRC, EPS, OUT = "brand/logo-source.png", float(sys.argv[1]), sys.argv[2]
im = Image.open(SRC).convert("RGB"); W, H = im.size; px = im.load()
ink = [[False]*W for _ in range(H)]
for y in range(H):
    row = ink[y]
    for x in range(W):
        r, g, b = px[x, y]
        row[x] = g > 150 and r > 110 and (g - b) > 55

# --- outside vs enclosed background -----------------------------------------
outside = [[False]*W for _ in range(H)]
q = deque()
for x in range(W):
    for y in (0, H-1):
        if not ink[y][x] and not outside[y][x]: outside[y][x] = True; q.append((x, y))
for y in range(H):
    for x in (0, W-1):
        if not ink[y][x] and not outside[y][x]: outside[y][x] = True; q.append((x, y))
while q:
    x, y = q.popleft()
    for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)):
        nx, ny = x+dx, y+dy
        if 0 <= nx < W and 0 <= ny < H and not ink[ny][nx] and not outside[ny][nx]:
            outside[ny][nx] = True; q.append((nx, ny))

def region_mask(kind):
    if kind == "ink": return ink
    return [[(not ink[y][x]) and (not outside[y][x]) for x in range(W)] for y in range(H)]

def components(mask):
    seen = [[False]*W for _ in range(H)]; out = []
    for y in range(H):
        for x in range(W):
            if mask[y][x] and not seen[y][x]:
                comp = []; s = [(x, y)]; seen[y][x] = True
                while s:
                    cx, cy = s.pop(); comp.append((cx, cy))
                    for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)):
                        nx, ny = cx+dx, cy+dy
                        if 0 <= nx < W and 0 <= ny < H and mask[ny][nx] and not seen[ny][nx]:
                            seen[ny][nx] = True; s.append((nx, ny))
                if len(comp) > 200: out.append(comp)
    return out

# --- Moore-neighbour boundary following, on the CORNER lattice ---------------
def trace(mask, comp):
    start = min(comp, key=lambda p: (p[1], p[0]))            # topmost-leftmost
    def solid(x, y): return 0 <= x < W and 0 <= y < H and mask[y][x]
    # Walk the crack boundary: state = (corner point, direction). Directions: 0=E,1=S,2=W,3=N.
    sx, sy = start; path = [(sx, sy)]; x, y, d = sx, sy, 0
    for _ in range(4 * len(comp) + 1000):
        if d == 0:   left, right = solid(x, y-1), solid(x, y)
        elif d == 1: left, right = solid(x, y),   solid(x-1, y)
        elif d == 2: left, right = solid(x-1, y), solid(x-1, y-1)
        else:        left, right = solid(x-1, y-1), solid(x, y-1)
        if left:  d = (d - 1) % 4
        elif not right: d = (d + 1) % 4
        else:
            x, y = (x+1, y) if d == 0 else (x, y+1) if d == 1 else (x-1, y) if d == 2 else (x, y-1)
            path.append((x, y))
            if (x, y) == (sx, sy) and len(path) > 4: break
    return path

def chaikin(pts, passes=3):
    for _ in range(passes):
        out = []
        n = len(pts)
        for i in range(n):
            p, q2 = pts[i], pts[(i+1) % n]
            out.append((p[0]*0.75 + q2[0]*0.25, p[1]*0.75 + q2[1]*0.25))
            out.append((p[0]*0.25 + q2[0]*0.75, p[1]*0.25 + q2[1]*0.75))
        pts = out
    return pts

sys.setrecursionlimit(20000)
def rdp(pts, eps):
    if len(pts) < 3: return pts
    a, b = pts[0], pts[-1]
    dx, dy = b[0]-a[0], b[1]-a[1]
    norm = (dx*dx + dy*dy) ** 0.5 or 1e-9
    dmax, idx = 0.0, 0
    for i in range(1, len(pts)-1):
        dist = abs(dy*(pts[i][0]-a[0]) - dx*(pts[i][1]-a[1])) / norm
        if dist > dmax: dmax, idx = dist, i
    if dmax > eps: return rdp(pts[:idx+1], eps)[:-1] + rdp(pts[idx:], eps)
    return [a, b]

contours = []
for kind in ("ink", "hole"):
    mask = region_mask(kind)
    for comp in sorted(components(mask), key=len, reverse=True)[:3]:
        raw = trace(mask, comp)
        smooth = chaikin(raw)
        # RDP on a CLOSED ring collapses to two points: first and last coincide, so the chord has no
        # length and every deviation measures zero against it. Cut the ring at its two extremes and
        # simplify each arc as an open polyline.
        far = max(range(len(smooth)),
                  key=lambda i: (smooth[i][0]-smooth[0][0])**2 + (smooth[i][1]-smooth[0][1])**2)
        simple = rdp(smooth[:far+1], EPS)[:-1] + rdp(smooth[far:] + [smooth[0]], EPS)[:-1]
        contours.append({"kind": kind, "points": simple})
        print(f"{kind}: {len(comp)}px -> {len(raw)} boundary -> {len(simple)} points", file=sys.stderr)
json.dump(contours, open(OUT, "w"))
