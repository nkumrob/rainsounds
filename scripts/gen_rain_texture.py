#!/usr/bin/env python3
"""Generate a vertically-tileable rain-streak texture as a binary PPM (P6).

The texture is black with additive light streaks. It is *vertically tileable*:
streaks that run off the bottom wrap back to the top, so when the pipeline
scrolls it by exactly one texture-height per loop the motion is seamless with
no visible seam.

Only the Python standard library is used, so it runs anywhere python3 does.

Usage:
    gen_rain_texture.py --width 1920 --height 1080 \
        --intensity medium --seed 7 --out build/rain_texture.ppm
"""
import argparse
import random
import sys

# streaks-per-pixel-of-width, by intensity
DENSITY = {"light": 0.12, "medium": 0.28, "heavy": 0.55}

# base streak tint (cool blue-grey), scaled per-streak by its brightness
TINT = (150, 170, 200)


def build(width, height, intensity, seed):
    rng = random.Random(seed)
    # near-black background so compositing with 'screen'/'addition' reads clean
    buf = bytearray(width * height * 3)

    n_streaks = max(1, int(width * DENSITY.get(intensity, DENSITY["medium"])))

    def add_px(x, y, bright):
        # wrap vertically -> tileable; clamp horizontally
        if x < 0 or x >= width:
            return
        y %= height
        i = (y * width + x) * 3
        for c in range(3):
            v = buf[i + c] + int(TINT[c] * bright)
            buf[i + c] = 255 if v > 255 else v

    for _ in range(n_streaks):
        x0 = rng.randint(0, width - 1)
        y0 = rng.randint(0, height - 1)
        length = rng.randint(int(height * 0.04), int(height * 0.16))
        # perspective: some streaks are near (bright/long), most are far (faint)
        depth = rng.random()
        bright = 0.15 + 0.85 * (depth ** 2)
        drift = rng.uniform(-0.12, 0.12)  # slight slant, px per row
        thickness = 1 if depth < 0.7 else 2

        for k in range(length):
            y = y0 + k
            x = int(round(x0 + drift * k))
            # taper the head and tail so streaks fade in/out instead of ending hard
            edge = min(k, length - 1 - k)
            fade = min(1.0, edge / 6.0)
            b = bright * (0.35 + 0.65 * fade)
            for t in range(thickness):
                add_px(x + t, y, b)

    return buf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--intensity", default="medium")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if args.width <= 0 or args.height <= 0:
        sys.exit("width/height must be positive")

    buf = build(args.width, args.height, args.intensity, args.seed)
    with open(args.out, "wb") as fh:
        fh.write(b"P6\n%d %d\n255\n" % (args.width, args.height))
        fh.write(buf)


if __name__ == "__main__":
    main()
