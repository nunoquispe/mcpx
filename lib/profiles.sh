# profiles.sh — profile management

is_profile() {
  [[ -f "$PROFILES" ]] && jq -e --arg p "$1" '.[$p]' "$PROFILES" &>/dev/null
}

cmd_profile_save() {
  ensure_profiles
  ensure_catalog
  local name="$1"; shift
  [[ -n "$name" ]] || die "usage: mcpx :save <name> <mcp1> <mcp2> ..."
  [[ $# -gt 0 ]] || die "provide at least one MCP name"

  local mcps=()
  for m in "$@"; do
    local resolved
    resolved=$(fuzzy_match "$m") || return 1
    mcps+=("$resolved")
  done

  local json_arr
  json_arr=$(printf '%s\n' "${mcps[@]}" | jq -R . | jq -s .)
  json_update "$PROFILES" --arg n "$name" --argjson v "$json_arr" '.[$n] = $v'
  info "profile ${C}${name}${N} (${#mcps[@]} MCPs)"
  printf '  %s\n' "${mcps[@]}"
}

cmd_profile_ls() {
  ensure_profiles
  local profiles
  profiles=$(jq -r 'keys[]' "$PROFILES" 2>/dev/null)
  if [[ -z "$profiles" ]]; then
    dim "(no profiles)"
    return
  fi
  echo -e "${B}profiles${N}"
  echo "$profiles" | while read -r name; do
    local count members
    count=$(jq --arg n "$name" '.[$n] | length' "$PROFILES")
    members=$(jq -r --arg n "$name" '.[$n] | join(", ")' "$PROFILES")
    echo -e "  ${C}${name}${N} ${D}(${count})${N} ${D}${members}${N}"
  done
}

cmd_profile_rm() {
  ensure_profiles
  local name="$1"
  if ! jq -e --arg n "$name" '.[$n]' "$PROFILES" &>/dev/null; then
    die "profile '$name' not found"
  fi
  json_update "$PROFILES" --arg n "$name" 'del(.[$n])'
  echo -e "${R}-${N} profile ${name}"
}
