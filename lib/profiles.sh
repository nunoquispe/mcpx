# profiles.sh — named groups of MCPs for batch add/remove.
#
# Profiles live in $PROFILES_FILE as { "<name>": ["mcp1", "mcp2", ...] }.
# `mcpx +<name>` checks profiles before the catalog so `+dev` expands
# to every MCP in the "dev" profile.

# is_profile <name> → exit 0 iff <name> is a defined profile.
is_profile() {
  [[ -f "$PROFILES_FILE" ]] \
    && jq -e --arg p "$1" '.[$p]' "$PROFILES_FILE" &>/dev/null
}

# profile_members <name> → one member per line (no validation).
profile_members() {
  jq -r --arg n "$1" '.[$n][]' "$PROFILES_FILE"
}

ensure_profiles() {
  ensure_json_file "$PROFILES_FILE"
}

# --- commands -------------------------------------------------------------

cmd_profile_save() {
  ensure_profiles
  ensure_catalog

  local name="$1"; shift
  [[ -n "$name" ]]  || die "usage: mcpx :save <name> <mcp1> <mcp2> ..."
  [[ $# -gt 0 ]]    || die "provide at least one MCP name"

  # Resolve every member through catalog fuzzy-match first: if any one
  # fails we abort before touching the profile file.
  local members=() m resolved
  for m in "$@"; do
    resolved=$(fuzzy_match "$m") || return 1
    members+=("$resolved")
  done

  local members_json
  members_json=$(printf '%s\n' "${members[@]}" | jq -R . | jq -s .)

  json_update "$PROFILES_FILE" \
    --arg n "$name" --argjson v "$members_json" \
    '.[$n] = $v'

  info "profile ${C}${name}${N} (${#members[@]} MCPs)"
  printf '  %s\n' "${members[@]}"
}

cmd_profile_ls() {
  ensure_profiles

  local names
  names=$(jq -r 'keys[]' "$PROFILES_FILE" 2>/dev/null)
  if [[ -z "$names" ]]; then
    dim "(no profiles)"
    return
  fi

  echo -e "${B}profiles${N}"
  while read -r name; do
    local count members
    count=$(jq   --arg n "$name" '.[$n] | length'       "$PROFILES_FILE")
    members=$(jq -r --arg n "$name" '.[$n] | join(", ")' "$PROFILES_FILE")
    echo -e "  ${C}${name}${N} ${D}(${count})${N} ${D}${members}${N}"
  done <<<"$names"
}

cmd_profile_rm() {
  ensure_profiles
  local name="$1"

  if ! jq -e --arg n "$name" '.[$n]' "$PROFILES_FILE" &>/dev/null; then
    die "profile '$name' not found"
  fi

  json_update "$PROFILES_FILE" --arg n "$name" 'del(.[$n])'
  echo -e "${R}-${N} profile ${name}"
}
