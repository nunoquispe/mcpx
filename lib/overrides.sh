# overrides.sh — URL overrides layer (temporary remapping of catalog URLs)
#
# Overrides let you redirect catalog entries to alternate URLs without
# touching the catalog. Use case: Mac Mini down, run MCPs locally on
# different ports. Override resolves before .mcp.json is written.

OVERRIDES="${CONFIG_DIR}/overrides.json"

ensure_overrides() {
  ensure_config_dir
  [[ -f "$OVERRIDES" ]] || echo '{}' > "$OVERRIDES"
}

# has_override NAME → exit 0 if override exists, 1 otherwise
has_override() {
  [[ -f "$OVERRIDES" ]] && jq -e --arg n "$1" '.[$n]' "$OVERRIDES" &>/dev/null
}

# override_url NAME → stdout override URL (empty if none)
override_url() {
  [[ -f "$OVERRIDES" ]] || return 0
  jq -r --arg n "$1" '.[$n] // empty' "$OVERRIDES" 2>/dev/null
}

# resolve_url NAME → stdout effective URL (override first, catalog fallback)
resolve_url() {
  local name="$1" ov
  ov=$(override_url "$name")
  if [[ -n "$ov" ]]; then
    echo "$ov"
    return
  fi
  [[ -f "$CATALOG" ]] || return 0
  jq -r --arg n "$name" '.mcpServers[$n].url // empty' "$CATALOG"
}

# Stopwords: tokens that carry no matching signal (common MCP/infra nouns).
# Used by _match_srvname_to_catalog to filter tokens before fuzzy-matching.
_SRV_STOPWORDS_RE='^(mcp|server|gm|general|mustard|enterprise|srv|service|svc|app)$'

# Normalize a server name: strip common mcp suffixes/prefixes.
_normalize_srvname() {
  local s="$1"
  s="${s%-mcp-server}"
  s="${s%_mcp_server}"
  s="${s%-mcp}"
  s="${s%_mcp}"
  s="${s#mcp-}"
  s="${s#mcp_}"
  echo "$s"
}

# Given a server name and catalog names list, return a catalog match or empty.
# Strategy:
#   1. Try full normalized name (handles cases like "broccoli-mcp" → "broccoli")
#   2. Tokenize on -/_, drop stopwords & 1-char tokens
#   3. Try tokens sorted by length DESC — first unique fuzzy match wins
# Length-desc bias favors the most distinctive token (e.g. "sapb1" over "sl").
_match_srvname_to_catalog() {
  local srv="$1" catalog_list="$2"
  local norm
  norm=$(_normalize_srvname "$srv")

  # Round 1: fuzzy on the full normalized name
  local m
  m=$(_fuzzy "$norm" "$catalog_list" 2>/dev/null || true)
  if [[ -n "$m" ]]; then
    echo "$m"
    return
  fi

  # Round 2: tokens sorted by length descending (distinctive first)
  local tokens
  tokens=$(echo "$norm" | tr '_-' '\n\n' \
    | awk -v re="$_SRV_STOPWORDS_RE" 'length($0) >= 2 && !($0 ~ re) { print length, $0 }' \
    | sort -rn \
    | awk '{print $2}')

  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    local hit
    hit=$(_fuzzy "$tok" "$catalog_list" 2>/dev/null || true)
    if [[ -n "$hit" ]]; then
      echo "$hit"
      return
    fi
  done <<< "$tokens"
}

cmd_override_ls() {
  ensure_overrides
  local count
  count=$(jq 'length' "$OVERRIDES")
  if [[ "$count" -eq 0 ]]; then
    dim "(no overrides)"
    return
  fi
  echo -e "${B}overrides${N} ${D}(${count})${N}"
  jq -r 'to_entries[] | "\(.key)|\(.value)"' "$OVERRIDES" | while IFS='|' read -r name url; do
    local catalog_url=""
    if [[ -f "$CATALOG" ]]; then
      catalog_url=$(jq -r --arg n "$name" '.mcpServers[$n].url // "(not in catalog)"' "$CATALOG")
    fi
    echo -e "  ${C}${name}${N} ${Y}!→${N} ${url}"
    echo -e "    ${D}catalog: ${catalog_url}${N}"
  done
}

cmd_override_set() {
  ensure_overrides
  ensure_catalog
  local name="${1:-}" url="${2:-}"
  [[ -n "$name" && -n "$url" ]] || die "usage: mcpx override set <name> <url>"

  local resolved
  resolved=$(fuzzy_match "$name") || return 1

  json_update "$OVERRIDES" --arg k "$resolved" --arg v "$url" '.[$k] = $v'
  info "override ${C}${resolved}${N} ${Y}!→${N} ${url}"
  dim "next: mcpx refresh (CWD) or mcpx refresh --walk <dir>"
}

