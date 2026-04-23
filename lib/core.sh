# core.sh — constants, colors, and shared helpers used by every module.
#
# Naming conventions used across lib/:
#   *_FILE          absolute path to a JSON state file
#   cmd_<name>      top-level command invoked from the main dispatcher
#   ensure_<thing>  precondition check (dies or creates on demand)
#   _<name>         file-private helper (not intended for cross-module use)

VERSION="0.4.0"

# --- paths ----------------------------------------------------------------

CONFIG_DIR="${MCPX_CONFIG_DIR:-$HOME/.config/mcpx}"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CATALOG_FILE="${CONFIG_DIR}/catalog.json"
PROFILES_FILE="${CONFIG_DIR}/profiles.json"
OVERRIDES_FILE="${CONFIG_DIR}/overrides.json"

# The per-project config that `mcpx` reads/writes in $PWD.
PROJECT_FILE=".mcp.json"

# --- colors (ANSI) --------------------------------------------------------
# Short names are deliberate: they keep interpolated output readable.
# Semantic mapping:
#   R = error    G = success    Y = warning
#   C = name/id  B = bold       D = dim/secondary    N = reset

R='\033[0;31m'  G='\033[0;32m'  Y='\033[0;33m'
C='\033[0;36m'  B='\033[1m'     D='\033[0;90m'
N='\033[0m'

# --- user-facing messaging -----------------------------------------------

die()  { echo -e "${R}error:${N} $1" >&2; exit 1; }
info() { echo -e "${G}+${N} $1"; }
warn() { echo -e "${Y}~${N} $1"; }
dim()  { echo -e "${D}$1${N}"; }

# --- filesystem helpers ---------------------------------------------------

ensure_config_dir() {
  [[ -d "$CONFIG_DIR" ]] || mkdir -p "$CONFIG_DIR"
}

ensure_catalog() {
  [[ -f "$CATALOG_FILE" ]] || die "no catalog — run: mcpx init"
}

# ensure_json_file <path> [<default='{}'>]
# Guarantees the file exists and contains valid JSON (or the supplied default).
ensure_json_file() {
  local path="$1" default="${2-}"
  [[ -z "$default" ]] && default='{}'
  ensure_config_dir
  [[ -f "$path" ]] || printf '%s\n' "$default" > "$path"
}

# json_update <file> <jq-args...>
# Atomic write: jq filter → tmp → mv. Fails safely if jq errors.
json_update() {
  local file="$1"; shift
  jq "$@" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# --- URL helpers ----------------------------------------------------------

# url_port <url> → the numeric port embedded in `://host:PORT/...`, or ''.
url_port() {
  local url="$1"
  [[ "$url" =~ :([0-9]+)(/|$) ]] && echo "${BASH_REMATCH[1]}"
}

# build_mcp_url <host> <port> → canonical MCP endpoint URL.
build_mcp_url() {
  echo "http://$1:$2/mcp"
}

# --- tempdir with trap cleanup -------------------------------------------
# Usage:
#   local td; td=$(make_tempdir)
#   # ... work under "$td" ...
# The directory is cleaned up automatically when the shell exits (EXIT trap).
_MCPX_TEMPDIRS=()
_mcpx_cleanup_tempdirs() {
  # ${arr[@]+...} is set-u-safe even when the array is empty.
  local d
  for d in ${_MCPX_TEMPDIRS[@]+"${_MCPX_TEMPDIRS[@]}"}; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap _mcpx_cleanup_tempdirs EXIT

make_tempdir() {
  local td
  td=$(mktemp -d)
  _MCPX_TEMPDIRS+=("$td")
  echo "$td"
}
