#!/usr/bin/env python3
"""Generate the OGG Vorbis sounds shipped with the Etherbeep mod.

The mod ships the rendered .ogg files, so you only need this script if you want
to tweak or regenerate them.

    pip install numpy soundfile
    python3 tools/generate_sounds.py

Output goes to Etherbeep/media/sound/.
"""

import os
import numpy as np
import soundfile as sf

RATE = 44100
OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Etherbeep", "media", "sound",
)


def silence(seconds):
    return np.zeros(int(RATE * seconds), dtype=np.float64)


def tone(freq, seconds, decay=6.0, partials=(1.0, 0.35, 0.12), detune=0.0):
    """A plucked/bell-like tone: a few harmonic partials under an exp decay."""
    t = np.linspace(0.0, seconds, int(RATE * seconds), endpoint=False)
    wave = np.zeros_like(t)
    for i, amp in enumerate(partials, start=1):
        wave += amp * np.sin(2.0 * np.pi * freq * i * (1.0 + detune) * t)
    envelope = np.exp(-decay * t)
    # short attack so the onset does not click
    attack = np.clip(t / 0.005, 0.0, 1.0)
    return wave * envelope * attack


def place(buffer, sound, at_seconds, gain=1.0):
    start = int(RATE * at_seconds)
    end = min(start + len(sound), len(buffer))
    buffer[start:end] += sound[: end - start] * gain
    return buffer


def normalize(buffer, peak=0.89):
    top = np.max(np.abs(buffer))
    if top > 0:
        buffer = buffer / top * peak
    # 8 ms fade out so the file never ends on a discontinuity
    fade = int(RATE * 0.008)
    buffer[-fade:] *= np.linspace(1.0, 0.0, fade)
    return buffer


def build_chime():
    """Soft two-note bell -- the default 'a character was born' sound."""
    out = silence(1.9)
    place(out, tone(1046.50, 1.8, decay=3.4), 0.00, 0.85)  # C6
    place(out, tone(1567.98, 1.6, decay=3.8), 0.16, 0.60)  # G6
    place(out, tone(2093.00, 1.2, decay=5.0), 0.16, 0.18)  # C7 shimmer
    return normalize(out)


def build_fanfare():
    """Rising major arpeggio, a touch more celebratory."""
    out = silence(2.3)
    notes = [(523.25, 0.00), (659.25, 0.13), (783.99, 0.26), (1046.50, 0.40)]
    for freq, when in notes:
        place(out, tone(freq, 1.6, decay=4.2, partials=(1.0, 0.42, 0.18, 0.06)), when, 0.7)
    place(out, tone(1567.98, 1.5, decay=3.0, partials=(1.0, 0.25)), 0.40, 0.30)
    return normalize(out)


def build_blip():
    """Terse UI blip for people who do not want a jingle every respawn."""
    seconds = 0.16
    t = np.linspace(0.0, seconds, int(RATE * seconds), endpoint=False)
    sweep = np.sin(2.0 * np.pi * (880.0 + 1400.0 * t / seconds) * t)
    envelope = np.exp(-16.0 * t) * np.clip(t / 0.003, 0.0, 1.0)
    return normalize(sweep * envelope)


def write(name, data):
    path = os.path.join(OUT_DIR, name)
    sf.write(path, data.astype(np.float32), RATE, format="OGG", subtype="VORBIS")
    print("wrote %s (%.2fs, %d bytes)" % (path, len(data) / RATE, os.path.getsize(path)))


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    chime = build_chime()
    write("Etherbeep_Chime.ogg", chime)
    write("Etherbeep_Fanfare.ogg", build_fanfare())
    write("Etherbeep_Blip.ogg", build_blip())
    # Etherbeep_Custom.ogg ships as a copy of the chime so the sound script always
    # resolves; users overwrite this one file to use their own audio.
    write("Etherbeep_Custom.ogg", chime)


if __name__ == "__main__":
    main()
