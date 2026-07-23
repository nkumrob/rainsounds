#!/usr/bin/env bash
# Generate a short audio preview of every procedural sound type.
# Output: output/previews/<type>.m4a  (default 20s each, seamless loop applied)
#
# Usage:
#   ./scripts/preview_sounds.sh [seconds]        # all types
#   TYPES="rain ocean wind" ./scripts/preview_sounds.sh 15

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/generators.sh"
check_deps

SR=48000
SECS="${1:-20}"
CF=4
RAW_LEN=$(python3 -c "print($SECS + $CF)")
HALF=$(python3 -c "print(($SECS + $CF) / 2)")
TARGET=-20
TYPES="${TYPES:-$SOUND_TYPES}"

PREV_DIR="$OUTPUT_DIR/previews"
mkdir -p "$PREV_DIR"

for t in $TYPES; do
  declare -f "gen_$t" >/dev/null || { warn "skip unknown type: $t"; continue; }
  log "preview: $t (${SECS}s)"
  raw="$BUILD_DIR/_prev_${t}.wav"
  ha="$BUILD_DIR/_prev_a.wav"; hb="$BUILD_DIR/_prev_b.wav"
  INTENSITY=medium "gen_$t" "$raw" </dev/null
  # normalise, then seamless-loop (swap halves + crossfade) to <SECS> seconds
  ffmpeg -nostdin -y -hide_banner -loglevel error -i "$raw" \
    -af "highpass=f=28,loudnorm=I=${TARGET}:TP=-1.5:LRA=11" -c:a pcm_f32le "${raw}.n.wav"
  ffmpeg -nostdin -y -hide_banner -loglevel error -i "${raw}.n.wav" \
    -af "atrim=end=${HALF},asetpts=PTS-STARTPTS" "$ha"
  ffmpeg -nostdin -y -hide_banner -loglevel error -i "${raw}.n.wav" \
    -af "atrim=start=${HALF},asetpts=PTS-STARTPTS" "$hb"
  ffmpeg -nostdin -y -hide_banner -loglevel error -i "$hb" -i "$ha" \
    -filter_complex "[0:a][1:a]acrossfade=d=${CF}:c1=qsin:c2=qsin[out]" \
    -map "[out]" -ar "$SR" -c:a aac -b:a 256k "$PREV_DIR/${t}.m4a"
  rm -f "$raw" "${raw}.n.wav" "$ha" "$hb"
done

log "previews in $PREV_DIR"
ls -1 "$PREV_DIR"
