#!/usr/bin/env python3
"""Generates Largo's built-in demo song (royalty-free: every sound is synthesized here).

    python3 Design/make-demo-song.py /path/to/output.wav

100 BPM, 4/4, G major, ~48 s: intro, verse (G D Em C), chorus (C D G Em / C D G G), outro.
Strummed "guitar" (plucked-string additive synthesis), bass and a simple drum kit, in stereo.
Run Design/make-demo-song.sh instead to also convert it to AAC with title, artist and cover art.
"""
import sys
import wave

import numpy as np

SR = 44_100
BPM = 100
BEAT = 60 / BPM
BAR = 4 * BEAT
rng = np.random.default_rng(7)

# Guitar voicings (MIDI note numbers), like open chords on a real guitar.
VOICINGS = {
    "G":  [43, 47, 50, 55, 59, 67],
    "D":  [50, 57, 62, 66],
    "Em": [40, 47, 52, 55, 59, 64],
    "C":  [48, 52, 55, 60, 64],
}
BASS_ROOT = {"G": 31, "D": 38, "Em": 40, "C": 36}  # an octave or two below

SECTIONS = [
    ("intro",  ["G", "D"]),
    ("verse",  ["G", "D", "Em", "C"] * 2),
    ("chorus", ["C", "D", "G", "Em", "C", "D", "G", "G"]),
    ("outro",  ["G", "G"]),
]

def freq(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)

def pluck(midi, dur, velocity):
    """Plucked nylon-like string: soft upper harmonics that decay faster the higher they are."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    f0 = freq(midi)
    out = np.zeros(n)
    for h in range(1, 7):  # up to the 6th harmonic; the 7th sounds like a minor seventh
        fh = f0 * h * (1 + 0.0004 * h * h)
        if fh > SR / 2.2:
            break
        decay = 1.2 + 0.9 * h + f0 / 220
        out += np.sin(2 * np.pi * fh * t + rng.uniform(0, 2 * np.pi)) * np.exp(-decay * t) / h ** 1.7
    attack = np.minimum(1, t / 0.004)
    release = np.minimum(1, (dur - t) / 0.03)  # short fade instead of a click when damped
    return out * attack * release * velocity

def strum(buf, start, chord, down, velocity, ring):
    notes = VOICINGS[chord] if down else list(reversed(VOICINGS[chord]))
    for i, midi in enumerate(notes):
        offset = start + i * rng.uniform(0.008, 0.014)  # strings are hit one after another
        add(buf, offset, pluck(midi, ring, velocity * rng.uniform(0.85, 1.0)))

def kick():
    t = np.arange(int(0.35 * SR)) / SR
    phase = 2 * np.pi * np.cumsum(50 + 90 * np.exp(-t * 30)) / SR
    return np.sin(phase) * np.exp(-t * 9)

def snare():
    t = np.arange(int(0.22 * SR)) / SR
    noise = rng.standard_normal(len(t))
    noise = noise - np.concatenate(([0], noise[:-1])) * 0.6  # brighter
    return (0.55 * noise * np.exp(-t * 22) + 0.5 * np.sin(2 * np.pi * 185 * t) * np.exp(-t * 30)) * 0.5

def hat(open_hat=False):
    t = np.arange(int((0.12 if open_hat else 0.05) * SR)) / SR
    noise = rng.standard_normal(len(t))
    noise = np.diff(np.diff(noise, prepend=0), prepend=0)  # crude high-pass
    return noise * np.exp(-t * (25 if open_hat else 70)) * 0.08

def bass_note(midi, dur):
    t = np.arange(int(dur * SR)) / SR
    f = freq(midi)
    tone = np.sin(2 * np.pi * f * t) + 0.35 * np.sin(4 * np.pi * f * t) + 0.12 * np.sin(6 * np.pi * f * t)
    return tone * np.minimum(1, t / 0.01) * np.exp(-t * 2.2) * 0.55

def add(buf, start, sound, gain=1.0):
    i = int(start * SR)
    if i >= len(buf):
        return
    end = min(len(buf), i + len(sound))
    buf[i:end] += sound[: end - i] * gain

def main(path):
    bars = [(section, chord) for section, chords in SECTIONS for chord in chords]
    total = len(bars) * BAR + 2.0
    guitar = np.zeros(int(total * SR))
    bass = np.zeros_like(guitar)
    drums_l = np.zeros_like(guitar)
    drums_r = np.zeros_like(guitar)

    # Strum pattern per bar, in eighths: D . D U . U D U
    pattern = [(0, True, 1.0), (2, True, 0.8), (3, False, 0.55), (5, False, 0.6), (6, True, 0.8), (7, False, 0.55)]
    for b, (section, chord) in enumerate(bars):
        t0 = b * BAR
        loud = 1.0 if section == "chorus" else 0.8
        if section in ("intro", "outro") and b == len(bars) - 1:
            strum(guitar, t0, chord, True, 0.45, 3.5)  # final chord rings out
        else:
            for eighth, down, vel in pattern:
                # Strings are damped at the chord change, like a guitarist does, so chords don't blur.
                ring = min(1.6, BAR - eighth * BEAT / 2 + 0.03)
                strum(guitar, t0 + eighth * BEAT / 2, chord, down, vel * loud * 0.32, ring)

        if section != "intro":
            root = BASS_ROOT[chord]
            for beat, midi in [(0, root), (1.5, root), (2, root + 7), (3, root + 12 if section == "chorus" else root)]:
                add(bass, t0 + beat * BEAT, bass_note(midi, BEAT * 1.4))

        if section in ("verse", "chorus") or (section == "outro" and b < len(bars) - 1):
            for beat in (0, 2):
                add(drums_l, t0 + beat * BEAT, kick(), 0.9)
                add(drums_r, t0 + beat * BEAT, kick(), 0.9)
            if section == "chorus":
                add(drums_l, t0 + 2.5 * BEAT, kick(), 0.6)
                add(drums_r, t0 + 2.5 * BEAT, kick(), 0.6)
            for beat in (1, 3):
                add(drums_l, t0 + beat * BEAT, snare(), 0.9)
                add(drums_r, t0 + beat * BEAT, snare(), 0.9)
            for eighth in range(8):
                open_hat = section == "chorus" and eighth == 7
                add(drums_r, t0 + eighth * BEAT / 2, hat(open_hat), 1.0 if eighth % 2 == 0 else 0.7)
                add(drums_l, t0 + eighth * BEAT / 2, hat(open_hat), 0.4)

    # Mix: guitar slightly left, bass centered, hats right; a touch of room via short echoes.
    left = 0.95 * guitar + bass + drums_l
    right = 0.75 * guitar + bass + drums_r
    for delay, gain in [(0.023, 0.18), (0.041, 0.12), (0.067, 0.08)]:
        d = int(delay * SR)
        left[d:] += right[:-d] * gain
        right[d:] += left[:-d] * gain

    # Fade out the last two seconds, normalize to -1 dBFS.
    fade = int(2.0 * SR)
    ramp = np.linspace(1, 0, fade)
    left[-fade:] *= ramp
    right[-fade:] *= ramp
    peak = max(np.abs(left).max(), np.abs(right).max())
    stereo = np.stack([left, right], axis=1) / peak * 10 ** (-1 / 20)

    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((stereo * 32767).astype("<i2").tobytes())
    print(f"Wrote {path}: {len(bars)} bars, {total:.1f} s")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "LargoDemo.wav")
