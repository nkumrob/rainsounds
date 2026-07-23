# shellcheck shell=bash
# Procedural ambient-sound generators.
#
# Each gen_<type> function synthesises one sound to a stereo float WAV ($1),
# RAW_LEN seconds long, at sample rate $SR. They use only ffmpeg's built-in
# noise sources and filters — no samples. Left/right are built from different
# noise seeds for natural stereo width. Output is intentionally NOT loudness-
# normalised here; make_audio.sh mixes the layers and normalises the result,
# so these just need sane relative levels. Float output avoids intermediate
# clipping when layers are summed.
#
# Globals expected: SR, RAW_LEN, and (for gen_rain) INTENSITY.

# shorthand: a mono anoisesrc input spec
_noise() { printf -- '-f lavfi -i anoisesrc=color=%s:seed=%s:amplitude=0.8:d=%s:r=%s' "$1" "$2" "$RAW_LEN" "$SR"; }

_emit() {  # _emit OUT FILTERCOMPLEX INPUT... -> runs ffmpeg producing stereo [o]
  local out="$1" fc="$2"; shift 2
  # -nostdin: these run inside a `while read` loop over the layer list; without
  # it ffmpeg would consume that list from stdin and mangle later layers.
  # shellcheck disable=SC2086
  ffmpeg -nostdin -y -hide_banner -loglevel error "$@" \
    -filter_complex "$fc" -map "[o]" -ar "$SR" -ac 2 -c:a pcm_f32le "$out"
}

# --- noise colours ------------------------------------------------------
gen_white() {
  _emit "$1" "[0:a]lowpass=f=16000,volume=0.5[l];[1:a]lowpass=f=16000,volume=0.5[r];[l][r]join=inputs=2:channel_layout=stereo[o]" \
    $(_noise white 11) $(_noise white 29)
}
gen_pink() {
  _emit "$1" "[0:a]volume=0.6[l];[1:a]volume=0.6[r];[l][r]join=inputs=2:channel_layout=stereo[o]" \
    $(_noise pink 11) $(_noise pink 29)
}
gen_brown() {
  _emit "$1" "[0:a]highpass=f=30,volume=0.9[l];[1:a]highpass=f=30,volume=0.9[r];[l][r]join=inputs=2:channel_layout=stereo[o]" \
    $(_noise brown 11) $(_noise brown 29)
}

# --- rain (warm wash + gated droplet patter) ----------------------------
gen_rain() {
  local BODY_HP BODY_LP AIR_LP PAT_F BODY_W AIR_W PAT_W MASTER_LP
  case "${INTENSITY:-medium}" in
    light) BODY_HP=90; BODY_LP=5000; AIR_LP=4600; PAT_F=1900; BODY_W=0.85; AIR_W=0.34; PAT_W=0.55; MASTER_LP=5000 ;;
    heavy) BODY_HP=42; BODY_LP=6200; AIR_LP=6400; PAT_F=1300; BODY_W=1.55; AIR_W=0.42; PAT_W=1.00; MASTER_LP=7000 ;;
    *)     BODY_HP=60; BODY_LP=5600; AIR_LP=5400; PAT_F=1600; BODY_W=1.20; AIR_W=0.38; PAT_W=0.78; MASTER_LP=6000 ;;
  esac
  local ch
  ch() { # brown_in pink_in label
    printf '[%s:a]highpass=f=%s,lowpass=f=%s,volume=%s[b%s];' "$1" "$BODY_HP" "$BODY_LP" "$BODY_W" "$3"
    printf '[%s:a]asplit=2[air%s][pat%s];' "$2" "$3" "$3"
    printf '[air%s]highpass=f=240,lowpass=f=%s,treble=f=3000:g=-7,volume=%s[a%s];' "$3" "$AIR_LP" "$AIR_W" "$3"
    printf '[pat%s]bandpass=f=%s:t=h:w=1900,compand=attacks=0.002:decays=0.06:points=-90/-118|-55/-80|-40/-46|-20/-17|0/-3,volume=%s[p%s];' "$3" "$PAT_F" "$PAT_W" "$3"
    printf '[b%s][a%s][p%s]amix=inputs=3:normalize=0,lowpass=f=%s[%s];' "$3" "$3" "$3" "$MASTER_LP" "$3"
  }
  local fc="$(ch 0 1 L)$(ch 2 3 R)[L][R]join=inputs=2:channel_layout=stereo[o]"
  _emit "$1" "$fc" $(_noise brown 11) $(_noise pink 29) $(_noise brown 71) $(_noise pink 97)
}

# --- ocean surf (low wash + slow wave swell) ----------------------------
gen_ocean() {
  local swell="tremolo=f=0.1:d=0.7,tremolo=f=0.133:d=0.4"   # two LFOs -> beating = natural surf
  local fc="\
    [0:a]lowpass=f=1600[bl];[1:a]highpass=f=600,lowpass=f=4500,volume=0.5[fl];[bl][fl]amix=inputs=2:normalize=0,${swell}[L];\
    [2:a]lowpass=f=1600[br];[3:a]highpass=f=600,lowpass=f=4500,volume=0.5[fr];[br][fr]amix=inputs=2:normalize=0,${swell}[R];\
    [L][R]join=inputs=2:channel_layout=stereo[o]"
  _emit "$1" "$fc" $(_noise brown 13) $(_noise pink 41) $(_noise brown 67) $(_noise pink 89)
}

