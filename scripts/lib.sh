# shellcheck shell=bash
# Shared helpers for the rain-sounds pipeline.
# Sourced by the other scripts; not meant to be run directly.

set -euo pipefail

# --- paths --------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$ROOT_DIR/config/project.json}"
BUILD_DIR="$ROOT_DIR/build"
OUTPUT_DIR="$ROOT_DIR/output"
ASSETS_DIR="$ROOT_DIR/assets"

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR" "$ASSETS_DIR"

# --- logging ------------------------------------------------------------
log()  { printf '\033[36m[rain]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[rain] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[rain] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- dependency checks --------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

check_deps() {
  need ffmpeg
  need ffprobe
  need python3
}

# --- config access ------------------------------------------------------
# cfg <dotted.key.path> [default]
# Reads a value out of config/project.json. Fails if the key is missing and
# no default is supplied, so typos surface immediately instead of silently
# producing empty strings.
cfg() {
  local key="$1"; shift || true
  local default="${1-__NO_DEFAULT__}"
  CONFIG_FILE="$CONFIG_FILE" KEY="$key" DEFAULT="$default" python3 - <<'PY'
import json, os, sys
key = os.environ["KEY"]
default = os.environ["DEFAULT"]
with open(os.environ["CONFIG_FILE"]) as fh:
    data = json.load(fh)
cur = data
for part in key.split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        if default == "__NO_DEFAULT__":
            sys.stderr.write(f"config key not found: {key}\n")
            sys.exit(3)
        print(default)
        sys.exit(0)
if isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
PY
}

# fresh <output> <input...> : true (exit 0) if <output> exists and is newer
# than every input, so stages can skip expensive work that is already done.
# Set FORCE=1 to always rebuild.
fresh() {
  local out="$1"; shift
  [[ "${FORCE:-0}" == "1" ]] && return 1
  [[ -f "$out" ]] || return 1
  local dep
  for dep in "$@"; do
    [[ -e "$dep" ]] || continue
    [[ "$dep" -nt "$out" ]] && return 1
  done
  return 0
}

# human-readable duration for logs
hms() {
  local s="$1"
  printf '%dh%02dm%02ds' $((s/3600)) $(((s%3600)/60)) $((s%60))
}
