# sync.sh — auto-sync $PROJECT_FILE to external MCP clients (Codex today).
#
# External configs are edited in-place using fenced block markers, so only
# the mcpx-managed region is touched. User-added content is preserved.

# BEGIN/END markers that delimit mcpx-managed regions in external configs.
BEGIN_MARKER="# BEGIN MCPX MANAGED MCP SERVERS"
END_MARKER="# END MCPX MANAGED MCP SERVERS"

# Legacy markers from the `mcpy` era — still recognized for migration.
OLD_BEGIN_MARKER="# BEGIN MCPY MANAGED MCP SERVERS"
OLD_END_MARKER="# END MCPY MANAGED MCP SERVERS"

# sync_enabled <target> → exit 0 iff auto-sync is turned on for <target>.
sync_enabled() {
  [[ -f "$CONFIG_FILE" ]] \
    && jq -e --arg t "$1" '.sync[$t] == true' "$CONFIG_FILE" &>/dev/null
}

# remove_managed_block <in-file> <out-file>
# Copies <in-file> → <out-file> with any mcpx/mcpy-managed block stripped.
remove_managed_block() {
  local file="$1" output="$2"
  awk -v b1="$BEGIN_MARKER" -v e1="$END_MARKER" \
      -v b2="$OLD_BEGIN_MARKER" -v e2="$OLD_END_MARKER" '
    ($0 == b1 || $0 == b2) { skip = 1; next }
    ($0 == e1 || $0 == e2) { skip = 0; next }
    skip != 1 { print }
  ' "$file" > "$output"
}

# generate_codex_toml → TOML block (to stdout) reflecting $PROJECT_FILE.
# Empty output if no project file or no servers.
generate_codex_toml() {
  [[ -f "$PROJECT_FILE" ]] || return 0
  local count
  count=$(jq '.mcpServers | length' "$PROJECT_FILE")
  [[ "$count" -gt 0 ]] || return 0

  echo ""
  echo "$BEGIN_MARKER"
  jq -r '
    .mcpServers | to_entries[] |
    "[mcp_servers.\"" + .key + "\"]\nurl = \"" + .value.url + "\"\n"
  ' "$PROJECT_FILE"
  echo "$END_MARKER"
}

sync_codex() {
  local codex_config="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
  if [[ ! -f "$codex_config" ]]; then
    dim "codex config not found: $codex_config (skipped)"
    return
  fi
  [[ -f "$PROJECT_FILE" ]] || return

  local tmp
  tmp=$(mktemp)
  remove_managed_block "$codex_config" "$tmp"
  generate_codex_toml >> "$tmp"
  mv "$tmp" "$codex_config"

  local count
  count=$(jq '.mcpServers | length' "$PROJECT_FILE")
  echo -e "  ${D}codex${N} ${G}synced${N} ${D}(${count} MCPs → $codex_config)${N}"
}

# auto_sync → run every enabled sync target.
auto_sync() {
  sync_enabled "codex" && sync_codex
  # Future: cursor, windsurf, etc.
  return 0
}

# --- commands -------------------------------------------------------------

cmd_sync_status() {
  [[ -f "$CONFIG_FILE" ]] || die "not initialized — run: mcpx init"
  echo -e "${B}sync targets${N}"

  local targets
  targets=$(jq -r '.sync // {} | to_entries[] | "\(.key) \(.value)"' "$CONFIG_FILE" 2>/dev/null)
  if [[ -z "$targets" ]]; then
    dim "  (none configured)"
    dim "  use: mcpx sync codex true"
    return
  fi

  while read -r name enabled; do
    if [[ "$enabled" == "true" ]]; then
      echo -e "  ${G}*${N} ${C}${name}${N} ${G}on${N}"
    else
      echo -e "    ${name} ${R}off${N}"
    fi
  done <<<"$targets"
}

cmd_sync_set() {
  [[ -f "$CONFIG_FILE" ]] || die "not initialized — run: mcpx init"
  local target="$1" raw="$2" value
  case "$raw" in
    true|on|1|yes)   value=true ;;
    false|off|0|no)  value=false ;;
    *)               die "usage: mcpx sync <target> true|false" ;;
  esac

  json_update "$CONFIG_FILE" --arg t "$target" --argjson v "$value" \
    '.sync = (.sync // {}) | .sync[$t] = $v'

  if [[ "$value" == "true" ]]; then
    info "sync ${target} enabled"
  else
    warn "sync ${target} disabled"
  fi
}
