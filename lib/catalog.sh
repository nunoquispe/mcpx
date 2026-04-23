# catalog.sh — the show / list / add / remove / refresh / catalog-edit commands.
#
# Two layers of state are at play:
#   $CATALOG_FILE   your private registry of all known MCPs
#   $PROJECT_FILE   which MCPs are active in the current working directory
#
# `mcpx +name` copies an entry from the catalog into the project file,
# applying any active override; `mcpx refresh` rewrites project URLs to
# match the current override/catalog state.

# --- shared helpers -------------------------------------------------------

# project_url <name> → URL recorded in the project file, or empty.
project_url() {
  jq -r --arg n "$1" '.mcpServers[$n].url // empty' "$PROJECT_FILE" 2>/dev/null
}

# project_has <name> → exit 0 iff the name is in the current project file.
project_has() {
  [[ -f "$PROJECT_FILE" ]] \
    && jq -e --arg n "$1" '.mcpServers[$n]' "$PROJECT_FILE" &>/dev/null
}

# catalog_has <name> → exit 0 iff the name is in the catalog.
catalog_has() {
  jq -e --arg n "$1" '.mcpServers[$n]' "$CATALOG_FILE" &>/dev/null
}

# ensure_project_file — create an empty .mcp.json if one doesn't exist.
ensure_project_file() {
  [[ -f "$PROJECT_FILE" ]] || echo '{"mcpServers":{}}' > "$PROJECT_FILE"
}

# --- show / list ----------------------------------------------------------

cmd_show() {
  if [[ ! -f "$PROJECT_FILE" ]]; then
    dim "no $PROJECT_FILE in $(pwd)"
    return
  fi

  local names
  names=$(project_names)
  if [[ -z "$names" ]]; then
    dim "(empty)"
    return
  fi

  local count
  count=$(wc -l <<<"$names" | tr -d ' ')
  echo -e "${B}${PROJECT_FILE}${N} ${D}(${count})${N}"

  while read -r name; do
    local port marker=""
    port=$(url_port "$(project_url "$name")")
    has_override "$name" && marker=" ${Y}!${N}"
    echo -e "  ${C}${name}${N} ${D}:${port}${N}${marker}"
  done <<<"$names"
}

cmd_list() {
  ensure_catalog

  # Active names as a newline-separated string (bash 3.2 has no -A arrays).
  # Surrounding with newlines lets us test membership with a single grep.
  local active=""
  if [[ -f "$PROJECT_FILE" ]]; then
    active=$(project_names)
  fi

  local total
  total=$(jq '.mcpServers | length' "$CATALOG_FILE")
  echo -e "${B}catalog${N} ${D}(${total})${N}"

  local name port marker ov_url
  while read -r name; do
    port=$(url_port "$(catalog_url "$name")")

    marker=""
    if has_override "$name"; then
      ov_url=$(override_url "$name")
      marker=" ${Y}!→${N} ${D}${ov_url}${N}"
    fi

    if grep -Fxq -- "$name" <<<"$active"; then
      echo -e "  ${G}*${N} ${C}${name}${N} ${D}:${port}${N}${marker}"
    else
      echo -e "    ${name} ${D}:${port}${N}${marker}"
    fi
  done < <(catalog_names)
}

# --- add / remove ---------------------------------------------------------

# mcp_add <name> — copy one catalog entry into the project file.
mcp_add() {
  ensure_catalog

  local name resolved
  resolved=$(fuzzy_match "$1") || return 1

  ensure_project_file

  if project_has "$resolved"; then
    warn "${resolved} already in config"
    return 0
  fi

  # Clone the catalog entry, apply override if any, then write.
  local entry
  entry=$(jq --arg n "$resolved" '.mcpServers[$n]' "$CATALOG_FILE")

  if has_override "$resolved"; then
    local ov
    ov=$(override_url "$resolved")
    entry=$(jq --arg u "$ov" '.url = $u' <<<"$entry")
    json_update "$PROJECT_FILE" --arg k "$resolved" --argjson v "$entry" \
      '.mcpServers[$k] = $v'
    info "${resolved} ${Y}!${N} ${D}${ov}${N}"
  else
    json_update "$PROJECT_FILE" --arg k "$resolved" --argjson v "$entry" \
      '.mcpServers[$k] = $v'
    info "${resolved}"
  fi
}

# mcp_remove <name> — remove one entry from the project file.
mcp_remove() {
  [[ -f "$PROJECT_FILE" ]] || die "no $PROJECT_FILE in current directory"

  local resolved
  resolved=$(fuzzy_match_current "$1") || return 1

  json_update "$PROJECT_FILE" --arg k "$resolved" 'del(.mcpServers[$k])'
  echo -e "${R}-${N} ${resolved}"
}

# cmd_add / cmd_rm — profile-aware wrappers over mcp_add / mcp_remove.

cmd_add() {
  local name="$1"
  if is_profile "$name"; then
    dim "profile: ${name}"
    while read -r m; do mcp_add "$m"; done < <(profile_members "$name")
  else
    mcp_add "$name"
  fi
}

cmd_rm() {
  local name="$1"
  if is_profile "$name"; then
    dim "profile: ${name}"
    while read -r m; do
      mcp_remove "$m" 2>/dev/null || true
    done < <(profile_members "$name")
  else
    mcp_remove "$name"
  fi
}

