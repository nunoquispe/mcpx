// scan — parallel HTTP probe + MCP protocol handshake
//
// probeHost does the work in two phases:
//   1. HTTP reachability sweep across [pmin, pmax]  (parallel fetch)
//   2. MCP `initialize` + `tools/list` on every live port  (parallel)
//
// Returns one record per live MCP: { port, srvName, srvVer, toolCount, toolNames }.
//
// The bash original parallelised with subshells writing to tempdir files and
// juggled `set +e`; here Promise.all + try/catch does the same, statelessly.

import {
  c,
  dim,
  VERSION,
  readJson,
  urlPort,
  buildMcpUrl,
  ensureCatalog,
  CATALOG_FILE,
  type McpFile,
} from "./core.ts";
import { loadHost } from "./config.ts";

export interface ScanRecord {
  port: number;
  srvName: string;
  srvVer: string;
  toolCount: number;
  toolNames: string;
}

// JSON-RPC request bodies used in phase 2.
const initBody = (v: string) =>
  JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-03-26",
      capabilities: {},
      clientInfo: { name: "mcpx", version: v },
    },
  });
const INITIALIZED_BODY = JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" });
const TOOLS_BODY = JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });

const JSON_HEADERS = {
  "Content-Type": "application/json",
  Accept: "application/json, text/event-stream",
};

// firstSseData — first `data:` payload from a text/event-stream body, or "".
// MCP servers respond with SSE for these methods; we take the first data line
// as the JSON-RPC response body.
function firstSseData(text: string): string {
  for (const line of text.split(/\r?\n/)) {
    if (line.startsWith("data:")) return line.replace(/^data:\s*/, "");
  }
  return "";
}

function safeParse(text: string): any {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

// mcpInit — POST initialize, returning the Mcp-Session-Id header and the first
// SSE data payload. The session id is required for every subsequent call on
// the Streamable HTTP transport.
async function mcpInit(url: string): Promise<{ sid: string; body: string }> {
  try {
    const r = await fetch(url, {
      method: "POST",
      headers: JSON_HEADERS,
      body: initBody(VERSION),
      signal: AbortSignal.timeout(2000),
    });
    const sid = (r.headers.get("mcp-session-id") ?? "").trim();
    return { sid, body: firstSseData(await r.text()) };
  } catch {
    return { sid: "", body: "" };
  }
}

// mcpPost — POST a JSON-RPC body (with the session id) and return the first
// SSE data payload, or "".
async function mcpPost(url: string, body: string, sid: string): Promise<string> {
  try {
    const headers: Record<string, string> = { ...JSON_HEADERS };
    if (sid) headers["Mcp-Session-Id"] = sid;
    const r = await fetch(url, {
      method: "POST",
      headers,
      body,
      signal: AbortSignal.timeout(2000),
    });
    return firstSseData(await r.text());
  } catch {
    return "";
  }
}

// probeOne — full handshake against a single live port.
async function probeOne(host: string, port: number): Promise<ScanRecord> {
  const url = buildMcpUrl(host, port);

  const { sid, body: initResp } = await mcpInit(url);

  // Notify initialized (server expects this before any other call). No
  // response body — it only advances the session state machine.
  if (sid) {
    try {
      await fetch(url, {
        method: "POST",
        headers: { ...JSON_HEADERS, "Mcp-Session-Id": sid },
        body: INITIALIZED_BODY,
        signal: AbortSignal.timeout(2000),
      });
    } catch {
      // best-effort
    }
  }

  const toolsResp = await mcpPost(url, TOOLS_BODY, sid);

  const init = safeParse(initResp);
  const tools = safeParse(toolsResp);

  const srvName = init?.result?.serverInfo?.name ?? "?";
  const srvVer = init?.result?.serverInfo?.version ?? "?";
  const toolList: { name: string }[] = Array.isArray(tools?.result?.tools)
    ? tools.result.tools
    : [];
  const toolCount = toolList.length;
  const toolNames = toolList.map((t) => t.name).join(",");

  // Best-effort: drop the session so the server doesn't accumulate idle
  // handshakes from repeated scans.
  if (sid) {
    try {
      await fetch(url, {
        method: "DELETE",
        headers: { "Mcp-Session-Id": sid },
        signal: AbortSignal.timeout(1000),
      });
    } catch {
      // best-effort
    }
  }

  return { port, srvName, srvVer, toolCount, toolNames };
}

// probeHost <host> <pmin> <pmax> → records for every live MCP, port-ordered.
export async function probeHost(host: string, pmin: number, pmax: number): Promise<ScanRecord[]> {
  // Phase 1: TCP/HTTP reachability. fetch resolves for any HTTP status (even
  // 404/405 → live); it throws only on connection refused / timeout.
  const ports: number[] = [];
  for (let p = pmin; p <= pmax; p++) ports.push(p);

  const liveFlags = await Promise.all(
    ports.map(async (port) => {
      try {
        await fetch(buildMcpUrl(host, port), {
          method: "GET",
          signal: AbortSignal.timeout(1000),
        });
        return true;
      } catch {
        return false;
      }
    }),
  );
  const livePorts = ports.filter((_, i) => liveFlags[i]);

  // Phase 2: MCP protocol handshake on each live port (parallel).
  const records = await Promise.all(livePorts.map((port) => probeOne(host, port)));
  return records.sort((a, b) => a.port - b.port);
}

// --- commands -------------------------------------------------------------

export async function cmdScan(hostName?: string): Promise<void> {
  const host = await loadHost(hostName);

  console.log(
    `${c.B}scanning${c.N} ${c.C}${host.name}${c.N} ${c.D}${host.addr}:${host.portMin}-${host.portMax}${c.N}`,
  );
  console.log("");

  ensureCatalog();

  // Build a port→name lookup from the catalog (first entry wins per port).
  const cat = await readJson<McpFile>(CATALOG_FILE, { mcpServers: {} });
  const portMap = new Map<string, string>();
  for (const [name, entry] of Object.entries(cat.mcpServers ?? {})) {
    const p = urlPort(entry.url);
    if (p && !portMap.has(p)) portMap.set(p, name);
  }

  const records = await probeHost(host.addr, host.portMin, host.portMax);

  let found = 0;
  let unknownCount = 0;
  for (const r of records) {
    const known = portMap.get(String(r.port));
    const toolsDisplay =
      r.toolNames && r.toolNames !== "null" ? `${c.D}[${r.toolNames}]${c.N}` : "";

    if (known) {
      console.log(
        `  ${c.G}*${c.N} :${r.port} ${c.C}${known}${c.N} ${c.D}${r.srvName} v${r.srvVer}${c.N} ${c.B}${r.toolCount}t${c.N} ${toolsDisplay}`,
      );
    } else {
      console.log(
        `  ${c.Y}?${c.N} :${r.port} ${c.Y}${r.srvName}${c.N} ${c.D}v${r.srvVer}${c.N} ${c.B}${r.toolCount}t${c.N} ${toolsDisplay}`,
      );
      unknownCount++;
    }
    found++;
  }

  console.log("");
  console.log(`${c.D}${found} live, ${unknownCount} unknown${c.N}`);
  if (unknownCount > 0) dim("use: mcpx @name port — to register");
}
