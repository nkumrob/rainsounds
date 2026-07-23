#!/usr/bin/env bash
# Build a short, seamlessly-looping ambient audio bed -> build/loop_audio.m4a
#
# procedural mode (default): one or more sounds are synthesised by the
# generators in generators.sh (rain, ocean, wind, stream, waterfall, fire,
# fan, airplane, thunder, and white/pink/brown noise) using only ffmpeg noise
# sources and filters -- no samples. Multiple sounds can be layered into a
# soundscape (e.g. rain + distant thunder). The mix is then made gap-free with
# the classic loop trick: swap the two halves and crossfade the new seam. The
# output's ends land on originally-continuous audio, so when it loops there is
# no click; the only edited seam sits in the middle and is crossfaded.
#
# Which sound(s) to build come from config/project.json:
#   "audio": { "type": "rain", "intensity": "medium", ... }          # single
#   "audio": { "layers": [ {"type":"rain","gain":1.0,"intensity":"medium"},
#                          {"type":"thunder","gain":0.4} ], ... }     # mix
#
# asset mode: your own recording (assets/rain.wav) is looped/normalised the
# same way, so even a non-looping clip becomes a seamless bed.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/generators.sh"
check_deps

MODE=$(cfg audio.mode)
LOOP=$(cfg audio.loop_seconds)
CF=$(cfg audio.crossfade_seconds)
TARGET=$(cfg audio.target_lufs)
ASSET=$(cfg audio.asset_path "assets/rain.wav")

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
if fresh "$OUT" "$CONFIG_FILE" "$0" "$SCRIPT_DIR/generators.sh"; then
  log "audio up to date (procedural): $OUT"; exit 0
fi

# Resolve the sound layers from config. Emits one "type gain intensity" line
# per layer: audio.layers[] if present, otherwise the single audio.type.
LAYERS=$(CONFIG_FILE="$CONFIG_FILE" python3 - <<'PY'
import json, os
a = json.load(open(os.environ["CONFIG_FILE"]))["audio"]
default_int = a.get("intensity", "medium")
layers = a.get("layers")
if not layers:
    layers = [{"type": a.get("type", "rain"), "gain": 1.0, "intensity": default_int}]
for l in layers:
    print(l["type"], l.get("gain", 1.0), l.get("intensity", default_int))
PY
)

# Synthesise each layer to its own float WAV via the generators.
layer_wavs=(); weights=(); i=0; desc=()
while read -r type gain intensity; do
  [[ -z "$type" ]] && continue
  if ! declare -f "gen_$type" >/dev/null; then
    die "unknown sound type '$type' (available: $SOUND_TYPES)"
  fi
  wav="$BUILD_DIR/_layer_${i}.wav"
  log "Synthesising layer: $type (gain=$gain, intensity=$intensity)"
  INTENSITY="$intensity" "gen_$type" "$wav"
  layer_wavs+=("$wav"); weights+=("$gain"); desc+=("$type"); i=$((i+1))
done <<< "$LAYERS"

[[ ${#layer_wavs[@]} -ge 1 ]] || die "no sound layers resolved from config."

# Mix the layers (if >1) and loudness-normalise to the target LUFS -> RAW.
if [[ ${#layer_wavs[@]} -eq 1 ]]; then
  ffmpeg -y -hide_banner -loglevel error -i "${layer_wavs[0]}" \
    -af "highpass=f=28,loudnorm=I=${TARGET}:TP=-1.5:LRA=11" -c:a pcm_f32le "$RAW"
else
  in_args=(); for w in "${layer_wavs[@]}"; do in_args+=(-i "$w"); done
  W="${weights[*]}"
  log "Mixing ${#layer_wavs[@]} layers: ${desc[*]}"
  ffmpeg -y -hide_banner -loglevel error "${in_args[@]}" \
    -filter_complex "amix=inputs=${#layer_wavs[@]}:weights=${W}:normalize=0,highpass=f=28,loudnorm=I=${TARGET}:TP=-1.5:LRA=11[o]" \
    -map "[o]" -c:a pcm_f32le "$RAW"
fi
rm -f "${layer_wavs[@]}"

seamless_loop "$RAW"
rm -f "$RAW"
log "wrote $OUT"
