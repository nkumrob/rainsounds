# Rain Sounds — single-page website design

Date: 2026-07-23
Status: proposed

## Purpose

A one-purpose, award-worthy single page: you land, you tap once, and it rains
forever. Three curated ElevenLabs-generated rain moods, switchable, looping
seamlessly. Dark, cinematic, nothing to read — the page *is* the rain.

## Decisions (from brainstorming)

- **Platform:** static site, no build step — `site/` folder in this repo
  (index.html + style.css + app.js + audio files). Hostable on GitHub
  Pages/Netlify as-is.
- **Visual:** full-screen generative canvas rain (2D canvas, no WebGL, no
  libraries): layered depth (3 parallax layers of streaks), subtle glass-blur
  glow, density/speed tied to the active mood. Controls fade out when idle.
- **Sound switching:** three named moods with ~2 s equal-power crossfade;
  visual rain density morphs with the mood:
  - **Drizzle** — `rain_gentle.mp3` (light)
  - **Downpour** — `rain_steady.mp3` (heavy)
  - **Tent** — `rain_tent.mp3` (rain on canvas + distant thunder)
- **V1 features:** volume slider (persisted in localStorage), sleep timer
  (15/30/60 min with slow fade-out), keyboard shortcuts (space = play/pause,
  1/2/3 = moods) + Media Session API for lock-screen/headphone controls.
- **Autoplay:** browsers block it, so the site opens on a beautiful minimal
  intro — the wordmark "rain sounds" and a single "begin" affordance. First
  tap starts audio + rain.

## Architecture

```
site/
  index.html      markup: intro overlay, canvas, control bar
  style.css       design system: type, color, motion, fade states
  app.js          three modules in one file (~400 lines):
                    AudioEngine  – Web Audio: gapless loop + crossfade + volume + timer fade
                    RainCanvas   – generative rain, mood-driven parameters
                    UI           – controls, keyboard, Media Session, idle fade, localStorage
  audio/
    drizzle.m4a   seamless loops produced by the existing pipeline
    downpour.m4a  (scripts/make_audio.sh seamless_loop transform applied
    tent.m4a       to each ElevenLabs mp3, ~16 s each, small files)
```

### Gapless looping (the critical detail)

MP3/AAC encoders pad the stream, so `<audio loop>` clicks at the seam. Instead:

1. Each ElevenLabs clip is pre-processed through the repo's existing
   swap-halves + crossfade transform (same as `make_audio.sh`) so the file's
   ends are continuity-safe.
2. In the browser, `AudioEngine` fetches and `decodeAudioData`s each file into
   an `AudioBuffer` and plays it with `AudioBufferSourceNode.loop = true`,
   using `loopStart`/`loopEnd` trimmed a few ms inside the buffer to skip
   encoder padding. Result: sample-accurate, truly gapless.
3. Mood switch = start new source at 0 gain, equal-power crossfade over 2 s,
   stop old source.

### Visual design language

- Near-black blue-charcoal field (#0a0e14 family), rain streaks in cool
  desaturated blues with additive glow; film-grain overlay for texture.
- One serif/display wordmark, lowercase: "rain sounds". Tiny caps for controls.
- Motion: everything eases slowly (600–900 ms); controls fade to nothing after
  3 s idle; cursor hides while idle.
- Mood switch subtly changes streak density, speed, angle jitter, and
  background luminance (Tent = slightly darker + occasional soft flash far
  away, matching its distant thunder).

## Error handling

- Audio fetch/decode failure → per-mood retry once, then a quiet inline note.
- Web Audio unavailable → fall back to plain `<audio loop>` elements
  (accepting the seam click) rather than a broken page.
- Timer end → fade to silence over 60 s, pause, show intro affordance again.

## Testing

- Playwright (webapp-testing toolkit): page loads, begin → playing state,
  mood switch updates UI, volume persists across reload, keyboard shortcuts.
- Manual: listen for loop seams and crossfade quality; check Media Session on
  macOS media keys.

## Out of scope (v1)

- No accounts, no mixing multiple sounds, no PWA/offline, no analytics.
- No mobile app; responsive layout only.

## Implementation steps

1. **Audio prep** — script `scripts/make_web_audio.sh`: run each of the three
   ElevenLabs mp3s through the seamless-loop transform → `site/audio/*.m4a`
   (16 s loop, 6 s crossfade, −20 LUFS), reusing `lib.sh`/`make_audio.sh` logic.
2. **Static shell** — `site/index.html` + `style.css`: intro overlay, canvas,
   control bar, wordmark, full design system.
3. **AudioEngine** — gapless Web Audio looping, crossfade switching, volume
   with persistence, sleep-timer fade, `<audio>` fallback.
4. **RainCanvas** — 3-layer parallax generative rain with mood parameter sets,
   devicePixelRatio-aware, `prefers-reduced-motion` respected (static mist).
5. **UI wiring** — mood selector, play/pause, volume, timer menu, idle fade,
   keyboard, Media Session metadata.
6. **Verify** — serve `site/` locally (`python3 -m http.server`), Playwright
   checks + screenshot review; listen test; commit.
