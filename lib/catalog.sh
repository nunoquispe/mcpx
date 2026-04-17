# catalog.sh — show, list, add, remove, clean, catalog modify

cmd_show() {
  if [[ ! -f "$TARGET" ]]; then
    dim "no $TARGET in $(pwd)"
    return
  fi
  local keys
  keys=$(jq -r '.mcpServers | keys[]' "$TARGET" 2>/dev/null)
  if [[ -z "$keys" ]]; then
    dim "(empty)"
    return
  fi
  local count
  count=$(echo "$keys" | wc -l | tr -d ' ')
  echo -e "${B}${TARGET}${N} ${D}(${count})${N}"
  echo "$keys" | while read -r k; do
    local url port
    url=$(jq -r ".mcpServers[\"$k\"].url" "$TARGET")
    port=$(echo "$url" | grep -oE ':[0-9]+/' | tr -d ':/')
    echo -e "  ${C}${k}${N} ${D}:${port}${N}"
  done
}

cmd_list() {
  ensure_catalog
  local active=""
  if [[ -f "$TARGET" ]]; then
    active=$(jq -r '.mcpServers | keys[]' "$TARGET" 2>/dev/null || true)
  fi
  local total
  total=$(jq '.mcpServers | length' "$CATALOG")
  echo -e "${B}catalog${N} ${D}(${total})${N}"
  catalog_names | while read -r name; do
    local port
    port=$(jq -r ".mcpServers[\"$name\"].url" "$CATALOG" | grep -oE ':[0-9]+/' | tr -d ':/')
    if echo "$active" | grep -qx "$name"; then
      echo -e "  ${G}*${N} ${C}${name}${N} ${D}:${port}${N}"
    else
      echo -e "    ${name} ${D}:${port}${N}"
    fi
  done
}

cmd_add_single() {
  ensure_catalog
  local name="$1"
  local resolved
  resolved=$(fuzzy_match "$name") || return 1

  if [[ ! -f "$TARGET" ]]; then
    echo '{"mcpServers":{}}' > "$TARGET"
  fi

  if jq -e ".mcpServers[\"$resolved\"]" "$TARGET" &>/dev/null; then
    warn "${resolved} already in config"
    return 0
  fi

  local entry
  entry=$(jq ".mcpServers[\"$resolved\"]" "$CATALOG")
  json_update "$TARGET" --arg k "$resolved" --argjson v "$entry" '.mcpServers[$k] = $v'
  info "${resolved}"
}

cmd_rm_single() {
  local name="$1"
  [[ -f "$TARGET" ]] || die "no $TARGET in current directory"

  local resolved
  resolved=$(fuzzy_match_current "$name") || return 1

  json_update "$TARGET" --arg k "$resolved" 'del(.mcpServers[$k])'
  echo -e "${R}-${N} ${resolved}"
}

# Add: profile-aware (checks profiles first, then catalog)
cmd_add() {
  local name="$1"
  if is_profile "$name"; then
    dim "profile: ${name}"
    jq -r --arg n "$name" '.[$n][]' "$PROFILES" | while read -r m; do
      cmd_add_single "$m"
    done
  else
    cmd_add_single "$name"
  fi
}

# Remove: profile-aware
cmd_rm() {
  local name="$1"
  if is_profile "$name"; then
    dim "profile: ${name}"
    jq -r --arg n "$name" '.[$n][]' "$PROFILES" | while read -r m; do
      cmd_rm_single "$m" 2>/dev/null || true
    done
  else
    cmd_rm_single "$name"
  fi
}

cmd_clean() {
  echo '{"mcpServers":{}}' > "$TARGET"
  info "cleaned $TARGET"
  auto_sync
}

cmd_catalog_mod() {
  ensure_catalog
  local name="$1"
  local port="${2:-}"

  load_host

  if [[ -z "$port" ]]; then
    if ! jq -e ".mcpServers[\"$name\"]" "$CATALOG" &>/dev/null; then
      echo -e "${R}not in catalog:${N} $name" >&2
      return 1
    fi
    json_update "$CATALOG" --arg k "$name" 'del(.mcpServers[$k])'
    echo -e "${R}-${N} ${name} ${D}(removed from catalog)${N}"
  else
    local url="http://${MCP_HOST}:${port}/mcp"
    if jq -e ".mcpServers[\"$name\"]" "$CATALOG" &>/dev/null; then
      local old_port
      old_port=$(jq -r ".mcpServers[\"$name\"].url" "$CATALOG" | grep -oE ':[0-9]+/' | tr -d ':/')
      if [[ "$old_port" == "$port" ]]; then
        warn "${name} already in catalog at :${port}"
        return 0
      fi
      json_update "$CATALOG" --arg k "$name" --arg u "$url" '.mcpServers[$k].url = $u'
      echo -e "${Y}~${N} ${name} ${D}:${old_port} → :${port}${N}"
    else
      json_update "$CATALOG" --arg k "$name" --arg u "$url" '.mcpServers[$k] = {"type":"http","url":$u}'
      info "${name} ${D}:${port} → catalog${N}"
    fi
  fi
}
