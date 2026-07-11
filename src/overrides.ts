// overrides — temporary URL remapping (override-first resolution)
//
// Use case: primary MCP host is down, you spin up local fallbacks on
// different ports. Overrides redirect catalog entries to alternate URLs
// without touching the catalog. Resolution happens at +add time and at
// refresh time, so reverting is a single `mcpx override clear`.

import {
  c,
  die,
  info,
  warn,
  dim,
  ask,
  readJson,
  writeJson,
  ensureJsonFile,
  ensureCatalog,
  buildMcpUrl,
  OVERRIDES_FILE,
  CATALOG_FILE,
  type McpFile,
} from "./core.ts";
import { catalogNames, fuzzyFindIn, fuzzyMatch } from "./fuzzy.ts";
import { loadHost } from "./config.ts";
import { probeHost } from "./scan.ts";

type Overrides = Record<string, string>;

export async function ensureOverrides(): Promise<void> {
  await ensureJsonFile(OVERRIDES_FILE);
}

async function readOverrides(): Promise<Overrides> {
  return readJson<Overrides>(OVERRIDES_FILE, {});
}

// hasOverride — true iff an override is set for <name>.
export async function hasOverride(name: string): Promise<boolean> {
  const o = await readOverrides();
  return o[name] != null;
}

// overrideUrl — effective override URL, or "" if none.
export async function overrideUrl(name: string): Promise<string> {
  const o = await readOverrides();
  return o[name] ?? "";
}

// catalogUrl — URL recorded in the catalog, or "".
export async function catalogUrl(name: string): Promise<string> {
  const j = await readJson<McpFile>(CATALOG_FILE, { mcpServers: {} });
  return (j.mcpServers?.[name]?.url as string | undefined) ?? "";
}

// resolveUrl — effective URL: override wins, else catalog.
export async function resolveUrl(name: string): Promise<string> {
  const o = await overrideUrl(name);
  if (o) return o;
  return catalogUrl(name);
}

// --- server-name → catalog-name matching ---------------------------------
//
// Used by `override from <host>` to auto-link a discovered server (whose name
// comes from its own serverInfo.name) to a catalog entry. We can't trust
// discovered names to match catalog names exactly — hence fuzzy with noise
// filtering.

// Tokens that carry no discriminating signal (common MCP/infra nouns).
const SRV_STOPWORDS = /^(mcp|server|gm|general|mustard|enterprise|srv|service|svc|app)$/;

// normalizeSrvname — strip common MCP suffix/prefix decorations.
function normalizeSrvname(s: string): string {
  s = s
    .replace(/-mcp-server$/, "")
    .replace(/_mcp_server$/, "")
    .replace(/-mcp$/, "")
    .replace(/_mcp$/, "");
  s = s.replace(/^mcp-/, "").replace(/^mcp_/, "");
  return s;
}

// matchSrvnameToCatalog — try the full normalized name, then individual
// tokens ordered by length descending (most distinctive token wins).
function matchSrvnameToCatalog(srv: string, catalog: string[]): string | null {
  const normalized = normalizeSrvname(srv);

  // Round 1: full normalized name.
  const hit = fuzzyFindIn(normalized, catalog, true);
  if (hit) return hit;

  // Round 2: tokens, length-descending.
  const tokens = normalized
    .split(/[_-]/)
    .filter((t) => t.length >= 2 && !SRV_STOPWORDS.test(t))
    .sort((a, b) => b.length - a.length);

  for (const tok of tokens) {
    const h = fuzzyFindIn(tok, catalog, true);
    if (h) return h;
  }
  return null;
}

// --- commands -------------------------------------------------------------

export async function cmdOverrideLs(): Promise<void> {
  await ensureOverrides();
  const o = await readOverrides();
  const entries = Object.entries(o);
  if (entries.length === 0) {
    dim("(no overrides)");
    return;
  }

  console.log(`${c.B}overrides${c.N} ${c.D}(${entries.length})${c.N}`);
  const cat = await readJson<McpFile>(CATALOG_FILE, { mcpServers: {} });
  for (const [name, url] of entries) {
    const catUrl = (cat.mcpServers?.[name]?.url as string | undefined) ?? "(not in catalog)";
    console.log(`  ${c.C}${name}${c.N} ${c.Y}!→${c.N} ${url}`);
    console.log(`    ${c.D}catalog: ${catUrl}${c.N}`);
  }
}

