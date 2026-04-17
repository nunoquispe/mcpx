# core.sh — constants, colors, helpers

VERSION="0.3.0"
CONFIG_DIR="${MCPX_CONFIG_DIR:-$HOME/.config/mcpx}"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CATALOG="${CONFIG_DIR}/catalog.json"
PROFILES="${CONFIG_DIR}/profiles.json"
TARGET=".mcp.json"

# Colors
R='\033[0;31m'  G='\033[0;32m'  Y='\033[0;33m'
C='\033[0;36m'  B='\033[1m'     D='\033[0;90m'
N='\033[0m'

die()  { echo -e "${R}error:${N} $1" >&2; exit 1; }
info() { echo -e "${G}+${N} $1"; }
warn() { echo -e "${Y}~${N} $1"; }
dim()  { echo -e "${D}$1${N}"; }

ensure_config_dir() {
  [[ -d "$CONFIG_DIR" ]] || mkdir -p "$CONFIG_DIR"
}

ensure_catalog() {
  [[ -f "$CATALOG" ]] || die "no catalog — run: mcpx init"
}

ensure_profiles() {
  ensure_config_dir
  [[ -f "$PROFILES" ]] || echo '{}' > "$PROFILES"
}

# Safe JSON file update: write to tmp then move
json_update() {
  local file="$1"
  shift
  jq "$@" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}
