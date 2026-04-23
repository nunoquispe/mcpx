# scan.sh — port scanning and MCP-over-HTTP discovery.
#
# probe_host does the work in two parallel phases:
#   1. HTTP reachability sweep across [pmin, pmax]
#   2. MCP `initialize` + `tools/list` on every live port
#
# Emits one pipe-delimited record per live MCP to stdout:
#   port|srv_name|srv_ver|tool_count|tool_names

# JSON-RPC request bodies used in phase 2 of probe_host.
_MCP_INIT_BODY='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"mcpx","version":"__VER__"}}}'
_MCP_INITIALIZED_BODY='{"jsonrpc":"2.0","method":"notifications/initialized"}'
_MCP_TOOLS_BODY='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# _mcp_post <url> <body> [<session_id>] → the first `data:` SSE payload, or empty.
# MCP servers respond with text/event-stream for these methods; we take
# the first `data:` line as the JSON-RPC response body. When session_id is
# provided, it is sent as the Mcp-Session-Id header (required for any call
# after `initialize` on the Streamable HTTP transport).
_mcp_post() {
  local url="$1" body="$2" sid="${3:-}"
  local args=(-s -X POST "$url"
       -H "Content-Type: application/json"
       -H "Accept: application/json, text/event-stream"
       --max-time 2
       -d "$body")
  [[ -n "$sid" ]] && args+=(-H "Mcp-Session-Id: $sid")
  curl "${args[@]}" 2>/dev/null \
    | awk '/^data:/ { sub(/^data: */, ""); print; exit }'
}

# _mcp_init <url> → "<session_id>|<body>" (either may be empty on failure).
# Performs the initial handshake while capturing the Mcp-Session-Id header
# that the server returns. The body is the first `data:` SSE payload.
_mcp_init() {
  local url="$1"
  local hdr_file body sid
  hdr_file=$(mktemp)
  body=$(curl -s -D "$hdr_file" -X POST "$url" \
       -H "Content-Type: application/json" \
       -H "Accept: application/json, text/event-stream" \
       --max-time 2 \
       -d "${_MCP_INIT_BODY/__VER__/$VERSION}" 2>/dev/null \
    | awk '/^data:/ { sub(/^data: */, ""); print; exit }')
  sid=$(awk 'tolower($1) == "mcp-session-id:" { print $2; exit }' "$hdr_file" \
    | tr -d '\r\n')
  rm -f "$hdr_file"
  echo "${sid}|${body}"
}

