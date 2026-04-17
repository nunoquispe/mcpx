# scan.sh — port scanning and MCP discovery

cmd_scan() {
  local host_name="${1:-}"
  load_host "$host_name"

  echo -e "${B}scanning${N} ${C}${CURRENT_HOST}${N} ${D}${MCP_HOST}:${PORT_MIN}-${PORT_MAX}${N}"
  echo ""

  ensure_catalog

  # Build port→name map
  local port_map_file
  port_map_file=$(mktemp)
  jq -r '.mcpServers | to_entries[] | "\(.value.url | capture("(?<p>[0-9]{4})") | .p)=\(.key)"' \
    "$CATALOG" > "$port_map_file"

  # Phase 1: parallel port discovery
  local tmpdir
  tmpdir=$(mktemp -d)
  for port in $(seq "$PORT_MIN" "$PORT_MAX"); do
    (
      local code
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 1 \
        "http://${MCP_HOST}:${port}/mcp" 2>/dev/null || echo "000")
      if [[ "$code" != "000" ]]; then
        echo "$port" > "${tmpdir}/${port}"
      fi
    ) &
  done
  wait

  # Collect live ports
  local live_ports=()
  for port in $(seq "$PORT_MIN" "$PORT_MAX"); do
    if [[ -f "${tmpdir}/${port}" ]]; then
      live_ports+=("$port")
    fi
  done

  # Phase 2: parallel MCP protocol probe on live ports
  local probe_dir
  probe_dir=$(mktemp -d)
  local init_body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"mcpx","version":"'"${VERSION}"'"}}}'
  local tools_body='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

  for port in "${live_ports[@]}"; do
    (
      local url="http://${MCP_HOST}:${port}/mcp"
      local headers="Content-Type: application/json"
      local accept="Accept: application/json, text/event-stream"

      # Initialize → server name + version
      local init_resp
      init_resp=$(curl -s -X POST "$url" -H "$headers" -H "$accept" \
        --max-time 2 -d "$init_body" 2>/dev/null | grep "^data:" | head -1 | sed 's/^data: //')

      local srv_name srv_ver
      srv_name=$(echo "$init_resp" | jq -r '.result.serverInfo.name // empty' 2>/dev/null)
      srv_ver=$(echo "$init_resp" | jq -r '.result.serverInfo.version // empty' 2>/dev/null)

      # tools/list → tool count and names
      local tools_resp
      tools_resp=$(curl -s -X POST "$url" -H "$headers" -H "$accept" \
        --max-time 2 -d "$tools_body" 2>/dev/null | grep "^data:" | head -1 | sed 's/^data: //')

      local tool_count tool_names
      tool_count=$(echo "$tools_resp" | jq '.result.tools | length' 2>/dev/null || echo "0")
      tool_names=$(echo "$tools_resp" | jq -r '[.result.tools[].name] | join(",")' 2>/dev/null || echo "")

      echo "${srv_name:-?}|${srv_ver:-?}|${tool_count:-0}|${tool_names}" > "${probe_dir}/${port}"
    ) &
  done
  wait

  # Display results
  local found=0
  local new=0
  for port in "${live_ports[@]}"; do
    local known_name=""
    known_name=$(grep "^${port}=" "$port_map_file" | cut -d= -f2 || true)

    local srv_name="?" srv_ver="?" tool_count="0" tool_names=""
    if [[ -f "${probe_dir}/${port}" ]]; then
      IFS='|' read -r srv_name srv_ver tool_count tool_names < "${probe_dir}/${port}"
    fi

    local tools_display=""
    if [[ -n "$tool_names" && "$tool_names" != "null" ]]; then
      tools_display="${D}[${tool_names}]${N}"
    fi

    if [[ -n "$known_name" ]]; then
      echo -e "  ${G}*${N} :${port} ${C}${known_name}${N} ${D}${srv_name} v${srv_ver}${N} ${B}${tool_count}t${N} ${tools_display}"
    else
      echo -e "  ${Y}?${N} :${port} ${Y}${srv_name}${N} ${D}v${srv_ver}${N} ${B}${tool_count}t${N} ${tools_display}"
      new=$((new + 1))
    fi
    found=$((found + 1))
  done
  rm -rf "$tmpdir" "$probe_dir" "$port_map_file"

  echo ""
  echo -e "${D}${found} live, ${new} unknown${N}"
  if [[ $new -gt 0 ]]; then
    dim "use: mcpx @name port — to register"
  fi
}
