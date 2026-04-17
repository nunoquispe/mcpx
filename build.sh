#!/usr/bin/env bash
# Assembles lib/*.sh into a single distributable mcpx script
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${SCRIPT_DIR}/mcpx"

# Module load order matters (dependencies first)
MODULES=(
  lib/core.sh
  lib/fuzzy.sh
  lib/sync.sh
  lib/config.sh
  lib/profiles.sh
  lib/catalog.sh
  lib/scan.sh
)

{
  cat <<'HEADER'
#!/usr/bin/env bash
# mcpx — fast MCP config manager for .mcp.json
# https://github.com/nunoquispe/mcpx
#
# Usage:
#   mcpx                     show current .mcp.json
#   mcpx ls                  list catalog (marks active with *)
#   mcpx +pg +ssh-d          add MCPs (fuzzy match)
#   mcpx -pg                 remove MCP (fuzzy match)
#   mcpx +pg -hana           mix add/remove in one shot
#   mcpx 0                   truncate .mcp.json to empty
#   mcpx @name 3240          add/update entry in catalog
#   mcpx @name               remove entry from catalog
#   mcpx :save dev pg ssh-d  save profile
#   mcpx +dev / -dev         add/remove profile MCPs
#   mcpx scan [host]         scan host ports for live MCPs
#   mcpx init                initialize config
#   mcpx hosts               list configured hosts
#   mcpx sync                show/set sync targets

set -euo pipefail

HEADER

  # Embed each module with a section header
  for mod in "${MODULES[@]}"; do
    local_path="${SCRIPT_DIR}/${mod}"
    echo ""
    echo "# ============================================================"
    echo "# ${mod}"
    echo "# ============================================================"
    echo ""
    # Strip the first comment line (file description) to avoid duplication
    tail -n +2 "$local_path"
  done

  # Append the main routing
  cat <<'MAIN'

# ============================================================
# main — command routing
# ============================================================

cmd_help() {
  cat <<'HELP'
mcpx — fast MCP config manager

Usage:
  mcpx                     show current .mcp.json
  mcpx ls                  list catalog (* = active in .mcp.json)
  mcpx +name               add MCP to .mcp.json (fuzzy match)
  mcpx -name               remove MCP from .mcp.json (fuzzy match)
  mcpx +a +b -c            mix add/remove in one shot
  mcpx 0                   truncate .mcp.json

Profiles:
  mcpx :save dev pg ssh-d  save profile "dev" with MCPs
  mcpx :ls                 list profiles
  mcpx :rm dev             delete profile
  mcpx +dev                add all MCPs in profile (auto-detected)
  mcpx -dev                remove all MCPs in profile

Catalog:
  mcpx @name port          add/update MCP in catalog
  mcpx @name               remove MCP from catalog

Discovery:
  mcpx scan [host]         scan host ports for live MCPs
  mcpx hosts               list configured hosts

Sync:
  mcpx sync                show sync targets status
  mcpx sync codex true     enable auto-sync to Codex
  mcpx sync codex false    disable auto-sync to Codex

Setup:
  mcpx init                initialize config (~/.config/mcpx/)
  mcpx -v, --version       show version
  mcpx -h, --help          show this help

Fuzzy matching:
  "pg"    → pg-enterprise
  "ssh-d" → ssh-dev
  "duck"  → duckdb-files-enterprise

Environment:
  MCPX_CONFIG_DIR          override config dir (default: ~/.config/mcpx)
HELP
}

cmd_version() {
  echo "mcpx ${VERSION}"
}

# No args: show current config
if [[ $# -eq 0 ]]; then
  cmd_show
  exit 0
fi

# Named commands
case "$1" in
  -v|--version|version)  cmd_version; exit 0 ;;
  -h|--help|help)        cmd_help; exit 0 ;;
  init)                  cmd_init; exit 0 ;;
  hosts)                 cmd_hosts; exit 0 ;;
  "?"|ls|list)           cmd_list; exit 0 ;;
  0|clean)               cmd_clean; exit 0 ;;
  scan)                  cmd_scan "${2:-}"; exit 0 ;;
  sync)
    if [[ $# -ge 3 ]]; then
      cmd_sync_set "$2" "$3"; exit 0
    else
      cmd_sync_status; exit 0
    fi
    ;;
  host)
    shift
    case "${1:-}" in
      add)  cmd_host_add "$2" "$3" "${4:-3200}" "${5:-3250}"; exit 0 ;;
      *)    cmd_hosts; exit 0 ;;
    esac
    ;;
esac

# : commands — profile management
if [[ "$1" == :* ]]; then
  subcmd="${1:1}"
  shift
  case "$subcmd" in
    save|s)  cmd_profile_save "$@"; exit $? ;;
    ls|list) cmd_profile_ls; exit 0 ;;
    rm)      cmd_profile_rm "$1"; exit $? ;;
    *)       die "unknown: :$subcmd (use :save, :ls, :rm)" ;;
  esac
fi

# @ commands — catalog management
if [[ "$1" == @* ]]; then
  name="${1:1}"
  [[ -n "$name" ]] || die "usage: mcpx @name [port]"
  cmd_catalog_mod "$name" "${2:-}"
  exit $?
fi

# +/- operations
errors=0
for arg in "$@"; do
  case "$arg" in
    +*)  cmd_add "${arg:1}" || errors=$((errors + 1)) ;;
    -*)  cmd_rm "${arg:1}" || errors=$((errors + 1)) ;;
    *)   warn "unknown: $arg (try: mcpx --help)"; errors=$((errors + 1)) ;;
  esac
done

if [[ $errors -lt $# ]]; then
  echo ""
  cmd_show
  auto_sync
fi

exit $errors
MAIN

} > "$OUT"

chmod +x "$OUT"

# Show stats
total=$(wc -l < "$OUT" | tr -d ' ')
echo "built: mcpx (${total} lines, $(du -h "$OUT" | cut -f1))"
echo "modules: ${#MODULES[@]}"
for mod in "${MODULES[@]}"; do
  lines=$(wc -l < "${SCRIPT_DIR}/${mod}" | tr -d ' ')
  printf "  %-20s %s lines\n" "$mod" "$lines"
done