cmd_override_rm() {
  ensure_overrides
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: mcpx override rm <name>"

  local names
  names=$(jq -r 'keys[]' "$OVERRIDES" 2>/dev/null)
  [[ -n "$names" ]] || die "no overrides to remove"

  local resolved
  resolved=$(_fuzzy "$name" "$names") || return 1

  json_update "$OVERRIDES" --arg k "$resolved" 'del(.[$k])'
  echo -e "${R}-${N} override ${resolved}"
}

cmd_override_clear() {
  ensure_overrides
  local count
  count=$(jq 'length' "$OVERRIDES")
  if [[ "$count" -eq 0 ]]; then
    dim "(already empty)"
    return
  fi
  echo '{}' > "$OVERRIDES"
  info "cleared ${count} override(s)"
  dim "next: mcpx refresh (CWD) or mcpx refresh --walk <dir>"
}

# cmd_override_from HOST [--dry-run] [--yes]
# Scans HOST, fuzzy-matches discovered MCPs against catalog, proposes overrides.
cmd_override_from() {
  ensure_overrides
  ensure_catalog

  local host_name="${1:-}"
  shift || true
  local dry_run=0 auto_yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=1 ;;
      --yes|-y)  auto_yes=1 ;;
      *)         die "unknown flag: $1" ;;
    esac
    shift
  done

  [[ -n "$host_name" ]] || die "usage: mcpx override from <host> [--dry-run] [--yes]"
  load_host "$host_name"

  echo -e "${B}scanning${N} ${C}${CURRENT_HOST}${N} ${D}${MCP_HOST}:${PORT_MIN}-${PORT_MAX}${N}"
  echo ""

  local records
  records=$(probe_host "$MCP_HOST" "$PORT_MIN" "$PORT_MAX")

  if [[ -z "$records" ]]; then
    warn "no live MCPs on ${CURRENT_HOST}"
    return 1
  fi

  local catalog_list
  catalog_list=$(catalog_names)

  local plan_file unmatched_file
  plan_file=$(mktemp)
  unmatched_file=$(mktemp)

  while IFS='|' read -r port srv_name srv_ver tool_count tool_names; do
    [[ -z "$port" ]] && continue
    local match
    match=$(_match_srvname_to_catalog "$srv_name" "$catalog_list")

    local url="http://${MCP_HOST}:${port}/mcp"
    if [[ -n "$match" ]]; then
      echo "${match}|${url}|${port}|${srv_name}" >> "$plan_file"
    else
      echo "${port}|${srv_name}|${tool_count}" >> "$unmatched_file"
    fi
  done <<< "$records"

  local matched_count unmatched_count
  matched_count=$(wc -l < "$plan_file" | tr -d ' ')
  unmatched_count=$(wc -l < "$unmatched_file" | tr -d ' ')

  echo -e "${B}proposed overrides${N} ${D}(${matched_count} matched, ${unmatched_count} unmatched)${N}"
  if [[ "$matched_count" -gt 0 ]]; then
    while IFS='|' read -r cat url port srv; do
      echo -e "  ${C}${cat}${N} ${Y}!→${N} ${url} ${D}(${srv})${N}"
    done < "$plan_file"
  fi
  if [[ "$unmatched_count" -gt 0 ]]; then
    echo ""
    echo -e "${Y}unmatched${N} ${D}(no catalog fuzzy-match — register with: mcpx @name port)${N}"
    while IFS='|' read -r port srv tc; do
      echo -e "  :${port} ${srv} ${D}${tc}t${N}"
    done < "$unmatched_file"
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    echo ""
    dim "dry-run — no changes made"
    rm -f "$plan_file" "$unmatched_file"
    return 0
  fi

  if [[ "$matched_count" -eq 0 ]]; then
    warn "nothing to apply"
    rm -f "$plan_file" "$unmatched_file"
    return 1
  fi

  if [[ "$auto_yes" -eq 0 ]]; then
    echo ""
    read -rp "Apply ${matched_count} override(s)? [y/N] " ans
    if ! [[ "$ans" =~ ^[yY]$ ]]; then
      dim "aborted"
      rm -f "$plan_file" "$unmatched_file"
      return 0
    fi
  fi

  while IFS='|' read -r cat url port srv; do
    json_update "$OVERRIDES" --arg k "$cat" --arg v "$url" '.[$k] = $v'
  done < "$plan_file"

  info "applied ${matched_count} override(s)"
  dim "next: mcpx refresh (CWD) or mcpx refresh --walk <dir>"
  rm -f "$plan_file" "$unmatched_file"
}
