// config — init, hosts, loadHost → resolved Host
//
// loadHost replaces the bash HOST_* globals: it returns a Host object that
// scan.ts and overrides.ts consume, resolved from $CONFIG_FILE.

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  c,
  die,
  info,
  warn,
  dim,
  ask,
  commandExists,
  readJson,
  writeJson,
  ensureConfigDir,
  CONFIG_FILE,
  CATALOG_FILE,
  type Config,
  type Host,
} from "./core.ts";

// loadHost — resolve a host from $CONFIG_FILE. With no arg, uses .default_host.
export async function loadHost(name?: string): Promise<Host> {
  if (!existsSync(CONFIG_FILE)) die("not initialized — run: mcpx init");
  const cfg = await readJson<Config>(CONFIG_FILE, { hosts: {} });

  let host = name;
  if (!host) {
    host = cfg.default_host;
    if (!host) die("no default_host in config");
  }

  const h = cfg.hosts?.[host];
  if (!h || !h.address) die(`host '${host}' not found in config`);

  return {
    name: host,
    addr: h.address,
    portMin: h.port_min ?? 3200,
    portMax: h.port_max ?? 3250,
  };
}

// --- commands -------------------------------------------------------------

export async function cmdInit(): Promise<void> {
  await ensureConfigDir();

  if (existsSync(CONFIG_FILE)) {
    warn(`config already exists: ${CONFIG_FILE}`);
    const ans = await ask("Overwrite? [y/N] ");
    if (!/^[yY]$/.test(ans)) return;
  }

  console.log(`${c.B}mcpx init${c.N}`);
  console.log("");

  const hostName = await ask("Host name (e.g. mini, server, local): ");
  if (!hostName) die("host name required");

  const hostAddr = await ask("Host address (IP or hostname): ");
  if (!hostAddr) die("address required");

  const portMinRaw = await ask("Port range start [3200]: ");
  const portMin = Number(portMinRaw || "3200");

  const portMaxRaw = await ask("Port range end [3250]: ");
  const portMax = Number(portMaxRaw || "3250");

  let syncCodex = false;
  let syncGemini = false;

  // Offer Codex sync only if Codex is actually installed/configured.
  if (commandExists("codex") || existsSync(join(homedir(), ".codex", "config.toml"))) {
    const ans = await ask("Sync to Codex (~/.codex/config.toml)? [Y/n]: ");
    if (!/^[nN]$/.test(ans)) syncCodex = true;
  }

  // Offer Gemini sync.
  const gAns = await ask("Sync to Gemini (.gemini/settings.json)? [Y/n]: ");
  if (!/^[nN]$/.test(gAns)) syncGemini = true;

  const cfg: Config = {
    default_host: hostName,
    hosts: {
      [hostName]: { address: hostAddr, port_min: portMin, port_max: portMax },
    },
    sync: { codex: syncCodex, gemini: syncGemini },
  };
  await writeJson(CONFIG_FILE, cfg);

  if (!existsSync(CATALOG_FILE)) {
    await writeJson(CATALOG_FILE, { mcpServers: {} });
    info("created empty catalog");
  }

  info(`config saved to ${CONFIG_FILE}`);
  console.log("");
  dim("next: mcpx scan — discover live MCPs");
  dim("  or: mcpx @my-server 3201 — add to catalog manually");
}

export async function cmdHosts(): Promise<void> {
  if (!existsSync(CONFIG_FILE)) die("not initialized — run: mcpx init");
  const cfg = await readJson<Config>(CONFIG_FILE, { hosts: {} });
  const def = cfg.default_host ?? "";

  console.log(`${c.B}hosts${c.N}`);
  for (const [name, h] of Object.entries(cfg.hosts ?? {})) {
    if (name === def) {
      console.log(`  ${c.G}*${c.N} ${c.C}${name}${c.N} ${c.D}${h.address} :${h.port_min}-${h.port_max}${c.N}`);
    } else {
      console.log(`    ${name} ${c.D}${h.address} :${h.port_min}-${h.port_max}${c.N}`);
    }
  }
}

export async function cmdHostAdd(
  name: string,
  addr: string,
  pmin = 3200,
  pmax = 3250,
): Promise<void> {
  if (!existsSync(CONFIG_FILE)) die("not initialized — run: mcpx init");
  const cfg = await readJson<Config>(CONFIG_FILE, { hosts: {} });
  cfg.hosts = cfg.hosts ?? {};
  cfg.hosts[name] = { address: addr, port_min: pmin, port_max: pmax };
  await writeJson(CONFIG_FILE, cfg);
  info(`host ${name} (${addr})`);
}