cmd_clean() {
  echo '{"mcpServers":{}}' > "$PROJECT_FILE"
  info "cleaned $PROJECT_FILE"
  auto_sync
}

# --- refresh: rewrite project-file URLs to match current resolution ------
#
# Walks one file (CWD by default) or an entire tree (--walk DIR). Only
# touches entries whose name is in the catalog; manually-added entries
# are left alone. In walk mode, backups are taken under $CONFIG_DIR unless
# --no-backup is given.

cmd_refresh() {
  ensure_catalog

  local dry_run=0 walk_dir="" no_backup=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)    dry_run=1 ;;
      --walk)       walk_dir="${2:-}"
                    [[ -n "$walk_dir" ]] || die "--walk requires a directory"
                    shift ;;
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
    [[ -f "$PROJECT_FILE" ]] || die "no $PROJECT_FILE in $(pwd)"
    files+=("$PROJECT_FILE")
  fi

  if [[ "${#files[@]}" -eq 0 ]]; then
    warn "no .mcp.json files found"
    return 1
  fi

  local file_word="file"
  [[ "${#files[@]}" -gt 1 ]] && file_word="files"
  echo -e "${B}refresh${N} ${D}(${#files[@]} ${file_word})${N}"

  # Prepare backup directory (walk mode, non-dry-run, backups enabled).
  local bakdir=""
  if [[ "$dry_run" -eq 0 && "$no_backup" -eq 0 && -n "$walk_dir" ]]; then
    bakdir="${CONFIG_DIR}/refresh-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bakdir"
  fi

  local total_changed=0 files_changed=0
  local f
  for f in "${files[@]}"; do
    local keys
    keys=$(jq -r '.mcpServers | keys[]?' "$f" 2>/dev/null || true)
    [[ -z "$keys" ]] && continue

    # Compute the diff: for each key in both $f and the catalog,
    # compare current URL to the resolved (override|catalog) URL.
    local changes=() k cur exp
    while IFS= read -r k; do
      catalog_has "$k" || continue
      cur=$(jq -r --arg n "$k" '.mcpServers[$n].url // empty' "$f")
      exp=$(resolve_url "$k")
      [[ -n "$exp" && "$cur" != "$exp" ]] && changes+=("$k|$cur|$exp")
    done <<<"$keys"

    [[ "${#changes[@]}" -eq 0 ]] && continue

    echo -e "  ${C}${f}${N}"
    local c
    for c in "${changes[@]}"; do
      IFS='|' read -r k cur exp <<<"$c"
      echo -e "    ${k} ${D}${cur}${N} → ${exp}"
    done

    if [[ "$dry_run" -eq 0 ]]; then
      if [[ -n "$bakdir" ]]; then
        local rel="${f#/}"
        mkdir -p "$(dirname "${bakdir}/${rel}")"
        cp -p "$f" "${bakdir}/${rel}"
      fi
      for c in "${changes[@]}"; do
        IFS='|' read -r k cur exp <<<"$c"
        json_update "$f" --arg k "$k" --arg u "$exp" \
          '.mcpServers[$k].url = $u'
      done
    fi

    files_changed=$((files_changed + 1))
    total_changed=$((total_changed + ${#changes[@]}))
  done

  echo ""
  if [[ "$total_changed" -eq 0 ]]; then
    dim "(no changes — already in sync)"
    return 0
  fi

  local verb="were"
  [[ "$dry_run" -eq 1 ]] && verb="would be"
  echo -e "${D}${total_changed} entries across ${files_changed} file(s) ${verb} rewritten${N}"
  [[ -n "$bakdir" ]] && dim "backup: $bakdir"

  # Auto-sync only when rewriting the CWD file — walk mode would thrash
  # the external client config for every project visited.
  if [[ "$dry_run" -eq 0 && -z "$walk_dir" ]]; then
    auto_sync
  fi
}

# --- catalog edit ---------------------------------------------------------
# `mcpx @name port` → upsert entry using the default host address.
# `mcpx @name`      → remove entry from the catalog.

cmd_catalog() {
  ensure_catalog
  local name="$1" port="${2:-}"

  load_host

  if [[ -z "$port" ]]; then
    _catalog_remove "$name"
  else
    _catalog_upsert "$name" "$port"
  fi
}

_catalog_remove() {
  local name="$1"
  if ! catalog_has "$name"; then
    echo -e "${R}not in catalog:${N} $name" >&2
    return 1
  fi
  json_update "$CATALOG_FILE" --arg k "$name" 'del(.mcpServers[$k])'
  echo -e "${R}-${N} ${name} ${D}(removed from catalog)${N}"
}

_catalog_upsert() {
  local name="$1" port="$2"
  local url
  url=$(build_mcp_url "$HOST_ADDR" "$port")

  if catalog_has "$name"; then
    local old_port
    old_port=$(url_port "$(catalog_url "$name")")
    if [[ "$old_port" == "$port" ]]; then
      warn "${name} already in catalog at :${port}"
      return 0
    fi
    json_update "$CATALOG_FILE" --arg k "$name" --arg u "$url" \
      '.mcpServers[$k].url = $u'
    echo -e "${Y}~${N} ${name} ${D}:${old_port} → :${port}${N}"
  else
    json_update "$CATALOG_FILE" --arg k "$name" --arg u "$url" \
      '.mcpServers[$k] = {"type":"http", "url":$u}'
    info "${name} ${D}:${port} → catalog${N}"
  fi
}
