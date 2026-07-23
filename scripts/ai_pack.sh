#!/usr/bin/env bash
# Fetch a curated pack of AI sound effects into assets/ in one go, then print
# ready-to-use config snippets. Wraps ai_fetch.sh (same provider/env rules).
#
# Usage:
#   export ELEVENLABS_API_KEY=...        # or STABILITY_API_KEY + AI_PROVIDER=stableaudio
#   ./scripts/ai_pack.sh                 # fetch the default pack
#   DRY_RUN=1 ./scripts/ai_pack.sh       # show what it would fetch
#
# Requires the API host to be reachable (open network, or allowed in the
# environment's egress policy). If a fetch is blocked it stops with a clear
# message from ai_fetch.sh.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FETCH="$SCRIPT_DIR/ai_fetch.sh"
DUR="${AI_DURATION:-22}"

# name  ->  prompt
PACK=(
  "ai_rain|steady heavy rain falling, gentle continuous downpour, no thunder, calming ambience"
  "ai_ocean|calm ocean waves rolling onto a sandy beach, slow rhythmic surf, distant sea"
  "ai_fire|crackling campfire, wood fire with soft pops and embers, cozy"
  "ai_thunder|distant rolling thunder rumbling low, overcast storm far away, no rain"
  "ai_forest|gentle forest ambience, soft wind in leaves, calm woodland"
)

log "Fetching ${#PACK[@]} SFX (${DUR}s each) into assets/ …"
for entry in "${PACK[@]}"; do
  name="${entry%%|*}"; prompt="${entry#*|}"
  AI_DURATION="$DUR" "$FETCH" "$prompt" "$name"
done

cat <<'EOF'

--- Use a fetched sound (single) ---
"audio": { "mode": "asset", "asset_path": "assets/ai_rain.mp3",
           "loop_seconds": 300, "crossfade_seconds": 8, "target_lufs": -20 }

Then:  make audio && make sample
Each clip is looped seamlessly regardless of whether the AI clip loops.
EOF
