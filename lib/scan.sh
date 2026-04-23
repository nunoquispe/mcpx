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
_MCP_TOOLS_BODY='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# _mcp_post <url> <body> → the first `data:` SSE payload, or empty.
# MCP servers respond with text/event-stream for these methods; we take
# the first `data:` line as the JSON-RPC response body.
_mcp_post() {
  local url="$1" body="$2"
  curl -s -X POST "$url" \
       -H "Content-Type: application/json" \
       -H "Accept: application/json, text/event-stream" \
       --max-time 2 \
       -d "$body" 2>/dev/null \
    | awk '/^data:/ { sub(/^data: */, ""); print; exit }'
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
  local probe_dir
  probe_dir=$(make_tempdir)

  # Bake the running version into the clientInfo once, up front.
  local init_body="${_MCP_INIT_BODY/__VER__/$VERSION}"

  for port in "${live_ports[@]}"; do
    (
      local url init_resp tools_resp srv_name srv_ver tool_count tool_names
      url=$(build_mcp_url "$host" "$port")

      init_resp=$(_mcp_post  "$url" "$init_body")
      tools_resp=$(_mcp_post "$url" "$_MCP_TOOLS_BODY")

      srv_name=$(jq -r '.result.serverInfo.name    // empty' <<<"$init_resp" 2>/dev/null)
      srv_ver=$(jq  -r '.result.serverInfo.version // empty' <<<"$init_resp" 2>/dev/null)
      tool_count=$(jq   '.result.tools | length'    <<<"$tools_resp" 2>/dev/null || echo 0)
      tool_names=$(jq -r '[.result.tools[].name] | join(",")' <<<"$tools_resp" 2>/dev/null || echo "")

      echo "${port}|${srv_name:-?}|${srv_ver:-?}|${tool_count:-0}|${tool_names}" \
        > "${probe_dir}/${port}"
    ) &
  done
  wait

  # Emit records in port order.
  for port in "${live_ports[@]}"; do
    [[ -f "${probe_dir}/${port}" ]] && cat "${probe_dir}/${port}"
  done
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

    known=$(grep "^${port}=" <<<"$port_map" | head -1 | cut -d= -f2-)

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
