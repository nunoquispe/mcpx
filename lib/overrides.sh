# overrides.sh — temporary URL remapping layer.
#
# Use case: primary MCP host is down, you spin up local fallbacks on
# different ports. Overrides redirect catalog entries to alternate URLs
# without touching the catalog. Resolution happens at +add time and at
# refresh time, so reverting is a single `mcpx override clear`.

ensure_overrides() {
  ensure_json_file "$OVERRIDES_FILE"
}

# has_override <name> → exit 0 iff an override is set for <name>.
has_override() {
  [[ -f "$OVERRIDES_FILE" ]] \
    && jq -e --arg n "$1" '.[$n]' "$OVERRIDES_FILE" &>/dev/null
}

# override_url <name> → effective override URL, or empty if none.
override_url() {
  [[ -f "$OVERRIDES_FILE" ]] || return 0
  jq -r --arg n "$1" '.[$n] // empty' "$OVERRIDES_FILE" 2>/dev/null
}

# catalog_url <name> → URL recorded in the catalog, or empty.
catalog_url() {
  [[ -f "$CATALOG_FILE" ]] || return 0
  jq -r --arg n "$1" '.mcpServers[$n].url // empty' "$CATALOG_FILE"
}

# resolve_url <name> → effective URL: override wins, else catalog.
resolve_url() {
  local name="$1" url
  url=$(override_url "$name")
  [[ -n "$url" ]] && { echo "$url"; return; }
  catalog_url "$name"
}

# --- server-name → catalog-name matching ---------------------------------
#
# Used by `override from <host>` to auto-link a discovered server (whose
# name comes from its own `serverInfo.name`) to a catalog entry. We can't
# trust discovered names to match catalog names exactly — hence fuzzy
# with noise filtering.

# Tokens that carry no discriminating signal (common MCP/infra nouns).
_SRV_STOPWORDS_RE='^(mcp|server|gm|general|mustard|enterprise|srv|service|svc|app)$'

# _normalize_srvname <name> → strip common MCP suffix/prefix decorations.
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

# _match_srvname_to_catalog <srv_name> <catalog-names>
# Try the full normalized name, then individual tokens ordered by length
# descending (most distinctive token wins, e.g. "sapb1" beats "sl").
_match_srvname_to_catalog() {
  local srv="$1" catalog_list="$2"
  local normalized
  normalized=$(_normalize_srvname "$srv")

  # Round 1: full normalized name.
  local hit
  hit=$(fuzzy_find_in "$normalized" "$catalog_list" 2>/dev/null || true)
  [[ -n "$hit" ]] && { echo "$hit"; return; }

  # Round 2: tokens, length-descending.
  local tokens
  tokens=$(tr '_-' '\n\n' <<<"$normalized" \
    | awk -v re="$_SRV_STOPWORDS_RE" 'length($0) >= 2 && !($0 ~ re) { print length, $0 }' \
    | sort -rn \
    | awk '{print $2}')

  local tok
  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    hit=$(fuzzy_find_in "$tok" "$catalog_list" 2>/dev/null || true)
    [[ -n "$hit" ]] && { echo "$hit"; return; }
  done <<<"$tokens"
}

# --- commands -------------------------------------------------------------

cmd_override_ls() {
  ensure_overrides
  local count
  count=$(jq 'length' "$OVERRIDES_FILE")
  if [[ "$count" -eq 0 ]]; then
    dim "(no overrides)"
    return
  fi

  echo -e "${B}overrides${N} ${D}(${count})${N}"
  jq -r 'to_entries[] | "\(.key)|\(.value)"' "$OVERRIDES_FILE" \
    | while IFS='|' read -r name url; do
        local cat_url="(not in catalog)"
        if [[ -f "$CATALOG_FILE" ]]; then
          cat_url=$(jq -r --arg n "$name" '.mcpServers[$n].url // "(not in catalog)"' "$CATALOG_FILE")
        fi
        echo -e "  ${C}${name}${N} ${Y}!→${N} ${url}"
        echo -e "    ${D}catalog: ${cat_url}${N}"
      done
}

cmd_override_set() {
  ensure_overrides
  ensure_catalog
  local name="${1:-}" url="${2:-}"
  [[ -n "$name" && -n "$url" ]] || die "usage: mcpx override set <name> <url>"

  local resolved
  resolved=$(fuzzy_match "$name") || return 1

  json_update "$OVERRIDES_FILE" --arg k "$resolved" --arg v "$url" '.[$k] = $v'
  info "override ${C}${resolved}${N} ${Y}!→${N} ${url}"
  dim "next: mcpx refresh (CWD) or mcpx refresh --walk <dir>"
}

