# sync.sh — auto-sync to external clients (Codex, etc.)

BEGIN_MARKER="# BEGIN MCPX MANAGED MCP SERVERS"
END_MARKER="# END MCPX MANAGED MCP SERVERS"
OLD_BEGIN_MARKER="# BEGIN MCPY MANAGED MCP SERVERS"
OLD_END_MARKER="# END MCPY MANAGED MCP SERVERS"

sync_enabled() {
  local target="$1"
  [[ -f "$CONFIG_FILE" ]] && jq -e --arg t "$target" '.sync[$t] == true' "$CONFIG_FILE" &>/dev/null
}

remove_managed_block() {
  local file="$1" output="$2"
  awk -v b1="$BEGIN_MARKER" -v e1="$END_MARKER" \
      -v b2="$OLD_BEGIN_MARKER" -v e2="$OLD_END_MARKER" '
    ($0 == b1 || $0 == b2) { skip = 1; next }
    ($0 == e1 || $0 == e2) { skip = 0; next }
    skip != 1 { print }
  ' "$file" > "$output"
}

generate_codex_toml() {
  [[ -f "$TARGET" ]] || return 0
  local count
  count=$(jq '.mcpServers | length' "$TARGET")
  [[ "$count" -gt 0 ]] || return 0

  echo ""
  echo "$BEGIN_MARKER"
  jq -r '
    .mcpServers | to_entries[] |
    "[mcp_servers.\"" + .key + "\"]\nurl = \"" + .value.url + "\"\n"
  ' "$TARGET"
  echo "$END_MARKER"
}

sync_codex() {
  local codex_config="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
  if [[ ! -f "$codex_config" ]]; then
    dim "codex config not found: $codex_config (skipped)"
    return
  fi
  [[ -f "$TARGET" ]] || return

  local stripped tmp
  stripped=$(mktemp)
  tmp=$(mktemp)

  remove_managed_block "$codex_config" "$stripped"
  cp "$stripped" "$tmp"
  generate_codex_toml >> "$tmp"

  mv "$tmp" "$codex_config"
  rm -f "$stripped"

  local count
  count=$(jq '.mcpServers | length' "$TARGET")
  echo -e "  ${D}codex${N} ${G}synced${N} ${D}(${count} MCPs → $codex_config)${N}"
}

auto_sync() {
  if sync_enabled "codex"; then
    sync_codex
  fi
  # Future: cursor, windsurf, etc.
}

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
  echo "$targets" | while read -r name enabled; do
    if [[ "$enabled" == "true" ]]; then
      echo -e "  ${G}*${N} ${C}${name}${N} ${G}on${N}"
    else
      echo -e "    ${name} ${R}off${N}"
    fi
  done
}

cmd_sync_set() {
  [[ -f "$CONFIG_FILE" ]] || die "not initialized — run: mcpx init"
  local target="$1" value="$2"
  case "$value" in
    true|on|1|yes)   value=true ;;
    false|off|0|no)  value=false ;;
    *)               die "usage: mcpx sync <target> true|false" ;;
  esac

  jq --arg t "$target" --argjson v "$value" \
    '.sync = (.sync // {}) | .sync[$t] = $v' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
    && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

  if [[ "$value" == "true" ]]; then
    info "sync ${target} enabled"
  else
    warn "sync ${target} disabled"
  fi
}