# --- wind (band-limited howl + gusts) -----------------------------------
gen_wind() {
  local sh="highpass=f=100,lowpass=f=1000,equalizer=f=520:t=q:w=1.0:g=5,volume=0.9,tremolo=f=0.1:d=0.6,tremolo=f=0.15:d=0.5"
  _emit "$1" "[0:a]${sh}[l];[1:a]${sh}[r];[l][r]join=inputs=2:channel_layout=stereo[o]" \
    $(_noise brown 17) $(_noise brown 53)
}

# --- stream / creek (bright wash + dense burble) ------------------------
gen_stream() {
  local pat="bandpass=f=2500:t=h:w=2500,compand=attacks=0.001:decays=0.03:points=-90/-110|-50/-70|-35/-40|-15/-12|0/-3,volume=0.7"
  local fc="\
    [0:a]highpass=f=350,lowpass=f=6500,volume=0.7[wl];[2:a]${pat}[pl];[wl][pl]amix=inputs=2:normalize=0,tremolo=f=0.12:d=0.2[L];\
    [1:a]highpass=f=350,lowpass=f=6500,volume=0.7[wr];[3:a]${pat}[pr];[wr][pr]amix=inputs=2:normalize=0,tremolo=f=0.12:d=0.2[R];\
    [L][R]join=inputs=2:channel_layout=stereo[o]"
  _emit "$1" "$fc" $(_noise pink 11) $(_noise pink 29) $(_noise pink 43) $(_noise pink 61)
}

# --- waterfall (steady heavy roar) --------------------------------------
gen_waterfall() {
  local fc="\
    [0:a]highpass=f=200,lowpass=f=9000,volume=0.55[al];[1:a]lowpass=f=1200,volume=0.9[bl];[al][bl]amix=inputs=2:normalize=0[L];\
    [2:a]highpass=f=200,lowpass=f=9000,volume=0.55[ar];[3:a]lowpass=f=1200,volume=0.9[br];[ar][br]amix=inputs=2:normalize=0[R];\
    [L][R]join=inputs=2:channel_layout=stereo[o]"
  _emit "$1" "$fc" $(_noise pink 11) $(_noise brown 29) $(_noise pink 67) $(_noise brown 83)
}

# --- fan (warm steady airflow) ------------------------------------------
gen_fan() {
  local fc="\
    [0:a]lowpass=f=1000,volume=0.9[bl];[2:a]highpass=f=300,lowpass=f=2500,volume=0.22[hl];[bl][hl]amix=inputs=2:normalize=0[L];\
    [1:a]lowpass=f=1000,volume=0.9[br];[3:a]highpass=f=300,lowpass=f=2500,volume=0.22[hr];[br][hr]amix=inputs=2:normalize=0[R];\
    [L][R]join=inputs=2:channel_layout=stereo[o]"
  _emit "$1" "$fc" $(_noise brown 11) $(_noise brown 29) $(_noise pink 41) $(_noise pink 53)
}

# --- airplane cabin (warm broadband drone) ------------------------------
gen_airplane() {
  local fc="\
    [0:a]highpass=f=45,lowpass=f=1900,volume=0.9[bl];[2:a]highpass=f=250,lowpass=f=3500,volume=0.18[hl];[bl][hl]amix=inputs=2:normalize=0[L];\
    [1:a]highpass=f=45,lowpass=f=1900,volume=0.9[br];[3:a]highpass=f=250,lowpass=f=3500,volume=0.18[hr];[br][hr]amix=inputs=2:normalize=0[R];\
    [L][R]join=inputs=2:channel_layout=stereo[o]"
  _emit "$1" "$fc" $(_noise brown 11) $(_noise brown 29) $(_noise pink 41) $(_noise pink 53)
}

# --- fireplace / campfire (low roar + sparse crackle) -------------------
gen_fireplace() {
  local crack="highpass=f=1500,lowpass=f=7000,compand=attacks=0:decays=0.02:points=-90/-120|-45/-78|-32/-46|-12/-10|0/-2,volume=0.9"
  local fc="\
    [0:a]lowpass=f=700,volume=0.8[rl];[1:a]${crack}[cl];[rl][cl]amix=inputs=2:normalize=0[L];\
    [2:a]lowpass=f=700,volume=0.8[rr];[3:a]${crack}[cr];[rr][cr]amix=inputs=2:normalize=0[R];\
    [L][R]join=inputs=2:channel_layout=stereo[o]"
  _emit "$1" "$fc" $(_noise brown 11) $(_noise pink 41) $(_noise brown 29) $(_noise pink 53)
}

# --- distant thunder (continuous rolling rumble; loop-safe, no claps) ----
gen_thunder() {
  local sh="lowpass=f=110,volume=0.9,tremolo=f=0.12:d=0.8"
  _emit "$1" "[0:a]${sh}[l];[1:a]${sh}[r];[l][r]join=inputs=2:channel_layout=stereo[o]" \
    $(_noise brown 5) $(_noise brown 23)
}

# list of everything above, for help text / validation
SOUND_TYPES="white pink brown rain ocean wind stream waterfall fan airplane fireplace thunder"
