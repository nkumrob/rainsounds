#!/usr/bin/env bash
# Fetch an AI-generated ambient/sound-effect clip into assets/, so the existing
# asset-mode pipeline can loop it seamlessly to any length.
#
# AI models only produce short clips (seconds). This pipeline's seamless-loop +
# no-re-encode render is the other half: AI gives realism, we give length. So
# the flow is:  prompt -> short AI clip -> assets/<name> -> seamless 15h render.
#
# Usage:
#   scripts/ai_fetch.sh "heavy rain on a tent, distant thunder" [out_basename]
#
# Providers (set AI_PROVIDER, default elevenlabs):
#   elevenlabs   needs ELEVENLABS_API_KEY   (hosted SFX API, commercial on paid plans)
#   stableaudio  needs STABILITY_API_KEY    (hosted, longer ambient clips)
#
# Env knobs:
#   AI_DURATION  clip length in seconds (default 22; provider caps apply)
#   DRY_RUN=1    print the request that would be made, don't call the API
#
# This script is OPTIONAL. The procedural generators (generators.sh) remain the
# free, offline default; AI is an opt-in realism upgrade per sound.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMPT="${1:-}"
NAME="${2:-ai_sound}"
PROVIDER="${AI_PROVIDER:-elevenlabs}"
DURATION="${AI_DURATION:-22}"

[[ -n "$PROMPT" ]] || die "usage: scripts/ai_fetch.sh \"<prompt>\" [out_basename]"
need curl

OUT_BASE="$ASSETS_DIR/$NAME"

hint_next() {
  local f="$1"
  cat >&2 <<EOF

Fetched: $f

Next, point the pipeline at it (edit config/project.json):
  "audio": { "mode": "asset", "asset_path": "assets/$(basename "$f")",
             "loop_seconds": 300, "crossfade_seconds": 8, "target_lufs": -20 }
Then:  make audio && make render
The asset is looped seamlessly (swap-halves + crossfade) regardless of whether
the AI clip itself loops.
EOF
}

case "$PROVIDER" in
  elevenlabs)
    OUT="${OUT_BASE}.mp3"
    URL="https://api.elevenlabs.io/v1/sound-generation"
    BODY=$(PROMPT="$PROMPT" DURATION="$DURATION" python3 -c '
import json, os
print(json.dumps({
    "text": os.environ["PROMPT"],
    "duration_seconds": float(os.environ["DURATION"]),
    "prompt_influence": 0.5,
}))')
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      log "[dry-run] POST $URL"
      log "[dry-run] header: xi-api-key: \$ELEVENLABS_API_KEY"
      log "[dry-run] body: $BODY"
      log "[dry-run] -> $OUT"
      exit 0
    fi
    [[ -n "${ELEVENLABS_API_KEY:-}" ]] || die "set ELEVENLABS_API_KEY (get one at https://elevenlabs.io/api)."
    log "Requesting ElevenLabs SFX: \"$PROMPT\" (${DURATION}s)"
    http=$(curl -sS -w '%{http_code}' -o "$OUT" -X POST "$URL" \
      -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "$BODY")
    [[ "$http" == "200" ]] || { warn "$(cat "$OUT" 2>/dev/null | head -c 400)"; rm -f "$OUT"; die "ElevenLabs API returned HTTP $http"; }
    hint_next "$OUT"
    ;;

  stableaudio)
    OUT="${OUT_BASE}.wav"
    URL="https://api.stability.ai/v2beta/audio/stable-audio-2/text-to-audio"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      log "[dry-run] POST $URL"
      log "[dry-run] header: Authorization: Bearer \$STABILITY_API_KEY"
      log "[dry-run] multipart: prompt=$PROMPT duration=$DURATION output_format=wav"
      log "[dry-run] -> $OUT"
      exit 0
    fi
    [[ -n "${STABILITY_API_KEY:-}" ]] || die "set STABILITY_API_KEY (get one at https://platform.stability.ai/)."
    log "Requesting Stable Audio: \"$PROMPT\" (${DURATION}s)"
    http=$(curl -sS -w '%{http_code}' -o "$OUT" -X POST "$URL" \
      -H "Authorization: Bearer ${STABILITY_API_KEY}" \
      -H "Accept: audio/*" \
      -F "prompt=${PROMPT}" \
      -F "duration=${DURATION}" \
      -F "output_format=wav")
    [[ "$http" == "200" ]] || { warn "$(cat "$OUT" 2>/dev/null | head -c 400)"; rm -f "$OUT"; die "Stability API returned HTTP $http"; }
    hint_next "$OUT"
    ;;

  *)
    die "unknown AI_PROVIDER '$PROVIDER' (supported: elevenlabs, stableaudio)"
    ;;
esac
