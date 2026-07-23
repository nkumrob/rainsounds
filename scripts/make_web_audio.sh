#!/usr/bin/env bash
# Build the website's seamless audio loops -> site/audio/*.m4a
#
# Each ElevenLabs clip in assets/ goes through the same swap-halves +
# crossfade transform as make_audio.sh, so the file's end flows into its
# start. The web player then loops the decoded buffer sample-accurately.
#
# Usage: scripts/make_web_audio.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
check_deps

LOOP=16 CF=6 TARGET=-20 SR=48000
RAW_LEN=$((LOOP + CF))
HALF=$(python3 -c "print(($LOOP + $CF) / 2)")
OUT_DIR="$ROOT_DIR/site/audio"
mkdir -p "$OUT_DIR"

# mood_name:asset_basename
MOODS="drizzle:rain_gentle downpour:rain_steady tent:rain_tent"

for pair in $MOODS; do
  mood="${pair%%:*}" src_base="${pair#*:}"
  src="$ASSETS_DIR/${src_base}.mp3"
  out="$OUT_DIR/${mood}.wav"
  [[ -f "$src" ]] || die "missing $src (generate it with scripts/ai_fetch.sh)"
  if fresh "$out" "$src" "$0"; then log "up to date: $out"; continue; fi
  log "Building seamless web loop: $mood <- ${src_base}.mp3"
  raw="$BUILD_DIR/_web_raw.wav" ha="$BUILD_DIR/_web_a.wav" hb="$BUILD_DIR/_web_b.wav"
  ffmpeg -y -hide_banner -loglevel error -stream_loop -1 -i "$src" \
    -t "$RAW_LEN" -ac 2 -ar "$SR" \
    -af "loudnorm=I=${TARGET}:TP=-1.5:LRA=11" "$raw"
  ffmpeg -y -hide_banner -loglevel error -i "$raw" \
    -af "atrim=end=${HALF},asetpts=PTS-STARTPTS" "$ha"
  ffmpeg -y -hide_banner -loglevel error -i "$raw" \
    -af "atrim=start=${HALF},asetpts=PTS-STARTPTS" "$hb"
  ffmpeg -y -hide_banner -loglevel error -i "$hb" -i "$ha" \
    -filter_complex "[0:a][1:a]acrossfade=d=${CF}:c1=qsin:c2=qsin[out]" \
    -map "[out]" -ar "$SR" -c:a pcm_s16le "$out"
  rm -f "$raw" "$ha" "$hb"
  log "wrote $out"
done
