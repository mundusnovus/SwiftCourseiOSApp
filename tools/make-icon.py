#!/usr/bin/env python3
# Writes the Asteria 26 app icon as an Icon Composer document: aqua steps climbing from a cream zero to a heavy
# Asteria star. Usage: python3 tools/make-icon.py <path/to/AppIcon.icon>
# Soft glows live in the flat background layer; glass layers would draw hard edges round them.
# Preview with: "/Applications/Icon Composer.app/Contents/Executables/ictool" AppIcon.icon --export-image ...
import os, sys, random, math, json
out = sys.argv[1]
A = os.path.join(out, "Assets"); os.makedirs(A, exist_ok=True)
for f in os.listdir(A): os.remove(os.path.join(A, f))
H = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
def w(name, body, defs=""):
    open(os.path.join(A, name), "w").write(H + (f"<defs>{defs}</defs>" if defs else "") + body + "</svg>")

def star(cx, cy, r, pinch=0.36):
    # Asteria four-point star: curved sides pulled toward the centre.
    pts = []
    for k in range(4):
        a = -math.pi/2 + k*math.pi/2
        b = a + math.pi/2
        tip = (cx + r*math.cos(a), cy + r*math.sin(a))
        nxt = (cx + r*math.cos(b), cy + r*math.sin(b))
        m = a + math.pi/4
        ctrl = (cx + r*pinch*0.45*math.cos(m), cy + r*pinch*0.45*math.sin(m))
        pts.append((tip, ctrl, nxt))
    d = f"M{pts[0][0][0]:.1f} {pts[0][0][1]:.1f} " + " ".join(f"Q{c[0]:.1f} {c[1]:.1f} {n[0]:.1f} {n[1]:.1f}" for _, c, n in pts) + " Z"
    return d

SX, SY, SR = 818, 236, 150  # hero star

# 0: flat background with every soft glow (glass layers would draw hard edges round a glow)
w("0_background.svg",
  '<rect width="1024" height="1024" fill="url(#g)"/><rect width="1024" height="1024" fill="url(#a)"/>'
  '<rect width="1024" height="1024" fill="url(#h)"/>'
  f'<circle cx="{SX}" cy="{SY}" r="330" fill="url(#halo)"/>'
  '<ellipse cx="512" cy="900" rx="520" ry="160" fill="url(#floor)"/>',
  '<radialGradient id="g" cx="0.5" cy="0.38" r="0.8"><stop offset="0" stop-color="#0F2C3D"/><stop offset="0.55" stop-color="#081421"/><stop offset="1" stop-color="#04060C"/></radialGradient>'
  '<radialGradient id="a" cx="0.12" cy="0.95" r="0.62"><stop offset="0" stop-color="#00FFD3" stop-opacity="0.28"/><stop offset="1" stop-color="#00FFD3" stop-opacity="0"/></radialGradient>'
  '<radialGradient id="h" cx="0.95" cy="0.05" r="0.5"><stop offset="0" stop-color="#FF0058" stop-opacity="0.22"/><stop offset="1" stop-color="#FF0058" stop-opacity="0"/></radialGradient>'
  '<radialGradient id="halo"><stop offset="0" stop-color="#FF0058" stop-opacity="0.42"/><stop offset="0.45" stop-color="#7A5CFF" stop-opacity="0.20"/><stop offset="1" stop-color="#7A5CFF" stop-opacity="0"/></radialGradient>'
  '<radialGradient id="floor"><stop offset="0" stop-color="#00FFD3" stop-opacity="0.16"/><stop offset="1" stop-color="#00FFD3" stop-opacity="0"/></radialGradient>')

# 1: distant stars
random.seed(26111)
dots = []
for _ in range(26):
    x, y = random.randint(60, 980), random.randint(50, 560)
    if math.hypot(x - SX, y - SY) < SR + 40: continue
    dots.append(f'<circle cx="{x}" cy="{y}" r="{random.uniform(2,5):.1f}" fill="#FFFFFF" opacity="{random.uniform(0.35,0.85):.2f}"/>')
