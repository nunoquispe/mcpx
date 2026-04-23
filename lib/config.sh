# config.sh — init, host registry, and host loading.
#
# load_host populates these globals (consumed by scan.sh and overrides.sh):
#   HOST_NAME       the configured host key
#   HOST_ADDR       the IP/hostname to dial
#   HOST_PORT_MIN   inclusive start of the scan range
#   HOST_PORT_MAX   inclusive end of the scan range

# load_host [<host-name>]
# Resolves a host from $CONFIG_FILE. With no arg, uses .default_host.
load_host() {
  [[ -f "$CONFIG_FILE" ]] || die "not initialized — run: mcpx init"

  local host="${1:-}"
  if [[ -z "$host" ]]; then
    host=$(jq -r '.default_host // empty' "$CONFIG_FILE")
    [[ -n "$host" ]] || die "no default_host in config"
  fi

  HOST_ADDR=$(jq -r --arg h "$host" '.hosts[$h].address // empty' "$CONFIG_FILE")
  [[ -n "$HOST_ADDR" ]] || die "host '$host' not found in config"

  HOST_PORT_MIN=$(jq -r --arg h "$host" '.hosts[$h].port_min // 3200' "$CONFIG_FILE")
  HOST_PORT_MAX=$(jq -r --arg h "$host" '.hosts[$h].port_max // 3250' "$CONFIG_FILE")
  HOST_NAME="$host"
}

# --- commands -------------------------------------------------------------

cmd_init() {
  ensure_config_dir

  if [[ -f "$CONFIG_FILE" ]]; then
    warn "config already exists: $CONFIG_FILE"
    read -rp "Overwrite? [y/N] " ans
    [[ "$ans" =~ ^[yY]$ ]] || exit 0
  fi

  echo -e "${B}mcpx init${N}"
  echo ""

  local host_name host_addr port_min port_max sync_codex="false"

  read -rp "Host name (e.g. mini, server, local): " host_name
  [[ -n "$host_name" ]] || die "host name required"

  read -rp "Host address (IP or hostname): " host_addr
  [[ -n "$host_addr" ]] || die "address required"

  read -rp "Port range start [3200]: " port_min
  port_min="${port_min:-3200}"

  read -rp "Port range end [3250]: " port_max
  port_max="${port_max:-3250}"

  # Offer Codex sync only if Codex is actually installed/configured.
  if command -v codex &>/dev/null || [[ -f "$HOME/.codex/config.toml" ]]; then
    local ans
    read -rp "Sync to Codex (~/.codex/config.toml)? [Y/n]: " ans
    [[ "$ans" =~ ^[nN]$ ]] || sync_codex="true"
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

  if [[ ! -f "$CATALOG_FILE" ]]; then
    echo '{"mcpServers":{}}' > "$CATALOG_FILE"
    info "created empty catalog"
  fi

  info "config saved to $CONFIG_FILE"
  echo ""
  dim "next: mcpx scan — discover live MCPs"
  dim "  or: mcpx @my-server 3201 — add to catalog manually"
}

cmd_hosts() {
  [[ -f "$CONFIG_FILE" ]] || die "not initialized — run: mcpx init"

  local default
  default=$(jq -r '.default_host // ""' "$CONFIG_FILE")

  echo -e "${B}hosts${N}"
  jq -r '.hosts | to_entries[] | "\(.key) \(.value.address) \(.value.port_min) \(.value.port_max)"' "$CONFIG_FILE" \
    | while read -r name addr pmin pmax; do
        if [[ "$name" == "$default" ]]; then
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
    --arg  h    "$name" \
    --arg  a    "$addr" \
    --argjson pmin "$pmin" \
    --argjson pmax "$pmax" \
    '.hosts[$h] = {address: $a, port_min: $pmin, port_max: $pmax}'

  if jq -e --arg h "$name" '.hosts[$h]' "$CONFIG_FILE" &>/dev/null; then
    info "host ${name} (${addr})"
  fi
}
