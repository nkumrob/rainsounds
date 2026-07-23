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
#   AI_LOOP=1    ask the provider to make the clip loop smoothly (elevenlabs only)
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

# POST helper that classifies failures: connection/egress-policy blocks vs HTTP
# errors, so a blocked host in a restricted environment gives actionable advice
# instead of a raw "curl (56) CONNECT tunnel failed".
_post() {  # _post OUT_FILE curl-args...
  local out="$1"; shift
  local code rc
  set +e
  code=$(curl -sS -w '%{http_code}' -o "$out" "$@")
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    rm -f "$out"
    if [[ $rc -eq 56 || $rc -eq 7 || $rc -eq 35 ]]; then
      warn "Could not connect to the API host (curl $rc)."
      warn "In a restricted / agent environment the egress policy may block it."
      warn "Fixes: allow this host in your environment's network policy, or run"
      warn "this script on your own machine where outbound HTTPS is open."
    fi
    die "request failed (curl exit $rc)"
  fi
  case "$code" in
    200) : ;;
    401|403) warn "$(head -c 300 "$out" 2>/dev/null)"; rm -f "$out"; die "HTTP $code — check the API key / plan permissions." ;;
    *)   warn "$(head -c 300 "$out" 2>/dev/null)"; rm -f "$out"; die "API returned HTTP $code" ;;
  esac
}

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
    BODY=$(PROMPT="$PROMPT" DURATION="$DURATION" LOOP="${AI_LOOP:-0}" python3 -c '
import json, os
body = {
    "text": os.environ["PROMPT"],
    "duration_seconds": float(os.environ["DURATION"]),
    "prompt_influence": 0.5,
}
# Opt-in: ask ElevenLabs to synthesize an already-loopable clip. The pipeline
# still runs its own swap-halves+crossfade, but a natively-looping seed gives a
# cleaner seam. See https://elevenlabs.io/docs/api-reference/text-to-sound-effects/convert
if os.environ["LOOP"] == "1":
    body["loop"] = True
print(json.dumps(body))')
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      log "[dry-run] POST $URL"
      log "[dry-run] header: xi-api-key: \$ELEVENLABS_API_KEY"
      log "[dry-run] body: $BODY"
      log "[dry-run] -> $OUT"
      exit 0
    fi
    [[ -n "${ELEVENLABS_API_KEY:-}" ]] || die "set ELEVENLABS_API_KEY (get one at https://elevenlabs.io/api)."
    log "Requesting ElevenLabs SFX: \"$PROMPT\" (${DURATION}s)"
    _post "$OUT" -X POST "$URL" \
      -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "$BODY"
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
    _post "$OUT" -X POST "$URL" \
      -H "Authorization: Bearer ${STABILITY_API_KEY}" \
      -H "Accept: audio/*" \
      -F "prompt=${PROMPT}" \
      -F "duration=${DURATION}" \
      -F "output_format=wav"
    hint_next "$OUT"
    ;;

  *)
    die "unknown AI_PROVIDER '$PROVIDER' (supported: elevenlabs, stableaudio)"
    ;;
esac
