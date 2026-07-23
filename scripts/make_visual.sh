#!/usr/bin/env bash
# Build a short, seamlessly-looping rain visual -> build/loop_visual.mp4
#
# procedural mode (default): a tileable rain-streak texture is scrolled by
# exactly one texture-height over the loop, composited over a dark gradient
# "scene". Because two stacked copies are scrolled one full height, the wrap
# is mathematically seamless.
#
# asset mode: your own scene video (assets/scene.mp4) is looped/normalised
# to the standard resolution, fps and loop length.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
check_deps

W=$(cfg width)
H=$(cfg height)
FPS=$(cfg fps)
MODE=$(cfg visual.mode)
LOOP=$(cfg visual.loop_seconds)
INTENSITY=$(cfg visual.intensity)
ASSET=$(cfg visual.asset_path)

OUT="$BUILD_DIR/loop_visual.mp4"

X264_COMMON=(-c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p
             -force_key_frames "expr:eq(n,0)" -g "$((FPS * LOOP))"
             -x264-params "scenecut=0" -movflags +faststart)

if [[ "$MODE" == "asset" ]]; then
  ASSET_PATH="$ROOT_DIR/$ASSET"
  [[ -f "$ASSET_PATH" ]] || die "visual.mode is 'asset' but '$ASSET' not found."
  if fresh "$OUT" "$ASSET_PATH" "$CONFIG_FILE"; then
    log "visual up to date (asset): $OUT"; exit 0
  fi
  log "Looping asset '$ASSET' -> ${LOOP}s @ ${W}x${H} ${FPS}fps"
  ffmpeg -y -hide_banner -loglevel error \
    -stream_loop -1 -i "$ASSET_PATH" -t "$LOOP" \
    -vf "scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},fps=${FPS}" \
    -an "${X264_COMMON[@]}" "$OUT"
  log "wrote $OUT"
  exit 0
fi

# --- procedural ---------------------------------------------------------
TEX="$BUILD_DIR/rain_texture.ppm"
if ! fresh "$TEX" "$SCRIPT_DIR/gen_rain_texture.py" "$CONFIG_FILE"; then
  log "Generating tileable rain texture (${W}x${H}, intensity=${INTENSITY})"
  python3 "$SCRIPT_DIR/gen_rain_texture.py" \
    --width "$W" --height "$H" --intensity "$INTENSITY" --seed 7 --out "$TEX"
fi

BG="$BUILD_DIR/bg.png"
if ! fresh "$BG" "$CONFIG_FILE" "$0"; then
  log "Rendering static night gradient background"
  # Single still: vertical gradient (dark blue -> near black) + vignette.
  # Rendering it once and looping it keeps the background perfectly static,
  # which is what makes the visual loop seamless.
  ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "color=black:s=${W}x${H}" -frames:v 1 \
    -vf "geq=r='11-7*Y/H':g='18-12*Y/H':b='32-20*Y/H',vignette=PI/5,format=rgb24" \
    "$BG"
fi

if fresh "$OUT" "$TEX" "$BG" "$CONFIG_FILE" "$0"; then
  log "visual up to date (procedural): $OUT"; exit 0
fi

log "Rendering ${LOOP}s seamless rain loop @ ${W}x${H} ${FPS}fps"

# Scroll expression. The stacked texture is 2*H tall and the crop window is H
# (= oh) tall. y sweeps 0 -> oh linearly, hitting oh*(N-1)/N on the last frame
# but never oh itself, so every frame's content position is a distinct, evenly
# spaced step of oh/N. Because rows r and r+H of the stack are identical, the
# jump back to y=0 on the next loop is just one more oh/N step -> seamless.
# Increasing y scrolls content upward, so we vflip the rain to make it fall.
SCROLL="oh*mod(t\,${LOOP})/${LOOP}"

ffmpeg -y -hide_banner -loglevel error \
  -loop 1 -framerate "$FPS" -t "$LOOP" -i "$BG" \
  -loop 1 -framerate "$FPS" -t "$LOOP" -i "$TEX" \
  -filter_complex "\
    [1:v]split[t0][t1];[t0][t1]vstack[tex]; \
    [tex]crop=${W}:${H}:0:'${SCROLL}',vflip,gblur=sigma=0.5,format=rgb24[rain]; \
    [0:v]format=rgb24[bg]; \
    [bg][rain]blend=all_mode=screen,format=yuv420p[v]" \
  -map "[v]" -t "$LOOP" -r "$FPS" \
  "${X264_COMMON[@]}" "$OUT"

log "wrote $OUT"
