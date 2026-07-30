#!/usr/bin/env python3
"""Generate Etherbeep/poster.png, the 256x256 image shown in the mod list.

    pip install numpy
    python3 tools/generate_poster.py
"""

import os
import struct
import zlib

import numpy as np

SIZE = 256
SS = 4  # supersample factor, for smooth edges
OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Etherbeep", "poster.png",
)

BACKGROUND = np.array([0.07, 0.08, 0.10])
GLOW = np.array([0.10, 0.16, 0.19])
ACCENT = np.array([0.36, 0.85, 0.82])
ACCENT_DIM = np.array([0.20, 0.50, 0.52])


def render():
    n = SIZE * SS
    y, x = np.mgrid[0:n, 0:n].astype(np.float64)
    # coordinates in a -1..1 square, origin at the emitter dot on the left
    cx, cy = n * 0.34, n * 0.5
    dx = (x - cx) / (n * 0.5)
    dy = (y - cy) / (n * 0.5)
    radius = np.sqrt(dx * dx + dy * dy)
    angle = np.arctan2(dy, dx)

    # background with a soft glow behind the emitter
    image = np.zeros((n, n, 3), dtype=np.float64)
    image += BACKGROUND
    image += (GLOW - BACKGROUND) * np.clip(1.0 - radius / 1.1, 0.0, 1.0)[..., None] ** 2

    # emitter dot
    dot = np.clip((0.075 - radius) / 0.012, 0.0, 1.0)
    image = image * (1 - dot[..., None]) + ACCENT * dot[..., None]

    # three arcs opening to the right, fading as they travel outwards
    cone = np.abs(angle) < np.deg2rad(52)
    for index, ring in enumerate((0.20, 0.34, 0.48)):
        thickness = 0.022
        band = np.clip(1.0 - np.abs(radius - ring) / thickness, 0.0, 1.0)
        band = band * cone
        # soften where the arc meets the edge of the cone
        band = band * np.clip((np.deg2rad(52) - np.abs(angle)) / np.deg2rad(10), 0.0, 1.0)
        colour = ACCENT * (1.0 - 0.22 * index) + ACCENT_DIM * (0.22 * index)
        alpha = (band * (1.0 - 0.18 * index))[..., None]
        image = image * (1 - alpha) + colour * alpha

    # subtle vignette so the poster does not look flat in the mod list
    vignette = np.clip(1.15 - 0.45 * np.sqrt(((x - n / 2) ** 2 + (y - n / 2) ** 2)) / (n / 2), 0.0, 1.0)
    image *= vignette[..., None]

    # downsample the supersampled buffer
    image = image.reshape(SIZE, SS, SIZE, SS, 3).mean(axis=(1, 3))
    return np.clip(image * 255.0, 0, 255).astype(np.uint8)


def write_png(path, pixels):
    height, width, _ = pixels.shape
    raw = b"".join(b"\x00" + pixels[row].tobytes() for row in range(height))

    def chunk(tag, payload):
        body = tag + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")

    with open(path, "wb") as handle:
        handle.write(png)


if __name__ == "__main__":
    write_png(OUT, render())
    print("wrote %s (%d bytes)" % (OUT, os.path.getsize(OUT)))
