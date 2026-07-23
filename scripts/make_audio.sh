#!/usr/bin/env bash
# Build a short, seamlessly-looping rain audio bed -> build/loop_audio.m4a
#
# procedural mode (default): two decorrelated pink-noise sources are spectrally
# shaped into a rain "shhh", then made gap-free with the classic loop trick:
#   swap the two halves and crossfade the new seam.
# The output's ends land on originally-continuous audio, so when it loops there
# is no click; the only edited seam sits in the middle and is crossfaded.
#
# asset mode: your own recording (assets/rain.wav) is looped/normalised the
# same way, so even a non-looping clip becomes a seamless bed.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
check_deps

MODE=$(cfg audio.mode)
LOOP=$(cfg audio.loop_seconds)
CF=$(cfg audio.crossfade_seconds)
INTENSITY=$(cfg audio.intensity)
THUNDER=$(cfg audio.thunder)
TARGET=$(cfg audio.target_lufs)
ASSET=$(cfg audio.asset_path)

OUT="$BUILD_DIR/loop_audio.m4a"
RAW="$BUILD_DIR/_rain_raw.wav"
SR=48000

# RAW length = LOOP + CF so the seamless output is exactly LOOP seconds.
RAW_LEN=$(python3 -c "print($LOOP + $CF)")
HALF=$(python3 -c "print(($LOOP + $CF) / 2)")

seamless_loop() {
  # $1 = input wav (length RAW_LEN). Writes a seamless loop of length LOOP to
  # $OUT by swapping the two halves and crossfading the new seam. The halves
  # are written to temp files first: feeding acrossfade two independent inputs
  # avoids the EOF-timing deadlock you hit when both come from one asplit.
  local src="$1"
  local ha="$BUILD_DIR/_half_a.wav" hb="$BUILD_DIR/_half_b.wav"
  ffmpeg -y -hide_banner -loglevel error -i "$src" \
    -af "atrim=end=${HALF},asetpts=PTS-STARTPTS" "$ha"
  ffmpeg -y -hide_banner -loglevel error -i "$src" \
    -af "atrim=start=${HALF},asetpts=PTS-STARTPTS" "$hb"
  # second-half then first-half, crossfaded at the join (equal-power qsin).
  ffmpeg -y -hide_banner -loglevel error -i "$hb" -i "$ha" \
    -filter_complex "[0:a][1:a]acrossfade=d=${CF}:c1=qsin:c2=qsin[out]" \
    -map "[out]" -ar "$SR" -c:a aac -b:a 192k "$OUT"
  rm -f "$ha" "$hb"
}

if [[ "$MODE" == "asset" ]]; then
  ASSET_PATH="$ROOT_DIR/$ASSET"
  [[ -f "$ASSET_PATH" ]] || die "audio.mode is 'asset' but '$ASSET' not found."
  if fresh "$OUT" "$ASSET_PATH" "$CONFIG_FILE" "$0"; then
    log "audio up to date (asset): $OUT"; exit 0
  fi
  log "Preparing asset '$ASSET' into a ${LOOP}s seamless loop"
  ffmpeg -y -hide_banner -loglevel error -stream_loop -1 -i "$ASSET_PATH" \
    -t "$RAW_LEN" -ac 2 -ar "$SR" \
    -af "loudnorm=I=${TARGET}:TP=-1.5:LRA=11" "$RAW"
  seamless_loop "$RAW"
  rm -f "$RAW"
  log "wrote $OUT"
  exit 0
fi

# --- procedural ---------------------------------------------------------
if fresh "$OUT" "$CONFIG_FILE" "$0"; then
  log "audio up to date (procedural): $OUT"; exit 0
fi

# spectral shaping per intensity
case "$INTENSITY" in
  light) HP=200; LP=9000;  PATTER=2; LOWSHELF=0 ;;
  heavy) HP=55;  LP=12000; PATTER=4; LOWSHELF=6 ;;
  *)     HP=110; LP=11000; PATTER=3; LOWSHELF=2 ;;  # medium
esac

SHAPE="highpass=f=${HP},lowpass=f=${LP},equalizer=f=1600:t=q:w=1.4:g=${PATTER},bass=g=${LOWSHELF}:f=180"

log "Synthesising ${RAW_LEN}s rain bed (intensity=${INTENSITY}, thunder=${THUNDER})"

INPUTS=(
  -f lavfi -i "anoisesrc=color=pink:seed=11:amplitude=0.9:d=${RAW_LEN}:r=${SR}"
  -f lavfi -i "anoisesrc=color=pink:seed=29:amplitude=0.9:d=${RAW_LEN}:r=${SR}"
)

if [[ "$THUNDER" == "true" ]]; then
  # distant, continuous rolling rumble (kept stationary so the loop stays seamless;
  # discrete thunderclaps would break looping and are intentionally avoided).
  INPUTS+=(-f lavfi -i "anoisesrc=color=brown:seed=5:amplitude=0.9:d=${RAW_LEN}:r=${SR}")
  FC="[0:a]${SHAPE}[l];[1:a]${SHAPE}[r];[l][r]join=inputs=2:channel_layout=stereo[st]; \
      [2:a]lowpass=f=110,volume=0.35,tremolo=f=0.07:d=0.8,aformat=channel_layouts=stereo[th]; \
      [st][th]amix=inputs=2:weights=1 0.6:normalize=0,loudnorm=I=${TARGET}:TP=-1.5:LRA=11[o]"
else
  FC="[0:a]${SHAPE}[l];[1:a]${SHAPE}[r];[l][r]join=inputs=2:channel_layout=stereo, \
      loudnorm=I=${TARGET}:TP=-1.5:LRA=11[o]"
fi

ffmpeg -y -hide_banner -loglevel error "${INPUTS[@]}" \
  -filter_complex "$FC" -map "[o]" -ar "$SR" -ac 2 -c:a pcm_s16le "$RAW"

seamless_loop "$RAW"
rm -f "$RAW"
log "wrote $OUT"
