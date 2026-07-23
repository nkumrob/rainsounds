#!/usr/bin/env bash
# A/B test: does ElevenLabs' native `loop` flag produce a more seamless clip
# than the default (unlooped) generation?
#
# It fetches the SAME prompt twice — once with AI_LOOP=0, once with AI_LOOP=1 —
# then objectively scores each raw clip's loop seam: how big a jump you'd hear
# if the clip were butt-joined end-to-start (i.e. looped with no crossfade).
# Lower seam score = smoother natural loop. It also renders a listen-test file
# for each so you can confirm by ear.
#
# Usage:
#   ELEVENLABS_API_KEY=... scripts/ai_ab_test.sh "gentle rain on leaves" [basename]
#
# Env knobs:
#   AI_DURATION  clip length in seconds (default 22)
#   REPEATS      loops to concatenate for the listen-test file (default 3)
#
# Requires: the same reachable API + curl as ai_fetch.sh, plus ffmpeg/ffprobe.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMPT="${1:-}"
BASE="${2:-abtest}"
[[ -n "$PROMPT" ]] || die "usage: scripts/ai_ab_test.sh \"<prompt>\" [basename]"
need ffmpeg
need ffprobe

FETCH="$SCRIPT_DIR/ai_fetch.sh"
REPEATS="${REPEATS:-3}"

# Score the loop seam of a clip. Ambient beds are stochastic — the end and
# start never match sample-for-sample even in a good loop — so we don't measure
# sample difference (that just measures decorrelation). What a listener actually
# hears at the wrap is a LEVEL jump: if the clip fades out at the end but the
# start is loud (or vice-versa), the loop "pumps" once per cycle. So the score
# is the absolute RMS-level difference (in dB) between a short window at the end
# and one at the start. LOWER dB = smoother loop (level is continuous at the seam).
win_rms() {  # win_rms <wav> <ffmpeg-seek-args...>  -> RMS_level in dB
  ffmpeg -v error "$@" -filter_complex "astats=metadata=1:reset=0" -f null - 2>&1 \
    | awk -F': ' '/RMS_level/{v=$2} END{print v}'
}
seam_score() {  # seam_score <audio_file>  -> abs dB level jump at the wrap (lower better)
  local f="$1" win=0.25 wav rms_tail rms_head
  wav="$(mktemp "$BUILD_DIR/ab_XXXX.wav")"
  ffmpeg -v error -y -i "$f" -ac 1 -ar 44100 "$wav"
  rms_tail=$(win_rms -sseof -"$win" -i "$wav")   # last 250 ms
  rms_head=$(win_rms -t "$win" -i "$wav")        # first 250 ms
  rm -f "$wav"
  python3 -c "print(f'{abs(float('$rms_tail') - float('$rms_head')):.2f}')" 2>/dev/null || echo "n/a"
}

# render REPEATS butt-joined copies so you can hear the seam(s)
listen_file() {  # listen_file <clip> <out>
  local clip="$1" out="$2" list; list="$(mktemp "$BUILD_DIR/ab_list_XXXX.txt")"
  local i; for ((i=0;i<REPEATS;i++)); do printf "file '%s'\n" "$(cd "$(dirname "$clip")"&&pwd)/$(basename "$clip")" >>"$list"; done
  ffmpeg -v error -y -f concat -safe 0 -i "$list" -c copy "$out" 2>/dev/null \
    || ffmpeg -v error -y -f concat -safe 0 -i "$list" "$out"
  rm -f "$list"
}

log "A/B test — prompt: \"$PROMPT\"  (${AI_DURATION:-22}s each)"

log "[A] fetching WITHOUT native loop..."
AI_LOOP=0 "$FETCH" "$PROMPT" "${BASE}_noloop" >/dev/null
A="$ASSETS_DIR/${BASE}_noloop.mp3"

log "[B] fetching WITH native loop..."
AI_LOOP=1 "$FETCH" "$PROMPT" "${BASE}_loop" >/dev/null
B="$ASSETS_DIR/${BASE}_loop.mp3"

SA=$(seam_score "$A")
SB=$(seam_score "$B")
LA="$OUTPUT_DIR/${BASE}_noloop_x${REPEATS}.mp3"; listen_file "$A" "$LA"
LB="$OUTPUT_DIR/${BASE}_loop_x${REPEATS}.mp3";   listen_file "$B" "$LB"

winner="tie / inconclusive (within 0.5 dB)"
python3 -c "import sys; sys.exit(0 if float('$SB') < float('$SA')-0.5 else 1)" 2>/dev/null && winner="B (native loop) — smoother seam"
python3 -c "import sys; sys.exit(0 if float('$SA') < float('$SB')-0.5 else 1)" 2>/dev/null && winner="A (no loop) — smoother seam"

cat >&2 <<EOF

──────────────── A/B RESULT ────────────────
  Seam level-jump (LOWER dB = smoother natural loop):
    A  no native loop : ${SA} dB   -> $A
    B  native loop=on : ${SB} dB   -> $B
  Winner: $winner

  Listen (the seam repeats ${REPEATS}x):
    A: $LA
    B: $LB
─────────────────────────────────────────────
Note: the pipeline's own swap-halves+crossfade smooths BOTH before the final
render, so this measures the raw seed. A higher score means less work for the
crossfade to hide — generally the better seed to loop into a 15h bed.
EOF
