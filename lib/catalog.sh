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
    local url port marker=""
    url=$(jq -r ".mcpServers[\"$k\"].url" "$TARGET")
    port=$(echo "$url" | grep -oE ':[0-9]+/' | tr -d ':/')
    if has_override "$k"; then
      marker=" ${Y}!${N}"
    fi
    echo -e "  ${C}${k}${N} ${D}:${port}${N}${marker}"
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
    local port marker=""
    port=$(jq -r ".mcpServers[\"$name\"].url" "$CATALOG" | grep -oE ':[0-9]+/' | tr -d ':/')
    if has_override "$name"; then
      local ov_url
      ov_url=$(override_url "$name")
      marker=" ${Y}!→${N} ${D}${ov_url}${N}"
    fi
    if echo "$active" | grep -qx "$name"; then
      echo -e "  ${G}*${N} ${C}${name}${N} ${D}:${port}${N}${marker}"
    else
      echo -e "    ${name} ${D}:${port}${N}${marker}"
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
  # Apply URL override if present
  if has_override "$resolved"; then
    local ov_url
    ov_url=$(override_url "$resolved")
    entry=$(echo "$entry" | jq --arg u "$ov_url" '.url = $u')
    json_update "$TARGET" --arg k "$resolved" --argjson v "$entry" '.mcpServers[$k] = $v'
    info "${resolved} ${Y}!${N} ${D}${ov_url}${N}"
  else
    json_update "$TARGET" --arg k "$resolved" --argjson v "$entry" '.mcpServers[$k] = $v'
    info "${resolved}"
  fi
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

# cmd_refresh [--walk DIR] [--dry-run] [--no-backup]
# Rewrites URLs in .mcp.json file(s) to match resolve_url (override-first, catalog-fallback).
# Only touches entries whose name is in the catalog; unknown entries are left alone.
# Default: CWD only. --walk walks a directory tree (skips +archives, node_modules, .git).
cmd_refresh() {
  ensure_catalog
  local dry_run=0 walk_dir="" no_backup=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)    dry_run=1 ;;
      --walk)       walk_dir="${2:-}"; [[ -n "$walk_dir" ]] || die "--walk requires a directory"; shift ;;
      --no-backup)  no_backup=1 ;;
      *)            die "unknown flag: $1 (use --walk DIR, --dry-run, --no-backup)" ;;
    esac
    shift
  done

  local files=()
  if [[ -n "$walk_dir" ]]; then
    [[ -d "$walk_dir" ]] || die "not a directory: $walk_dir"
    while IFS= read -r f; do
      case "$f" in
        */+archives/*|*/node_modules/*|*/.git/*|*/refresh-backup-*/*) continue ;;
      esac
      files+=("$f")
    done < <(find "$walk_dir" -name ".mcp.json" -type f 2>/dev/null)
  else
    [[ -f "$TARGET" ]] || die "no $TARGET in $(pwd)"
    files+=("$TARGET")
  fi

  if [[ "${#files[@]}" -eq 0 ]]; then
    warn "no .mcp.json files found"
    return 1
  fi

  echo -e "${B}refresh${N} ${D}(${#files[@]} file$([[ ${#files[@]} -gt 1 ]] && echo s))${N}"

  # Backup when rewriting multiple files (walk mode)
  local bakdir=""
  if [[ "$dry_run" -eq 0 && "$no_backup" -eq 0 && -n "$walk_dir" ]]; then
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    bakdir="${CONFIG_DIR}/refresh-backup-${ts}"
    mkdir -p "$bakdir"
  fi

  local total_touched=0 total_files_touched=0
  for f in "${files[@]}"; do
    local keys
    keys=$(jq -r '.mcpServers | keys[]?' "$f" 2>/dev/null || true)
    [[ -z "$keys" ]] && continue

    local changes=()
    while IFS= read -r k; do
      jq -e --arg n "$k" '.mcpServers[$n]' "$CATALOG" &>/dev/null || continue
      local cur exp
      cur=$(jq -r --arg n "$k" '.mcpServers[$n].url // empty' "$f")
      exp=$(resolve_url "$k")
      if [[ -n "$exp" && "$cur" != "$exp" ]]; then
        changes+=("$k|$cur|$exp")
      fi
    done <<< "$keys"

    [[ "${#changes[@]}" -eq 0 ]] && continue

    echo -e "  ${C}${f}${N}"
    for c in "${changes[@]}"; do
      IFS='|' read -r k cur exp <<< "$c"
      echo -e "    ${k} ${D}${cur}${N} → ${exp}"
    done

    if [[ "$dry_run" -eq 0 ]]; then
      if [[ -n "$bakdir" ]]; then
        local rel="${f#/}"
        mkdir -p "$(dirname "${bakdir}/${rel}")"
        cp -p "$f" "${bakdir}/${rel}"
      fi
      for c in "${changes[@]}"; do
        IFS='|' read -r k cur exp <<< "$c"
        json_update "$f" --arg k "$k" --arg u "$exp" '.mcpServers[$k].url = $u'
      done
    fi

    total_files_touched=$((total_files_touched + 1))
    total_touched=$((total_touched + ${#changes[@]}))
  done

  echo ""
  if [[ "$total_touched" -eq 0 ]]; then
    dim "(no changes — already in sync)"
    return 0
  fi

  local verb="were"
  [[ "$dry_run" -eq 1 ]] && verb="would be"
  echo -e "${D}${total_touched} entries across ${total_files_touched} file(s) ${verb} rewritten${N}"
  [[ -n "$bakdir" ]] && dim "backup: $bakdir"

  # Auto-sync only in CWD mode (walk mode would thrash codex for every project)
  if [[ "$dry_run" -eq 0 && -z "$walk_dir" ]]; then
    auto_sync
  fi
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
