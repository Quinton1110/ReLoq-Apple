#!/usr/bin/env python3
"""Describe a WAV: rate, frames, duration, peak, RMS and a rough fundamental (zero crossings).
Usage: tools/wav_probe.py file.wav [...]"""
import sys, wave, struct


def probe(path):
    w = wave.open(path)
    rate, n, ch, width = w.getframerate(), w.getnframes(), w.getnchannels(), w.getsampwidth()
    raw = w.readframes(n)
    if width != 2 or ch != 1:
        return f"{path}: rate={rate} frames={n} ch={ch} width={width} (not 16-bit mono, not analysed)"
    s = struct.unpack("<%dh" % n, raw)
    peak = max((abs(x) for x in s), default=0)
    rms = (sum(x * x for x in s) / n) ** 0.5 if n else 0
    loud = [x for x in s if abs(x) > 0]
    zc = sum(1 for i in range(1, len(loud)) if (loud[i - 1] < 0) != (loud[i] < 0))
    hz = zc / 2.0 / (len(loud) / rate) if loud else 0
    # leading / trailing silence (|x| <= 8)
    lead = next((i for i, x in enumerate(s) if abs(x) > 8), n)
    trail = next((i for i, x in enumerate(reversed(s)) if abs(x) > 8), n)
    return (f"{path}: rate={rate} frames={n} duration={n / rate:.3f}s peak={peak} rms={rms:.0f} "
            f"zcHz={hz:.0f} lead={lead / rate * 1000:.0f}ms trail={trail / rate * 1000:.0f}ms")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print(probe(p))
