# fuzzy.sh — fuzzy name matching

catalog_names() {
  jq -r '.mcpServers | keys[]' "$CATALOG" | sort
}

# Generic fuzzy match: exact → prefix → contains
_fuzzy() {
  local q="$1"
  local names="$2"

  # Exact
  if echo "$names" | grep -qx "$q"; then
    echo "$q"; return
  fi

  # Prefix (e.g. "ssh-d" → "ssh-dev")
  local matches
  matches=$(echo "$names" | grep "^${q}" || true)
  if [[ -n "$matches" ]]; then
    local count
    count=$(echo "$matches" | wc -l | tr -d ' ')
    if [[ "$count" -eq 1 ]]; then
      echo "$matches"; return
    fi
  fi

  # Contains (e.g. "duck" → "duckdb-files-enterprise")
  matches=$(echo "$names" | grep "${q}" || true)
  if [[ -n "$matches" ]]; then
    local count
    count=$(echo "$matches" | wc -l | tr -d ' ')
    if [[ "$count" -eq 1 ]]; then
      echo "$matches"; return
    fi
    echo -e "${Y}ambiguous:${N} '${q}' matches:" >&2
    echo "$matches" | sed 's/^/  /' >&2
    return 1
  fi

  echo -e "${R}no match:${N} '${q}'" >&2
  return 1
}

fuzzy_match() {
  _fuzzy "$1" "$(catalog_names)"
}

fuzzy_match_current() {
  [[ -f "$TARGET" ]] || die "no $TARGET in current directory"
  local names
  names=$(jq -r '.mcpServers | keys[]' "$TARGET" 2>/dev/null | sort)
  [[ -n "$names" ]] || die "$TARGET is empty"
  _fuzzy "$1" "$names"
}