cmd_override_rm() {
  ensure_overrides
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: mcpx override rm <name>"

  local existing
  existing=$(jq -r 'keys[]' "$OVERRIDES_FILE" 2>/dev/null)
  [[ -n "$existing" ]] || die "no overrides to remove"

  local resolved
  resolved=$(fuzzy_find_in "$name" "$existing") || return 1

  json_update "$OVERRIDES_FILE" --arg k "$resolved" 'del(.[$k])'
  echo -e "${R}-${N} override ${resolved}"
}

cmd_override_clear() {
  ensure_overrides
  local count
  count=$(jq 'length' "$OVERRIDES_FILE")
  if [[ "$count" -eq 0 ]]; then
    dim "(already empty)"
    return
  fi
  echo '{}' > "$OVERRIDES_FILE"
  info "cleared ${count} override(s)"
  dim "next: mcpx refresh (CWD) or mcpx refresh --walk <dir>"
}

# cmd_override_from <host> [--dry-run] [--yes]
# Scan <host>, fuzzy-match each discovered MCP to the catalog, propose overrides.
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

  echo -e "${B}scanning${N} ${C}${HOST_NAME}${N} ${D}${HOST_ADDR}:${HOST_PORT_MIN}-${HOST_PORT_MAX}${N}"
  echo ""

  local records
  records=$(probe_host "$HOST_ADDR" "$HOST_PORT_MIN" "$HOST_PORT_MAX")

  if [[ -z "$records" ]]; then
    warn "no live MCPs on ${HOST_NAME}"
    return 1
  fi

  local catalog_list
  catalog_list=$(catalog_names)

  local plan_file unmatched_file
  plan_file=$(mktemp)
  unmatched_file=$(mktemp)
  # Local trap: these are short-lived files, not tempdirs.
  trap 'rm -f "$plan_file" "$unmatched_file"' RETURN

  while IFS='|' read -r port srv_name srv_ver tool_count tool_names; do
    [[ -z "$port" ]] && continue
    local match
    match=$(_match_srvname_to_catalog "$srv_name" "$catalog_list")
    local url
    url=$(build_mcp_url "$HOST_ADDR" "$port")

    if [[ -n "$match" ]]; then
      echo "${match}|${url}|${port}|${srv_name}" >> "$plan_file"
    else
      echo "${port}|${srv_name}|${tool_count}" >> "$unmatched_file"
    fi
  done <<<"$records"

  local matched unmatched
  matched=$(wc -l < "$plan_file" | tr -d ' ')
  unmatched=$(wc -l < "$unmatched_file" | tr -d ' ')

  echo -e "${B}proposed overrides${N} ${D}(${matched} matched, ${unmatched} unmatched)${N}"
  if [[ "$matched" -gt 0 ]]; then
    while IFS='|' read -r cat url port srv; do
      echo -e "  ${C}${cat}${N} ${Y}!→${N} ${url} ${D}(${srv})${N}"
    done < "$plan_file"
  fi
  if [[ "$unmatched" -gt 0 ]]; then
    echo ""
    echo -e "${Y}unmatched${N} ${D}(no catalog fuzzy-match — register with: mcpx @name port)${N}"
    while IFS='|' read -r port srv tc; do
      echo -e "  :${port} ${srv} ${D}${tc}t${N}"
    done < "$unmatched_file"
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    echo ""
    dim "dry-run — no changes made"
    return 0
  fi

  if [[ "$matched" -eq 0 ]]; then
    warn "nothing to apply"
    return 1
  fi

  if [[ "$auto_yes" -eq 0 ]]; then
    echo ""
    read -rp "Apply ${matched} override(s)? [y/N] " ans
    if ! [[ "$ans" =~ ^[yY]$ ]]; then
      dim "aborted"
      return 0
    fi
  fi

  while IFS='|' read -r cat url port srv; do
    json_update "$OVERRIDES_FILE" --arg k "$cat" --arg v "$url" '.[$k] = $v'
  done < "$plan_file"

  info "applied ${matched} override(s)"
  dim "next: mcpx refresh (CWD) or mcpx refresh --walk <dir>"
}