for (x, y, r) in [(150, 150, 26), (420, 110, 18), (960, 640, 18), (110, 470, 16)]:
    dots.append(f'<path d="{star(x, y, r, 0.5)}" fill="#E9FBF7" opacity="0.85"/>')
w("1_stars.svg", "".join(dots))

# 2: the climb, one staircase rising from zero to hero
x0, wd = 70, 214
tops = [800, 670, 540, 410]
r = 30
d = f"M{x0} 1100 V{tops[0]+r} Q{x0} {tops[0]} {x0+r} {tops[0]}"
for i, t in enumerate(tops):
    xe = x0 + (i+1)*wd
    if i < len(tops) - 1:
        d += f" H{xe} V{tops[i+1]+r} Q{xe} {tops[i+1]} {xe+r} {tops[i+1]}"
    else:
        d += f" H{xe-r} Q{xe} {t} {xe} {t+r} V1100 Z"
# the tread highlights: a thin lighter edge on each step
edges = "".join(f'<rect x="{x0 + i*wd + (r if i == 0 else 0) + 6}" y="{t}" width="{wd - 12 - (r if i in (0, 3) else 0)}" height="10" rx="5" fill="#B9FFF2" opacity="0.9"/>' for i, t in enumerate(tops))
w("2_steps.svg", f'<path d="{d}" fill="url(#aq)"/>' + edges,
  '<linearGradient id="aq" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#5CFFE4"/><stop offset="0.4" stop-color="#00FFD3"/><stop offset="1" stop-color="#00A88B"/></linearGradient>')

# 3: the zero, starlight cream ring on the first step
zx, zy = x0 + wd/2, tops[0] - 100
w("3_zero.svg",
  f'<path fill-rule="evenodd" d="M{zx} {zy-70} a62 78 0 1 0 0.1 0 Z M{zx} {zy-50} a34 50 0 1 1 -0.1 0 Z" fill="#E9FBF7"/>')

# 4: the hero, an Asteria star in heavy
w("4_star.svg", f'<path d="{star(SX, SY, SR, 0.34)}" fill="url(#hv)"/>',
  '<linearGradient id="hv" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FF5C93"/><stop offset="1" stop-color="#FF0058"/></linearGradient>')

# 5: trail of dots from zero up to the star, aqua into violet into heavy
trail = []
n = 7
for i in range(n):
    t = (i + 1) / (n + 1)
    # quadratic curve from zero to star
    p0, p1, p2 = (zx + 30, zy - 100), (330, 250), (SX - SR*0.8, SY + 10)
    x = (1-t)**2*p0[0] + 2*(1-t)*t*p1[0] + t*t*p2[0]
    y = (1-t)**2*p0[1] + 2*(1-t)*t*p1[1] + t*t*p2[1]
    trail.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{7 + 6*t:.1f}" fill="url(#ig)"/>')
w("5_trail.svg", "".join(trail),
  '<linearGradient id="ig" gradientUnits="userSpaceOnUse" x1="200" y1="700" x2="620" y2="280"><stop offset="0" stop-color="#00FFD3"/><stop offset="0.5" stop-color="#7A5CFF"/><stop offset="1" stop-color="#FF0058"/></linearGradient>')

icon = {
  "fill": {"automatic-gradient": "extended-srgb:0.01961,0.03137,0.05882,1.00000"},
  "groups": [
    {"layers": [{"image-name": "4_star.svg", "name": "4_star"}],
     "shadow": {"kind": "neutral", "opacity": 0.5}, "translucency": {"enabled": True, "value": 0.1}},
    {"layers": [{"image-name": "5_trail.svg", "name": "5_trail"}, {"image-name": "3_zero.svg", "name": "3_zero"},
                {"image-name": "2_steps.svg", "name": "2_steps"}],
     "shadow": {"kind": "neutral", "opacity": 0.5}, "translucency": {"enabled": True, "value": 0.05}},
    {"layers": [{"image-name": "1_stars.svg", "name": "1_stars"}, {"image-name": "0_background.svg", "name": "0_background"}],
     "shadow": {"kind": "neutral", "opacity": 0.0}, "translucency": {"enabled": False, "value": 0.0}},
  ],
  "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
}
json.dump(icon, open(os.path.join(out, "icon.json"), "w"), indent=2)
