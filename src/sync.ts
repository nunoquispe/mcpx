// sync — auto-sync to external clients (Codex TOML, Gemini JSON)
//
// External configs are edited in-place using fenced block markers, so only
// the mcpx-managed region is touched. User-added content is preserved.

import { promises as fs, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  c,
  die,
  info,
  warn,
  dim,
  readJson,
  writeJson,
  CONFIG_FILE,
  PROJECT_FILE,
  type Config,
  type McpFile,
} from "./core.ts";

// BEGIN/END markers that delimit mcpx-managed regions in external configs.
const BEGIN_MARKER = "# BEGIN MCPX MANAGED MCP SERVERS";
const END_MARKER = "# END MCPX MANAGED MCP SERVERS";

// Legacy markers from the `mcpy` era — still recognized for migration.
const OLD_BEGIN_MARKER = "# BEGIN MCPY MANAGED MCP SERVERS";
const OLD_END_MARKER = "# END MCPY MANAGED MCP SERVERS";

// syncEnabled — true iff auto-sync is turned on for <target>.
async function syncEnabled(target: string): Promise<boolean> {
  const cfg = await readJson<Config>(CONFIG_FILE, { hosts: {} });
  return cfg.sync?.[target] === true;
}

// stripManagedBlock — return `content` with any mcpx/mcpy-managed block removed.
function stripManagedBlock(content: string): string {
  const out: string[] = [];
  let skip = false;
  for (const line of content.split("\n")) {
    if (line === BEGIN_MARKER || line === OLD_BEGIN_MARKER) {
      skip = true;
      continue;
    }
    if (line === END_MARKER || line === OLD_END_MARKER) {
      skip = false;
      continue;
    }
    if (!skip) out.push(line);
  }
  return out.join("\n");
}

// generateCodexToml — TOML block reflecting the CWD project file. "" if none.
async function generateCodexToml(): Promise<string> {
  const proj = await readJson<McpFile>(PROJECT_FILE, { mcpServers: {} });
  const entries = Object.entries(proj.mcpServers ?? {});
  if (entries.length === 0) return "";

  const lines: string[] = ["", BEGIN_MARKER];
  for (const [name, entry] of entries) {
    lines.push(`[mcp_servers."${name}"]`);
    lines.push(`url = "${entry.url ?? ""}"`);
    lines.push("");
  }
  lines.push(END_MARKER);
  return lines.join("\n");
}

async function syncCodex(): Promise<void> {
  const codexConfig = process.env.CODEX_CONFIG ?? join(homedir(), ".codex", "config.toml");
  if (!existsSync(codexConfig)) {
    dim(`codex config not found: ${codexConfig} (skipped)`);
    return;
  }
  if (!existsSync(PROJECT_FILE)) return;

  const existing = await fs.readFile(codexConfig, "utf8");
  const next = stripManagedBlock(existing) + (await generateCodexToml()) + "\n";
  await fs.writeFile(codexConfig, next);

  const proj = await readJson<McpFile>(PROJECT_FILE, { mcpServers: {} });
  const count = Object.keys(proj.mcpServers ?? {}).length;
  console.log(`  ${c.D}codex${c.N} ${c.G}synced${c.N} ${c.D}(${count} MCPs → ${codexConfig})${c.N}`);
}

// Gemini uses a JSON config with `httpUrl` instead of `url`. We track the
// keys we manage in `.mcpx_managed` so we can cleanly remove them next time.
interface GeminiConfig {
  mcpServers?: Record<string, { httpUrl: string }>;
  mcpx_managed?: string[];
  [k: string]: unknown;
}

async function syncGemini(): Promise<void> {
  const geminiConfig = join(".gemini", "settings.json");
  if (!existsSync(PROJECT_FILE)) return;
  if (!(await syncEnabled("gemini"))) return;

  await fs.mkdir(".gemini", { recursive: true });

  const cfg = await readJson<GeminiConfig>(geminiConfig, { mcpServers: {} });
  const proj = await readJson<McpFile>(PROJECT_FILE, { mcpServers: {} });

  // Transform .mcp.json servers to Gemini format (url -> httpUrl).
  const newMcp: Record<string, { httpUrl: string }> = {};
  for (const [name, entry] of Object.entries(proj.mcpServers ?? {})) {
    newMcp[name] = { httpUrl: entry.url ?? "" };
  }

  // Drop the keys we previously managed, then merge the fresh set.
  const oldManaged = cfg.mcpx_managed ?? [];
  const servers: Record<string, { httpUrl: string }> = {};
  for (const [k, v] of Object.entries(cfg.mcpServers ?? {})) {
    if (!oldManaged.includes(k)) servers[k] = v;
  }
  Object.assign(servers, newMcp);

  cfg.mcpServers = servers;
  cfg.mcpx_managed = Object.keys(newMcp);
  await writeJson(geminiConfig, cfg);

  const count = Object.keys(proj.mcpServers ?? {}).length;
  console.log(
    `  ${c.D}gemini${c.N} ${c.G}synced${c.N} ${c.D}(${count} MCPs → ${geminiConfig})${c.N}`,
  );
}

// autoSync — run every enabled sync target.
export async function autoSync(): Promise<void> {
  if (await syncEnabled("codex")) await syncCodex();
  if (await syncEnabled("gemini")) await syncGemini();
  // Future: cursor, windsurf, etc.
}

// --- commands -------------------------------------------------------------

export async function cmdSyncStatus(): Promise<void> {
  if (!existsSync(CONFIG_FILE)) die("not initialized — run: mcpx init");
  console.log(`${c.B}sync targets${c.N}`);

  const cfg = await readJson<Config>(CONFIG_FILE, { hosts: {} });
  const targets = Object.entries(cfg.sync ?? {});
  if (targets.length === 0) {
    dim("  (none configured)");
    dim("  use: mcpx sync codex true");
    dim("  or:  mcpx sync gemini true");
    return;
  }

  for (const [name, enabled] of targets) {
    if (enabled) {
      console.log(`  ${c.G}*${c.N} ${c.C}${name}${c.N} ${c.G}on${c.N}`);
    } else {
      console.log(`    ${name} ${c.R}off${c.N}`);
    }
  }
}

export async function cmdSyncSet(target: string, raw: string): Promise<void> {
  if (!existsSync(CONFIG_FILE)) die("not initialized — run: mcpx init");

  let value: boolean;
  switch (raw) {
    case "true":
    case "on":
    case "1":
    case "yes":
      value = true;
      break;
    case "false":
    case "off":
    case "0":
    case "no":
      value = false;
      break;
    default:
      die("usage: mcpx sync <target> true|false");
  }

  const cfg = await readJson<Config>(CONFIG_FILE, { hosts: {} });
  cfg.sync = cfg.sync ?? {};
  cfg.sync[target] = value;
  await writeJson(CONFIG_FILE, cfg);

  if (value) info(`sync ${target} enabled`);
  else warn(`sync ${target} disabled`);
}
