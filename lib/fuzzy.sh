# fuzzy.sh — fuzzy name matching against a set of known names.
#
# Strategy (in order): exact → unique prefix → unique substring.
# Ambiguous matches are reported on stderr with the candidate list;
# no match is reported on stderr with a hint.
#
# Inputs are treated as literal strings (never regex) so users can pass
# names containing regex metacharacters safely.

# catalog_names → one name per line, sorted.
catalog_names() {
  jq -r '.mcpServers | keys[]' "$CATALOG_FILE" | sort
}

# project_names → one name per line (from $PROJECT_FILE), sorted.
project_names() {
  jq -r '.mcpServers | keys[]' "$PROJECT_FILE" 2>/dev/null | sort
}

# fuzzy_find_in <query> <newline-separated-names>
# On success: prints the resolved unique name, returns 0.
# On ambiguity / no-match: prints nothing to stdout, message to stderr,
# returns 1.
fuzzy_find_in() {
  local query="$1"
  local names="$2"

  # 1. exact match (fixed-string, full-line)
  if grep -Fxq -- "$query" <<<"$names"; then
    echo "$query"
    return 0
  fi

  # 2. unique prefix match (e.g. "ssh-d" → "ssh-dev")
  local prefix_hits
  prefix_hits=$(awk -v q="$query" 'index($0, q) == 1' <<<"$names")
  if [[ -n "$prefix_hits" ]] && [[ $(wc -l <<<"$prefix_hits") -eq 1 ]]; then
    echo "$prefix_hits"
    return 0
  fi

  # 3. unique substring match (e.g. "duck" → "duckdb-files-enterprise")
  local sub_hits
  sub_hits=$(awk -v q="$query" 'index($0, q) > 0' <<<"$names")
  if [[ -n "$sub_hits" ]]; then
    if [[ $(wc -l <<<"$sub_hits") -eq 1 ]]; then
      echo "$sub_hits"
      return 0
    fi
    echo -e "${Y}ambiguous:${N} '${query}' matches:" >&2
    sed 's/^/  /' <<<"$sub_hits" >&2
    return 1
  fi

  echo -e "${R}no match:${N} '${query}'" >&2
  return 1
}

# fuzzy_match <query> → resolve against the catalog.
fuzzy_match() {
  fuzzy_find_in "$1" "$(catalog_names)"
}

# fuzzy_match_current <query> → resolve against the current project file.
fuzzy_match_current() {
  [[ -f "$PROJECT_FILE" ]] || die "no $PROJECT_FILE in current directory"
  local names
  names=$(project_names)
  [[ -n "$names" ]] || die "$PROJECT_FILE is empty"
  fuzzy_find_in "$1" "$names"
}