# probe_host <host> <pmin> <pmax>
probe_host() {
  local host="$1" pmin="$2" pmax="$3"

  # Phase 1: TCP/HTTP reachability (parallel curl per port).
  #   curl -s -w "%{http_code}" reliably prints a 3-digit code even on
  #   connection refused (the code is "000" in that case — we filter it).
  local live_dir
  live_dir=$(make_tempdir)

  local port
  for port in $(seq "$pmin" "$pmax"); do
    (
      local code
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 1 \
        "http://${host}:${port}/mcp" 2>/dev/null)
      if [[ -n "$code" && "$code" != "000" ]]; then
        : > "${live_dir}/${port}"
      fi
    ) &
  done
  wait

  local live_ports=()
  for port in $(seq "$pmin" "$pmax"); do
    [[ -f "${live_dir}/${port}" ]] && live_ports+=("$port")
  done

  # Phase 2: MCP protocol handshake on each live port (parallel).
  #
  # Streamable HTTP transport requires a stateful session:
  #   1. POST initialize             → server returns Mcp-Session-Id header
  #   2. POST notifications/initialized (with Mcp-Session-Id)
  #   3. POST tools/list             (with Mcp-Session-Id)
  #   4. DELETE /mcp                 (with Mcp-Session-Id)  — best-effort cleanup
  #
  # Skipping steps 1–2 makes the server return -32000 "not initialized" and
  # tool_count silently collapses to 0.
  local probe_dir
  probe_dir=$(make_tempdir)

  for port in "${live_ports[@]}"; do
    (
      # Disable errexit inside the probe subshell — partial failures (jq on
      # an empty body, a slow port that times out) must NOT abort the whole
      # scan. We always emit a record, even if some fields end up as '?'.
      set +e
      local url init_pair sid init_resp tools_resp
      local srv_name srv_ver tool_count tool_names
      url=$(build_mcp_url "$host" "$port")

      init_pair=$(_mcp_init "$url")
      sid="${init_pair%%|*}"
      init_resp="${init_pair#*|}"

      # Notify initialized (server expects this before any other call). No
      # response body — we only need it to advance the session state machine.
      if [[ -n "$sid" ]]; then
        curl -s -X POST "$url" \
             -H "Content-Type: application/json" \
             -H "Accept: application/json, text/event-stream" \
             -H "Mcp-Session-Id: $sid" \
             --max-time 2 \
             -d "$_MCP_INITIALIZED_BODY" >/dev/null 2>&1
      fi

      tools_resp=$(_mcp_post "$url" "$_MCP_TOOLS_BODY" "$sid")

      srv_name=$(jq   -r '.result.serverInfo.name    // empty' <<<"$init_resp"  2>/dev/null)
      srv_ver=$(jq    -r '.result.serverInfo.version // empty' <<<"$init_resp"  2>/dev/null)
      tool_count=$(jq    '.result.tools | length'             <<<"$tools_resp" 2>/dev/null)
      tool_names=$(jq -r '[.result.tools[].name] | join(",")' <<<"$tools_resp" 2>/dev/null)

      # Best-effort: tell the server to drop the session so it doesn't
      # accumulate idle handshakes from repeated scans.
      if [[ -n "$sid" ]]; then
        curl -s -X DELETE "$url" \
             -H "Mcp-Session-Id: $sid" \
             --max-time 1 >/dev/null 2>&1
      fi

      echo "${port}|${srv_name:-?}|${srv_ver:-?}|${tool_count:-0}|${tool_names}" \
        > "${probe_dir}/${port}"
    ) &
  done
  wait

  # Emit records in port order. The `|| true` keeps the loop's final exit
  # status at 0 even when a probe file is missing — otherwise `set -e` in
  # the caller's command substitution aborts the whole scan.
  for port in "${live_ports[@]}"; do
    [[ -f "${probe_dir}/${port}" ]] && cat "${probe_dir}/${port}"
  done
  return 0
}

# --- commands -------------------------------------------------------------

cmd_scan() {
  load_host "${1:-}"

  echo -e "${B}scanning${N} ${C}${HOST_NAME}${N} ${D}${HOST_ADDR}:${HOST_PORT_MIN}-${HOST_PORT_MAX}${N}"
  echo ""

  ensure_catalog

  # Build a port→name lookup table as "PORT=NAME" lines. Bash 3.2 lacks
  # associative arrays, so we grep this table once per probed port.
  local port_map
  port_map=$(jq -r '
    .mcpServers | to_entries[] |
      select(.value.url | test(":[0-9]+"))
    | ((.value.url | capture(":(?<p>[0-9]+)") | .p) + "=" + .key)
  ' "$CATALOG_FILE")

  local records
  records=$(probe_host "$HOST_ADDR" "$HOST_PORT_MIN" "$HOST_PORT_MAX")

  local found=0 new=0
  local port srv_name srv_ver tool_count tool_names known tools_display
  while IFS='|' read -r port srv_name srv_ver tool_count tool_names; do
    [[ -z "$port" ]] && continue

    # `|| true` keeps `set -e` happy when the port has no catalog entry —
    # grep returning 1 (no match) is the normal "unknown port" case, not an
    # error. Without this guard the entire scan aborts at the first new port.
    known=$(grep "^${port}=" <<<"$port_map" | head -1 | cut -d= -f2- || true)

    tools_display=""
    if [[ -n "$tool_names" && "$tool_names" != "null" ]]; then
      tools_display="${D}[${tool_names}]${N}"
    fi

    if [[ -n "$known" ]]; then
      echo -e "  ${G}*${N} :${port} ${C}${known}${N} ${D}${srv_name} v${srv_ver}${N} ${B}${tool_count}t${N} ${tools_display}"
    else
      echo -e "  ${Y}?${N} :${port} ${Y}${srv_name}${N} ${D}v${srv_ver}${N} ${B}${tool_count}t${N} ${tools_display}"
      new=$((new + 1))
    fi
    found=$((found + 1))
  done <<<"$records"

  echo ""
  echo -e "${D}${found} live, ${new} unknown${N}"
  [[ "$new" -gt 0 ]] && dim "use: mcpx @name port — to register"
}
