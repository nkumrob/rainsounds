#!/usr/bin/env bash
# Stitch the seamless loops into the final long-form MP4 -> output/<name>
#
# The key to a stable 15-hour export is that we DO NOT re-encode. Both loops
# are already H.264/AAC in an MP4-friendly form, so we loop them with
# -stream_loop and stream-copy (-c copy). ffmpeg just repeats the already
# encoded packets, which is fast, uses almost no CPU, and cannot fail halfway
# through a transcode. Video and audio loops can be different lengths; since
# each is individually seamless, the mix stays continuous for any duration.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
check_deps

VIS="$BUILD_DIR/loop_visual.mp4"
AUD="$BUILD_DIR/loop_audio.m4a"
NAME=$(cfg output_name)
DUR=$(cfg duration_seconds)

# Overrides for quick smoke tests:
#   DURATION=30 OUT_NAME=sample.mp4 ./scripts/render.sh
DUR="${DURATION:-$DUR}"
NAME="${OUT_NAME:-$NAME}"
OUT="$OUTPUT_DIR/$NAME"

[[ -f "$VIS" ]] || die "missing $VIS — run scripts/make_visual.sh first."
[[ -f "$AUD" ]] || die "missing $AUD — run scripts/make_audio.sh first."

log "Rendering final video: $(hms "$DUR") -> $OUT"
log "  visual loop: $(basename "$VIS")   audio loop: $(basename "$AUD")   (stream-copy, no re-encode)"

ffmpeg -y -hide_banner -loglevel error -stats \
  -stream_loop -1 -i "$VIS" \
  -stream_loop -1 -i "$AUD" \
  -map 0:v:0 -map 1:a:0 \
  -t "$DUR" \
  -c copy -movflags +faststart \
  -avoid_negative_ts make_zero -fflags +genpts \
  "$OUT"

# report
SIZE=$(du -h "$OUT" | cut -f1)
ACTUAL=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT" 2>/dev/null || echo "?")
log "Done: $OUT  (${SIZE}, ${ACTUAL}s)"
