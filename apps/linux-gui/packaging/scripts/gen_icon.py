#!/usr/bin/env python3
"""
Generate a 256x256 GhostStream icon (lime "G" on near-black tile) as PNG.

Uses only the Python standard library (zlib + struct + binascii), so the
build host does not need Pillow / ImageMagick. Output goes to
`apps/linux-gui/assets/icons/ghoststream.png`.
"""

import struct, zlib, binascii, os, sys

SIZE   = 256
BG     = (10, 9, 8)       # matches Theme.bg
RIM    = (61, 56, 40)     # hair_bold
LIME   = (196, 255, 62)   # Theme.signal
LIME_D = (74, 96, 16)     # signal_dim


def put(px, x, y, rgba):
    if 0 <= x < SIZE and 0 <= y < SIZE:
        px[y * SIZE + x] = rgba


def fill_rect(px, x0, y0, x1, y1, rgba):
    for y in range(max(0, y0), min(SIZE, y1)):
        for x in range(max(0, x0), min(SIZE, x1)):
            px[y * SIZE + x] = rgba


def fill_circle(px, cx, cy, r, rgba, glow=False):
    r2 = r * r
    for y in range(max(0, cy - r - 2), min(SIZE, cy + r + 2)):
        for x in range(max(0, cx - r - 2), min(SIZE, cx + r + 2)):
            dx = x - cx; dy = y - cy
            d2 = dx * dx + dy * dy
            if d2 <= r2:
                px[y * SIZE + x] = rgba
            elif glow and d2 <= (r + 2) ** 2:
                # soft halo
                blend = int(255 * (1.0 - (d2 - r2) / (((r + 2) ** 2) - r2)))
                r_, g_, b_, a_ = rgba
                # composite over current
                cur = px[y * SIZE + x]
                cr, cg, cb, _ = cur
                px[y * SIZE + x] = (
                    (cr * (255 - blend) + r_ * blend) // 255,
                    (cg * (255 - blend) + g_ * blend) // 255,
                    (cb * (255 - blend) + b_ * blend) // 255,
                    255,
                )


def main(out_path):
    px = [(BG[0], BG[1], BG[2], 255)] * (SIZE * SIZE)

    # 16px dark border frame
    fill_rect(px, 8, 8, SIZE - 8, 10, RIM + (255,))
    fill_rect(px, 8, SIZE - 10, SIZE - 8, SIZE - 8, RIM + (255,))
    fill_rect(px, 8, 8, 10, SIZE - 8, RIM + (255,))
    fill_rect(px, SIZE - 10, 8, SIZE - 8, SIZE - 8, RIM + (255,))

    # "G" — drawn as an outer arc (near-circle with right-opening) + a short
    # inward tongue at the middle right. Approximated with rectangles + circle.
    cx, cy = SIZE // 2, SIZE // 2
    outer_r = 88
    inner_r = 66

    # Outer ring (stroke) — the "G" arc.
    for y in range(cy - outer_r - 2, cy + outer_r + 2):
        for x in range(cx - outer_r - 2, cx + outer_r + 2):
            dx = x - cx; dy = y - cy
            d2 = dx * dx + dy * dy
            if inner_r * inner_r <= d2 <= outer_r * outer_r:
                px[y * SIZE + x] = LIME + (255,)

    # Carve the right-facing opening (the gap of the "G"). Upper-right wedge
    # cleared between x>cx and narrow y-band.
    gap_h = 30
    for y in range(cy - gap_h // 2, cy - gap_h // 2 + 6):
        for x in range(cx + 22, cx + outer_r + 4):
            if 0 <= x < SIZE and 0 <= y < SIZE:
                px[y * SIZE + x] = (BG[0], BG[1], BG[2], 255)
    # (the opening should be to the right; remove upper-right quarter arc area)
    for y in range(cy - outer_r - 2, cy + 6):
        for x in range(cx + 2, cx + outer_r + 4):
            dx = x - cx; dy = y - cy
            d2 = dx * dx + dy * dy
            if inner_r * inner_r - 12 * inner_r <= d2 <= outer_r * outer_r and dy < -6 and dx > 6:
                # keep only the topmost sliver (rim) and clear middle
                if -12 < dy < 0:
                    continue
                px[y * SIZE + x] = (BG[0], BG[1], BG[2], 255)

    # Horizontal tongue across the middle-right — signature "G" serif.
    fill_rect(px, cx + 6, cy - 6, cx + outer_r - 6, cy + 6, LIME + (255,))
    # inner cutout to make the tongue a stub, not full rectangle
    fill_rect(px, cx + 6, cy - 4, cx + outer_r - 30, cy + 4, (BG[0], BG[1], BG[2], 255))

    # Small accent dot (lower-right) like a signal LED.
    fill_circle(px, SIZE - 34, SIZE - 34, 5, LIME + (255,), glow=True)

    # Serialize to PNG.
    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)  # filter = None
        for x in range(SIZE):
            r, g, b, a = px[y * SIZE + x]
            raw.extend((r, g, b, a))
    compressed = zlib.compress(bytes(raw), 9)

    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        crc = binascii.crc32(tag + data) & 0xFFFFFFFF
        out += struct.pack(">I", crc)
        return out

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    png = sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", compressed) + chunk(b"IEND", b"")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(png)
    print(f"wrote {out_path} ({len(png)} bytes)")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(__file__), "..", "..", "assets", "icons", "ghoststream.png"
    )
    main(os.path.abspath(out))
