# assets/

Drop your own audio/video clips here to use them via **asset mode** instead of
procedural generation. Files in this folder are git-ignored (except this
README) so large media never lands in the repo.

## Bring your own recording

```jsonc
// config/project.json
"audio": { "mode": "asset", "asset_path": "assets/my_rain.wav",
           "loop_seconds": 300, "crossfade_seconds": 8, "target_lufs": -20 }
```
The clip is looped seamlessly (swap-halves + crossfade), so even a short,
non-looping recording becomes a gap-free bed of any length.

Video works the same way via `"visual": { "mode": "asset", "asset_path": "assets/scene.mp4" }`.

## AI-generated clips

`scripts/ai_fetch.sh` drops a generated clip here, ready for asset mode:

```bash
export ELEVENLABS_API_KEY=...            # or STABILITY_API_KEY + AI_PROVIDER=stableaudio
./scripts/ai_fetch.sh "heavy rain on a tent, distant thunder" rain_tent
# -> assets/rain_tent.mp3, then set audio.mode=asset / asset_path accordingly
```

AI models only make short clips; the seamless-loop render turns them into
15-hour beds. Preview a request without spending credits: `DRY_RUN=1 ...`.

**Note:** the API host must be reachable. In a restricted/agent environment the
egress policy may block it — run the fetch on your own machine, or allow the
host in your environment's network policy.
