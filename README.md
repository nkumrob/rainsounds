# rainsounds — long-form rain video pipeline

A small, dependency-light pipeline that renders a **long-form (e.g. 15-hour)
relaxing rain video** as a single MP4. It builds one short *seamless* rain
visual loop and one short *seamless* rain audio loop, then stitches them to the
target length **without re-encoding**, so even a 15-hour export takes seconds
and can't fail halfway through.

```
config/project.json ──► make_visual ──► build/loop_visual.mp4 ─┐
                    └──► make_audio  ──► build/loop_audio.m4a  ─┴─► render ─► output/rain_15h.mp4
```

Everything is driven by `config/project.json` and every stage caches its output
in `build/`, so runs are resumable — only stale stages rebuild.

## Requirements

- **ffmpeg / ffprobe** (with `libx264` + `aac`) — the only hard dependency.
- **python3** — standard library only (no numpy/PIL needed).
- **make** — optional, for the convenience targets.

Install ffmpeg: `apt-get install ffmpeg` (Debian/Ubuntu) or `brew install ffmpeg` (macOS).

## Quick start

```bash
# 1. Build both loops and render a 30-second preview:
make sample            # -> output/sample.mp4

# 2. Happy with it? Render the full length from config/project.json:
make all               # -> output/rain_15h.mp4  (15h by default)
```

Or run the stages directly:

```bash
./scripts/make_visual.sh     # build/loop_visual.mp4  (seamless rain visual)
./scripts/make_audio.sh      # build/loop_audio.m4a   (seamless rain audio)
./scripts/render.sh          # output/<output_name>   (final long MP4)
```

Handy overrides:

```bash
DURATION=60 OUT_NAME=test.mp4 ./scripts/render.sh   # quick 60s render
FORCE=1 ./scripts/make_visual.sh                    # ignore cache, rebuild
CONFIG_FILE=config/heavy-storm.json make all        # use an alternate config
```

## Presets

Alternate configs live in `config/`. Point `CONFIG_FILE` at one for any target:

| Preset | Look / sound | Notes |
| --- | --- | --- |
| `config/project.json` | medium rain, 1080p24 | the default |
| `config/heavy-storm.json` | heavy rain + continuous distant thunder | louder (`-19 LUFS`) |
| `config/light-sleep.json` | light rain, quiet | gentle (`-23 LUFS`), longer crossfade |
| `config/4k.json` | medium rain, 3840×2160 @ 30fps | ~4× the render size |

```bash
CONFIG_FILE=config/light-sleep.json make sample   # preview a preset
CONFIG_FILE=config/4k.json make all               # full 4K render
```

## Configuration — `config/project.json`

```jsonc
{
  "output_name": "rain_15h.mp4",
  "duration_seconds": 54000,      // final length (54000 = 15 hours)
  "width": 1920, "height": 1080, "fps": 24,

  "visual": {
    "mode": "procedural",         // "procedural" | "asset"
    "asset_path": "assets/scene.mp4",
    "loop_seconds": 20,           // length of the visual loop that gets repeated
    "intensity": "medium",        // light | medium | heavy  (streak density)
    "scene": "window"
  },

  "audio": {
    "mode": "procedural",         // "procedural" | "asset"
    "asset_path": "assets/rain.wav",
    "loop_seconds": 300,          // length of the audio loop that gets repeated
    "crossfade_seconds": 8,       // seam crossfade for the seamless loop
    "intensity": "medium",        // light | medium | heavy
    "thunder": false,             // adds a continuous distant rumble
    "target_lufs": -20            // loudness normalisation target
  }
}
```

Video and audio loop lengths are independent — since each is individually
seamless, the final mix stays continuous no matter how the two repeat.

## How the seamlessness works

**Visual.** `scripts/gen_rain_texture.py` draws a rain-streak texture that is
*vertically tileable* (streaks wrap top-to-bottom). The renderer stacks two
copies of it and scrolls a one-screen-tall window down by exactly one texture
height over the loop. Because rows `r` and `r + height` of the stack are
identical, the jump back to the start is just one more evenly-spaced step —
mathematically seamless, with no reset or stutter. It's composited over a static
dark gradient "scene" so the background never shifts.

**Audio.** `scripts/make_audio.sh` synthesises rain from two decorrelated
pink-noise sources (natural stereo width), spectrally shaped into a rain "shhh".
It's made gap-free with the classic loop trick: **swap the two halves and
crossfade the new seam.** The loop's ends then land on audio that was originally
continuous, so it repeats without a click; the only edited join sits in the
middle and is equal-power crossfaded.

**Render.** Both loops are already H.264/AAC, so `scripts/render.sh` repeats
them with `-stream_loop -1` and **stream-copies** (`-c copy`) to the target
duration. No transcoding means the export is fast (~1000× realtime), uses almost
no CPU, and won't die partway through a long encode.

## Using your own assets

Drop your files in `assets/` and switch modes in the config:

- **Visual:** set `visual.mode` to `"asset"` and `asset_path` to your scene
  video (e.g. a looping window/forest/tent clip). It's scaled/cropped to your
  resolution and looped to `loop_seconds`.
- **Audio:** set `audio.mode` to `"asset"` and `asset_path` to your rain
  recording. Even a non-looping clip is run through the same seamless-loop
  transform, so it becomes a gap-free bed.

## Notes

- **Disk & length.** A 15-hour 1080p render is ~8–9 GB. Make sure you have room;
  the intermediates in `build/` are tiny (a few MB each).
- **Thunder.** `thunder: true` adds a *continuous* distant rumble that stays
  loopable. Discrete thunderclaps are intentionally avoided because a one-off
  event would break seamless looping — layer those separately if you want them.
- `make clean` removes everything under `build/` and `output/`.
