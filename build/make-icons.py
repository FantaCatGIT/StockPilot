#!/usr/bin/env python3
"""Draws the StockPilot icon (white plane on a blue background) and writes every size/format the builds use.
usage: make-icons.py <project root>   -> build/icon.png, build/icon.ico, ui/logo.png, logo/*.png, logo/logo.ico, logo/logo.icns
Needs Pillow."""
import math, os, sys
from PIL import Image, ImageDraw

S = 2048  # drawing size (downscaled for smooth edges)


def plane_points():
    """Top-down airliner pointing up, centred on (0,0), roughly 1000 units long."""
    body = []
    # nose (half ellipse) + straight body + rounded tail
    for i in range(0, 181, 6):
        a = math.radians(180 + i)
        body.append((56 * math.cos(a), -330 + 130 * math.sin(a)))
    body += [(56, 320), (34, 405), (-34, 405), (-56, 320)]
    wing_r = [(50, -80), (450, 115), (450, 180), (50, 55)]
    tail_r = [(45, 250), (195, 330), (195, 380), (40, 345)]
    mirror = lambda pts: [(-x, y) for x, y in reversed(pts)]
    return [[(x, y + 18) for x, y in p] for p in (body, wing_r, mirror(wing_r), tail_r, mirror(tail_r))]


def draw(size=1024, rounded=True, margin=0.0):
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    # blue gradient background
    grad = Image.new('RGBA', (S, S))
    gd = ImageDraw.Draw(grad)
    top, bot = (59, 130, 246), (29, 78, 216)
    for y in range(S):
        t = y / (S - 1)
        gd.line([(0, y), (S, y)], fill=tuple(int(top[k] + (bot[k] - top[k]) * t) for k in range(3)) + (255,))
    m = int(S * margin)
    mask = Image.new('L', (S, S), 0)
    md = ImageDraw.Draw(mask)
    if rounded:
        md.rounded_rectangle([m, m, S - 1 - m, S - 1 - m], radius=int((S - 2 * m) * 0.225), fill=255)
    else:
        md.rectangle([m, m, S - 1 - m, S - 1 - m], fill=255)
    img.paste(grad, (0, 0), mask)
    # white plane, flying up and to the right (like a rising chart)
    d = ImageDraw.Draw(img)
    scale = (S - 2 * m) / 1000 * 0.80
    ang = math.radians(45)
    cx = cy = S / 2
    for poly in plane_points():
        pts = []
        for x, y in poly:
            rx = x * math.cos(ang) - y * math.sin(ang)
            ry = x * math.sin(ang) + y * math.cos(ang)
            pts.append((cx + rx * scale, cy + ry * scale))
        d.polygon(pts, fill=(255, 255, 255, 255))
    return img.resize((size, size), Image.LANCZOS)


def main(root):
    big = draw(1024)
    os.makedirs(os.path.join(root, 'logo'), exist_ok=True)
    for n in (192, 256, 512):
        big.resize((n, n), Image.LANCZOS).save(os.path.join(root, 'logo', 'logo%d.png' % n))
    big.resize((256, 256), Image.LANCZOS).save(os.path.join(root, 'build', 'icon.png'))
    big.resize((256, 256), Image.LANCZOS).save(os.path.join(root, 'ui', 'logo.png'))
    ico_sizes = [(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (128, 128), (256, 256)]
    for p in (os.path.join(root, 'build', 'icon.ico'), os.path.join(root, 'logo', 'logo.ico')):
        big.save(p, format='ICO', sizes=ico_sizes)
    # macOS icons leave a margin around the rounded square (Big Sur style)
    mac = draw(1024, margin=0.09)
    mac.save(os.path.join(root, 'logo', 'logo.icns'), format='ICNS')
    big.resize((512, 512), Image.LANCZOS).save(os.path.join(root, 'logo', 'preview.png'))
    print('icons written')


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..'))
