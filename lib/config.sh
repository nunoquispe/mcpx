# config.sh — init, hosts, load_host

load_host() {
  local host_name="${1:-}"
  [[ -f "$CONFIG_FILE" ]] || die "not initialized — run: mcpx init"
  if [[ -z "$host_name" ]]; then
    host_name=$(jq -r '.default_host // empty' "$CONFIG_FILE")
    [[ -n "$host_name" ]] || die "no default_host in config"
  fi
  MCP_HOST=$(jq -r --arg h "$host_name" '.hosts[$h].address // empty' "$CONFIG_FILE")
  [[ -n "$MCP_HOST" ]] || die "host '$host_name' not found in config"
  PORT_MIN=$(jq -r --arg h "$host_name" '.hosts[$h].port_min // 3200' "$CONFIG_FILE")
  PORT_MAX=$(jq -r --arg h "$host_name" '.hosts[$h].port_max // 3250' "$CONFIG_FILE")
  CURRENT_HOST="$host_name"
}

cmd_init() {
  ensure_config_dir

  if [[ -f "$CONFIG_FILE" ]]; then
    warn "config already exists: $CONFIG_FILE"
    read -rp "Overwrite? [y/N] " ans
    [[ "$ans" =~ ^[yY]$ ]] || exit 0
  fi

  echo -e "${B}mcpx init${N}"
  echo ""

  read -rp "Host name (e.g. mini, server, local): " host_name
  [[ -n "$host_name" ]] || die "host name required"

  read -rp "Host address (IP or hostname): " host_addr
  [[ -n "$host_addr" ]] || die "address required"

  read -rp "Port range start [3200]: " port_min
  port_min="${port_min:-3200}"

  read -rp "Port range end [3250]: " port_max
  port_max="${port_max:-3250}"

  # Sync targets
  local sync_codex="false"
  if command -v codex &>/dev/null || [[ -f "$HOME/.codex/config.toml" ]]; then
    read -rp "Sync to Codex (~/.codex/config.toml)? [Y/n]: " ans_codex
    [[ "$ans_codex" =~ ^[nN]$ ]] || sync_codex="true"
  fi

  cat > "$CONFIG_FILE" <<EOF
{
  "default_host": "${host_name}",
  "hosts": {
    "${host_name}": {
      "address": "${host_addr}",
      "port_min": ${port_min},
      "port_max": ${port_max}
    }
  },
  "sync": {
    "codex": ${sync_codex}
  }
}
EOF

  if [[ ! -f "$CATALOG" ]]; then
    echo '{"mcpServers":{}}' > "$CATALOG"
    info "created empty catalog"
  fi

  info "config saved to $CONFIG_FILE"
  echo ""
  dim "next: mcpx scan — discover live MCPs"
  dim "  or: mcpx @my-server 3201 — add to catalog manually"
}

cmd_hosts() {
  [[ -f "$CONFIG_FILE" ]] || die "not initialized — run: mcpx init"
  local default_host
  default_host=$(jq -r '.default_host // ""' "$CONFIG_FILE")
  echo -e "${B}hosts${N}"
  jq -r '.hosts | to_entries[] | "\(.key) \(.value.address) \(.value.port_min) \(.value.port_max)"' "$CONFIG_FILE" \
    | while read -r name addr pmin pmax; do
      if [[ "$name" == "$default_host" ]]; then
        echo -e "  ${G}*${N} ${C}${name}${N} ${D}${addr} :${pmin}-${pmax}${N}"
      else
        echo -e "    ${name} ${D}${addr} :${pmin}-${pmax}${N}"
      fi
    done
}

cmd_host_add() {
  [[ -f "$CONFIG_FILE" ]] || die "not initialized — run: mcpx init"
  local name="$1" addr="$2" pmin="${3:-3200}" pmax="${4:-3250}"

  json_update "$CONFIG_FILE" \
    --arg h "$name" --arg a "$addr" --argjson pmin "$pmin" --argjson pmax "$pmax" \
    '.hosts[$h] = {address:$a, port_min:$pmin, port_max:$pmax}'

  if jq -e --arg h "$name" '.hosts[$h]' "$CONFIG_FILE" &>/dev/null; then
    info "host ${name} (${addr})"
  fi
}
