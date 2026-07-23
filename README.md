# rainsounds — long-form ambient video pipeline

A small, dependency-light pipeline that renders **long-form (e.g. 15-hour)
relaxing ambient videos** as a single MP4. It builds one short *seamless* visual
loop and one short *seamless* audio loop, then stitches them to the target
length **without re-encoding**, so even a 15-hour export takes seconds and can't
fail halfway through.

The audio is a **procedural ambient-sound library** — 12 sounds synthesized
entirely from FFmpeg noise + filters (no samples), which can be layered into
soundscapes.

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

## Sound library

The audio is chosen in config. Every sound is synthesized from FFmpeg noise +
filters — no recordings needed.

| Type | Sound | Type | Sound |
|------|-------|------|-------|
| `rain` | rain (warm wash + droplet patter) | `waterfall` | steady heavy roar |
| `ocean` | surf with slow wave swell | `fan` | warm steady airflow |
| `wind` | band-limited howl with gusts | `airplane` | cabin drone |
| `stream` | creek / river burble | `fireplace` | low roar + crackle |
| `thunder` | distant rolling rumble | `white` | white noise |
| `brown` | brown noise (deep, bass-heavy) | `pink` | pink noise |

Preview every sound (writes `output/previews/<type>.m4a`):

```bash
./scripts/preview_sounds.sh 20            # 20s clip of each of the 12 sounds
TYPES="rain ocean fireplace" ./scripts/preview_sounds.sh 15   # just these
```

### Single sound

```jsonc
"audio": {
  "mode": "procedural",
  "type": "ocean",          // any type from the table above
  "intensity": "medium",    // light | medium | heavy  (mainly affects rain)
  "loop_seconds": 300,
  "crossfade_seconds": 8,
  "target_lufs": -20
}
```

### Layered soundscapes

Provide `layers` instead of `type` to mix sounds — this is how the classic
combos ("rain 70% + thunder 20%", "ocean + wind") are built. Each layer has a
`type` and a relative `gain`:

```jsonc
"audio": {
  "mode": "procedural",
  "loop_seconds": 300,
  "crossfade_seconds": 8,
  "target_lufs": -20,
  "layers": [
    { "type": "rain",    "gain": 1.0, "intensity": "heavy" },
    { "type": "thunder", "gain": 0.5 },
    { "type": "wind",    "gain": 0.3 }
  ]
}
```

Each layer is synthesized independently, mixed by gain, then the combined bed is
loudness-normalised and made seamless as one unit.

Sounds that realistically need field recordings (forest birds, café, train) are
best handled with **asset mode** — drop a file in `assets/` and set
`"mode": "asset"`.

### AI-generated sounds (optional)

For maximum realism you can generate a seed clip with an AI model and let the
pipeline loop it. AI models only make short clips (seconds); this pipeline's
seamless-loop + no-re-encode render is the other half — **AI gives realism, the
pipeline gives length.** Flow: `prompt → short AI clip → assets/ → seamless 15h`.

```bash
# ElevenLabs (hosted SFX API; commercial use on paid plans)
export ELEVENLABS_API_KEY=...   # from https://elevenlabs.io/api
./scripts/ai_fetch.sh "heavy rain on a tent, distant thunder" rain_tent

# Stable Audio (hosted; longer ambient clips)
export STABILITY_API_KEY=...
AI_PROVIDER=stableaudio AI_DURATION=90 ./scripts/ai_fetch.sh "calm ocean at night" ocean_night

# See the exact request without calling the API / spending credits:
DRY_RUN=1 ./scripts/ai_fetch.sh "campfire crackling" campfire
```

The script drops the clip in `assets/` and prints the config snippet to use it
via asset mode. **Licensing note for monetized videos:** use commercially-
licensed output — ElevenLabs paid plans, Stable Audio's commercial API, or the
local *Stable Audio Open Small* model. Avoid non-commercial-only model weights.
Procedural generators stay the free, offline default; AI is an opt-in upgrade.

## Website — `site/`

A single-page, no-build web player: land, press **begin**, and it rains
forever. Generative canvas rain (three parallax depth layers) with three
switchable moods — **drizzle / downpour / tent** — that crossfade the audio
over 2 s while the visual weather morphs to match. Night + overcast-day
themes, volume (persisted), 15/30/60-min sleep timer with a slow fade-out,
space + 1/2/3 keyboard shortcuts, Media Session lock-screen controls,
`prefers-reduced-motion` fallback.

```bash
./scripts/make_web_audio.sh          # assets/*.mp3 -> site/audio/*.wav (seamless loops)
cd site && python3 -m http.server    # or host site/ anywhere static (GitHub Pages etc.)
```

Audio is served as WAV (universally decodable, no encoder padding) and looped
sample-accurately via Web Audio, so the loop is truly gapless; a plain
`<audio loop>` fallback covers browsers without Web Audio.

## Presets

Alternate configs live in `config/`. Point `CONFIG_FILE` at one for any target:

| Preset | Look / sound | Notes |
| --- | --- | --- |
| `config/project.json` | medium rain, 1080p24 | the default |
| `config/heavy-storm.json` | rain + thunder + wind (layered) | louder (`-19 LUFS`) |
| `config/light-sleep.json` | light rain, quiet | gentle (`-23 LUFS`), longer crossfade |
| `config/ocean.json` | ocean surf + wind (layered) | seaside soundscape |
| `config/campfire.json` | fireplace + faint wind (layered) | cozy |
| `config/brown-noise.json` | brown noise | the trending focus/sleep noise |
| `config/4k.json` | medium rain, 3840×2160 @ 30fps | ~4× the render size |

```bash
CONFIG_FILE=config/ocean.json make sample         # preview a preset
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
- **Thunder.** The `thunder` sound is a *continuous* distant rumble (add it as a
  layer). Discrete thunderclaps are intentionally avoided because a one-off event
  would break seamless looping — use asset mode for those.
- `make clean` removes everything under `build/` and `output/`.
