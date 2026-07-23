#!/usr/bin/env bash
# Build a short, seamlessly-looping rain audio bed -> build/loop_audio.m4a
#
# procedural mode (default): rain is synthesised per channel from two layers so
# it reads as rain rather than flat static:
#   * wash   - warm brown-noise body + gently rolled-off pink "air"; the harsh
#              3-5 kHz hiss region is cut so it sounds like rain, not a fan.
#   * patter - band-passed noise pushed through a compand expander/gate, which
#              turns steady noise into intermittent droplet transients (the
#              "pitter-patter"). This granular layer is what sells "rain".
# Left/right are built from independent noise seeds for natural stereo width,
# then the whole thing is made gap-free with the classic loop trick:
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
    -map "[out]" -ar "$SR" -c:a aac -b:a 256k "$OUT"
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

# Per-intensity voicing.
#   BODY_HP/BODY_LP : brown-noise body band     BODY_W : its level
#   AIR_LP          : top of the pink "air"      AIR_W  : its level
#   PAT_F           : patter band centre         PAT_W  : droplet level
# Lower rain (heavier) has more body, a fuller/lower patter and a little more
# high extension; lighter rain is thinner and quieter.
# MASTER_LP caps the brightness of the whole mix -> the main de-hiss control.
case "$INTENSITY" in
  light) BODY_HP=90; BODY_LP=5000; AIR_LP=4600; PAT_F=1900; BODY_W=0.85; AIR_W=0.34; PAT_W=0.55; MASTER_LP=5000 ;;
  heavy) BODY_HP=42; BODY_LP=6200; AIR_LP=6400; PAT_F=1300; BODY_W=1.55; AIR_W=0.42; PAT_W=1.00; MASTER_LP=7000 ;;
  *)     BODY_HP=60; BODY_LP=5600; AIR_LP=5400; PAT_F=1600; BODY_W=1.20; AIR_W=0.38; PAT_W=0.78; MASTER_LP=6000 ;;  # medium
esac

# emit the filter subgraph for one channel: brown input $1, pink input $2, label $3
chan() {
  local bi="$1" pi="$2" o="$3"
  printf '[%s:a]highpass=f=%s,lowpass=f=%s,volume=%s[b%s];' "$bi" "$BODY_HP" "$BODY_LP" "$BODY_W" "$o"
  printf '[%s:a]asplit=2[air%s][pat%s];' "$pi" "$o" "$o"
  # air: rolled-off pink with a high-shelf cut above ~3 kHz to kill the "fan hiss".
  printf '[air%s]highpass=f=240,lowpass=f=%s,treble=f=3000:g=-7,volume=%s[a%s];' \
         "$o" "$AIR_LP" "$AIR_W" "$o"
  # patter: band-pass then compand as a downward expander/gate so only the
  # random peaks pass -> intermittent droplet transients.
  printf '[pat%s]bandpass=f=%s:t=h:w=1900,compand=attacks=0.002:decays=0.06:points=-90/-118|-55/-80|-40/-46|-20/-17|0/-3,volume=%s[p%s];' \
         "$o" "$PAT_F" "$PAT_W" "$o"
  printf '[b%s][a%s][p%s]amix=inputs=3:normalize=0[%s];' "$o" "$o" "$o" "$o"
}

log "Synthesising ${RAW_LEN}s rain bed (intensity=${INTENSITY}, thunder=${THUNDER})"

INPUTS=(
  -f lavfi -i "anoisesrc=color=brown:seed=11:amplitude=0.9:d=${RAW_LEN}:r=${SR}"
  -f lavfi -i "anoisesrc=color=pink:seed=29:amplitude=0.9:d=${RAW_LEN}:r=${SR}"
  -f lavfi -i "anoisesrc=color=brown:seed=71:amplitude=0.9:d=${RAW_LEN}:r=${SR}"
  -f lavfi -i "anoisesrc=color=pink:seed=97:amplitude=0.9:d=${RAW_LEN}:r=${SR}"
)

FC="$(chan 0 1 L)$(chan 2 3 R)[L][R]join=inputs=2:channel_layout=stereo[st];"

if [[ "$THUNDER" == "true" ]]; then
  # distant, continuous rolling rumble (kept stationary so the loop stays seamless;
  # discrete thunderclaps would break looping and are intentionally avoided).
  INPUTS+=(-f lavfi -i "anoisesrc=color=brown:seed=5:amplitude=0.9:d=${RAW_LEN}:r=${SR}")
  FC+="[4:a]lowpass=f=100,volume=0.32,tremolo=f=0.12:d=0.8,aformat=channel_layouts=stereo[th]; \
       [st][th]amix=inputs=2:weights=1 0.6:normalize=0[mix];"
  LAST="mix"
else
  LAST="st"
fi

# subsonic cleanup + master low-pass (warmth / de-hiss) + loudness normalisation.
FC+="[${LAST}]highpass=f=28,lowpass=f=${MASTER_LP},loudnorm=I=${TARGET}:TP=-1.5:LRA=11[o]"

ffmpeg -y -hide_banner -loglevel error "${INPUTS[@]}" \
  -filter_complex "$FC" -map "[o]" -ar "$SR" -ac 2 -c:a pcm_s16le "$RAW"

seamless_loop "$RAW"
rm -f "$RAW"
log "wrote $OUT"