export async function cmdOverrideSet(name?: string, url?: string): Promise<number> {
  await ensureOverrides();
  ensureCatalog();
  if (!name || !url) die("usage: mcpx override set <name> <url>");

  const resolved = await fuzzyMatch(name);
  if (!resolved) return 1;

  const o = await readOverrides();
  o[resolved] = url;
  await writeJson(OVERRIDES_FILE, o);
  info(`override ${c.C}${resolved}${c.N} ${c.Y}!→${c.N} ${url}`);
  dim("next: mcpx refresh (CWD) or mcpx refresh --walk <dir>");
  return 0;
}

export async function cmdOverrideRm(name?: string): Promise<number> {
  await ensureOverrides();
  if (!name) die("usage: mcpx override rm <name>");

  const o = await readOverrides();
  const existing = Object.keys(o);
  if (existing.length === 0) die("no overrides to remove");

  const resolved = fuzzyFindIn(name, existing);
  if (!resolved) return 1;

  delete o[resolved];
  await writeJson(OVERRIDES_FILE, o);
  console.log(`${c.R}-${c.N} override ${resolved}`);
  return 0;
}

export async function cmdOverrideClear(): Promise<void> {
  await ensureOverrides();
  const o = await readOverrides();
  const count = Object.keys(o).length;
  if (count === 0) {
    dim("(already empty)");
    return;
  }
  await writeJson(OVERRIDES_FILE, {});
  info(`cleared ${count} override(s)`);
  dim("next: mcpx refresh (CWD) or mcpx refresh --walk <dir>");
}

// cmdOverrideFrom — scan <host>, fuzzy-match each discovered MCP to the
// catalog, propose overrides.
export async function cmdOverrideFrom(argv: string[]): Promise<number> {
  await ensureOverrides();
  ensureCatalog();

  const hostName = argv[0];
  let dryRun = false;
  let autoYes = false;
  for (const a of argv.slice(1)) {
    switch (a) {
      case "--dry-run":
        dryRun = true;
        break;
      case "--yes":
      case "-y":
        autoYes = true;
        break;
      default:
        die(`unknown flag: ${a}`);
    }
  }

  if (!hostName) die("usage: mcpx override from <host> [--dry-run] [--yes]");
  const host = await loadHost(hostName);

  console.log(
    `${c.B}scanning${c.N} ${c.C}${host.name}${c.N} ${c.D}${host.addr}:${host.portMin}-${host.portMax}${c.N}`,
  );
  console.log("");

  const records = await probeHost(host.addr, host.portMin, host.portMax);
  if (records.length === 0) {
    warn(`no live MCPs on ${host.name}`);
    return 1;
  }

  const catalog = await catalogNames();

  const plan: { cat: string; url: string; srv: string }[] = [];
  const unmatched: { port: number; srv: string; toolCount: number }[] = [];

  for (const r of records) {
    const match = matchSrvnameToCatalog(r.srvName, catalog);
    const url = buildMcpUrl(host.addr, r.port);
    if (match) plan.push({ cat: match, url, srv: r.srvName });
    else unmatched.push({ port: r.port, srv: r.srvName, toolCount: r.toolCount });
  }

  console.log(
    `${c.B}proposed overrides${c.N} ${c.D}(${plan.length} matched, ${unmatched.length} unmatched)${c.N}`,
  );
  for (const p of plan) {
    console.log(`  ${c.C}${p.cat}${c.N} ${c.Y}!→${c.N} ${p.url} ${c.D}(${p.srv})${c.N}`);
  }
  if (unmatched.length > 0) {
    console.log("");
    console.log(
      `${c.Y}unmatched${c.N} ${c.D}(no catalog fuzzy-match — register with: mcpx @name port)${c.N}`,
    );
    for (const u of unmatched) {
      console.log(`  :${u.port} ${u.srv} ${c.D}${u.toolCount}t${c.N}`);
    }
  }

  if (dryRun) {
    console.log("");
    dim("dry-run — no changes made");
    return 0;
  }

  if (plan.length === 0) {
    warn("nothing to apply");
    return 1;
  }

  if (!autoYes) {
    console.log("");
    const ans = await ask(`Apply ${plan.length} override(s)? [y/N] `);
    if (!/^[yY]$/.test(ans)) {
      dim("aborted");
      return 0;
    }
  }

  const o = await readOverrides();
  for (const p of plan) o[p.cat] = p.url;
  await writeJson(OVERRIDES_FILE, o);

  info(`applied ${plan.length} override(s)`);
  dim("next: mcpx refresh (CWD) or mcpx refresh --walk <dir>");
  return 0;
}
