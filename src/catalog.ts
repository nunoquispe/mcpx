// catalog — show / list / add / remove / refresh / catalog edit
//
// Two layers of state are at play:
//   $CATALOG_FILE   your private registry of all known MCPs
//   $PROJECT_FILE   which MCPs are active in the current working directory
//
// `mcpx +name` copies an entry from the catalog into the project file,
// applying any active override; `mcpx refresh` rewrites project URLs to match
// the current override/catalog state.

import { promises as fs, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import {
  c,
  die,
  info,
  warn,
  dim,
  tildify,
  readJson,
  writeJson,
  urlPort,
  ensureCatalog,
  buildMcpUrl,
  CONFIG_DIR,
  CATALOG_FILE,
  PROJECT_FILE,
  type McpFile,
  type McpEntry,
} from "./core.ts";
import { fuzzyMatch, fuzzyMatchCurrent, catalogNames, projectNames } from "./fuzzy.ts";
import { hasOverride, overrideUrl, resolveUrl, catalogUrl } from "./overrides.ts";
import { isProfile, profileMembers } from "./profiles.ts";
import { autoSync } from "./sync.ts";
import { loadHost } from "./config.ts";

// --- shared helpers -------------------------------------------------------

// projectHas — true iff the name is in the current project file.
async function projectHas(name: string): Promise<boolean> {
  if (!existsSync(PROJECT_FILE)) return false;
  const j = await readJson<McpFile>(PROJECT_FILE, { mcpServers: {} });
  return j.mcpServers?.[name] != null;
}

// catalogHas — true iff the name is in the catalog.
async function catalogHas(name: string): Promise<boolean> {
  const j = await readJson<McpFile>(CATALOG_FILE, { mcpServers: {} });
  return j.mcpServers?.[name] != null;
}

// ensureProjectFile — create an empty .mcp.json if one doesn't exist.
async function ensureProjectFile(): Promise<void> {
  if (!existsSync(PROJECT_FILE)) await writeJson(PROJECT_FILE, { mcpServers: {} });
}

// mcpNamesIn — server names declared in <file>, sorted.
async function mcpNamesIn(file: string): Promise<string[]> {
  const j = await readJson<McpFile>(file, { mcpServers: {} });
  return Object.keys(j.mcpServers ?? {}).sort();
}

// mcpUrlIn — URL recorded for <name> in <file>. Accepts both the `.url` shape
// mcpx writes and the `.httpUrl` shape some agents author by hand.
async function mcpUrlIn(file: string, name: string): Promise<string> {
  const j = await readJson<McpFile>(file, { mcpServers: {} });
  const e = j.mcpServers?.[name];
  return e ? (e.url ?? e.httpUrl ?? "") : "";
}

// projectFileChain — every $PROJECT_FILE from CWD up to /, nearest first.
// Agents inherit MCP servers from ancestor directories, so the effective set
// in CWD is the union of the CWD file and each ancestor's.
function projectFileChain(): string[] {
  const chain: string[] = [];
  let dir = process.cwd();
  for (;;) {
    const f = join(dir, PROJECT_FILE);
    if (existsSync(f)) chain.push(f);
    if (dir === "/") break;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return chain;
}

// --- show / list ----------------------------------------------------------

// cmdShow lists the CWD .mcp.json plus every .mcp.json inherited from an
// ancestor directory — mirroring how agents resolve MCP config up the tree.
export async function cmdShow(): Promise<void> {
  const chain = projectFileChain();
  if (chain.length === 0) {
    dim(`no ${PROJECT_FILE} in ${process.cwd()} or any parent`);
    return;
  }

  const cwdFile = join(process.cwd(), PROJECT_FILE);
  const seen = new Set<string>();
  let first = true;

  for (const file of chain) {
    const names = await mcpNamesIn(file);
    if (names.length === 0) continue;

    const header =
      file === cwdFile
        ? `${c.B}${PROJECT_FILE}${c.N}`
        : `${c.D}↑ inherited ${tildify(file)}${c.N}`;
    if (!first) console.log("");
    first = false;
    console.log(`${header} ${c.D}(${names.length})${c.N}`);

    for (const name of names) {
      const port = urlPort(await mcpUrlIn(file, name));
      const marker = (await hasOverride(name)) ? ` ${c.Y}!${c.N}` : "";
      if (seen.has(name)) {
        console.log(`  ${c.D}${name} :${port} (overridden)${c.N}`);
      } else {
        console.log(`  ${c.C}${name}${c.N} ${c.D}:${port}${c.N}${marker}`);
      }
    }

    for (const n of names) seen.add(n);
  }
}

export async function cmdList(): Promise<void> {
  ensureCatalog();

  const active = new Set(existsSync(PROJECT_FILE) ? await projectNames() : []);
  const names = await catalogNames();
  console.log(`${c.B}catalog${c.N} ${c.D}(${names.length})${c.N}`);

  for (const name of names) {
    const port = urlPort(await catalogUrl(name));
    let marker = "";
    if (await hasOverride(name)) {
      marker = ` ${c.Y}!→${c.N} ${c.D}${await overrideUrl(name)}${c.N}`;
    }
    if (active.has(name)) {
      console.log(`  ${c.G}*${c.N} ${c.C}${name}${c.N} ${c.D}:${port}${c.N}${marker}`);
    } else {
      console.log(`    ${name} ${c.D}:${port}${c.N}${marker}`);
    }
  }
}

// --- add / remove ---------------------------------------------------------

// mcpAdd — copy one catalog entry into the project file. Returns true on
// success (already-present counts as success, matching bash).
async function mcpAdd(name: string): Promise<boolean> {
  ensureCatalog();

  const resolved = await fuzzyMatch(name);
  if (!resolved) return false;

  await ensureProjectFile();

  if (await projectHas(resolved)) {
    warn(`${resolved} already in config`);
    return true;
  }

  const cat = await readJson<McpFile>(CATALOG_FILE, { mcpServers: {} });
  const entry: McpEntry = { ...cat.mcpServers[resolved] };

  const proj = await readJson<McpFile>(PROJECT_FILE, { mcpServers: {} });

  if (await hasOverride(resolved)) {
    const ov = await overrideUrl(resolved);
    entry.url = ov;
    proj.mcpServers[resolved] = entry;
    await writeJson(PROJECT_FILE, proj);
    info(`${resolved} ${c.Y}!${c.N} ${c.D}${ov}${c.N}`);
  } else {
    proj.mcpServers[resolved] = entry;
    await writeJson(PROJECT_FILE, proj);
    info(resolved);
  }
  return true;
}

// mcpRemove — remove one entry from the project file.
async function mcpRemove(name: string): Promise<boolean> {
  if (!existsSync(PROJECT_FILE)) die(`no ${PROJECT_FILE} in current directory`);

  const resolved = await fuzzyMatchCurrent(name);
  if (!resolved) return false;

  const proj = await readJson<McpFile>(PROJECT_FILE, { mcpServers: {} });
  delete proj.mcpServers[resolved];
  await writeJson(PROJECT_FILE, proj);
  console.log(`${c.R}-${c.N} ${resolved}`);
  return true;
}

// cmdAdd / cmdRm — profile-aware wrappers over mcpAdd / mcpRemove.

export async function cmdAdd(name: string): Promise<boolean> {
  if (await isProfile(name)) {
    dim(`profile: ${name}`);
    let ok = true;
    for (const m of await profileMembers(name)) {
      if (!(await mcpAdd(m))) ok = false;
    }
    return ok;
  }
  return mcpAdd(name);
}

export async function cmdRm(name: string): Promise<boolean> {
  if (await isProfile(name)) {
    dim(`profile: ${name}`);
    for (const m of await profileMembers(name)) {
      try {
        await mcpRemove(m);
      } catch {
        // profile removal is best-effort per member
      }
    }
    return true;
  }
  return mcpRemove(name);
}

export async function cmdClean(): Promise<void> {
  await writeJson(PROJECT_FILE, { mcpServers: {} });
  info(`cleaned ${PROJECT_FILE}`);
  await autoSync();
}

// --- refresh: rewrite project-file URLs to match current resolution ------
//
// Walks one file (CWD by default) or an entire tree (--walk DIR). Only touches
// entries whose name is in the catalog; manually-added entries are left alone.
// In walk mode, backups are taken under $CONFIG_DIR unless --no-backup.

// findMcpJson — recursively collect .mcp.json under `dir`, skipping the same
// directories the bash --walk skipped.
async function findMcpJson(dir: string): Promise<string[]> {
  const out: string[] = [];
  async function rec(d: string): Promise<void> {
    let entries;
    try {
      entries = await fs.readdir(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const full = join(d, e.name);
      if (e.isDirectory()) {
        if (
          e.name === "node_modules" ||
          e.name === ".git" ||
          e.name === "+archives" ||
          e.name.startsWith("refresh-backup-")
        ) {
          continue;
        }
        await rec(full);
      } else if (e.isFile() && e.name === PROJECT_FILE) {
        out.push(full);
      }
    }
  }
  await rec(dir);
  return out;
}

function backupStamp(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

export async function cmdRefresh(argv: string[]): Promise<number> {
  ensureCatalog();

  let dryRun = false;
  let walkDir = "";
  let noBackup = false;
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case "--dry-run":
        dryRun = true;
        break;
      case "--walk":
        walkDir = argv[++i] ?? "";
        if (!walkDir) die("--walk requires a directory");
        break;
      case "--no-backup":
        noBackup = true;
        break;
      default:
        die(`unknown flag: ${argv[i]} (use --walk DIR, --dry-run, --no-backup)`);
    }
  }

  let files: string[];
  if (walkDir) {
    if (!existsSync(walkDir)) die(`not a directory: ${walkDir}`);
    files = await findMcpJson(walkDir);
  } else {
    if (!existsSync(PROJECT_FILE)) die(`no ${PROJECT_FILE} in ${process.cwd()}`);
    files = [PROJECT_FILE];
  }

  if (files.length === 0) {
    warn("no .mcp.json files found");
    return 1;
  }

  const fileWord = files.length > 1 ? "files" : "file";
  console.log(`${c.B}refresh${c.N} ${c.D}(${files.length} ${fileWord})${c.N}`);

  // Prepare backup directory (walk mode, non-dry-run, backups enabled).
  let bakdir = "";
  if (!dryRun && !noBackup && walkDir) {
    bakdir = join(CONFIG_DIR, `refresh-backup-${backupStamp()}`);
    await fs.mkdir(bakdir, { recursive: true });
  }

  let totalChanged = 0;
  let filesChanged = 0;

  for (const f of files) {
    const proj = await readJson<McpFile>(f, { mcpServers: {} });
    const keys = Object.keys(proj.mcpServers ?? {});
    if (keys.length === 0) continue;

    // Compute the diff: for each key in both `f` and the catalog, compare the
    // current URL to the resolved (override|catalog) URL.
    const changes: { k: string; cur: string; exp: string }[] = [];
    for (const k of keys) {
      if (!(await catalogHas(k))) continue;
      const cur = (proj.mcpServers[k].url as string | undefined) ?? "";
      const exp = await resolveUrl(k);
      if (exp && cur !== exp) changes.push({ k, cur, exp });
    }

    if (changes.length === 0) continue;

    console.log(`  ${c.C}${f}${c.N}`);
    for (const ch of changes) {
      console.log(`    ${ch.k} ${c.D}${ch.cur}${c.N} → ${ch.exp}`);
    }

    if (!dryRun) {
      if (bakdir) {
        const rel = f.replace(/^\//, "");
        const dest = join(bakdir, rel);
        await fs.mkdir(dirname(dest), { recursive: true });
        await fs.copyFile(f, dest);
      }
      for (const ch of changes) proj.mcpServers[ch.k].url = ch.exp;
      await writeJson(f, proj);
    }

    filesChanged++;
    totalChanged += changes.length;
  }

  console.log("");
  if (totalChanged === 0) {
    dim("(no changes — already in sync)");
    return 0;
  }

  const verb = dryRun ? "would be" : "were";
  console.log(`${c.D}${totalChanged} entries across ${filesChanged} file(s) ${verb} rewritten${c.N}`);
  if (bakdir) dim(`backup: ${bakdir}`);

  // Auto-sync only when rewriting the CWD file — walk mode would thrash the
  // external client config for every project visited.
  if (!dryRun && !walkDir) await autoSync();
  return 0;
}

// --- catalog edit ---------------------------------------------------------
// `mcpx @name port` → upsert entry using the default host address.
// `mcpx @name`      → remove entry from the catalog.

export async function cmdCatalog(name: string, port?: string): Promise<number> {
  ensureCatalog();
  const host = await loadHost();

  if (!port) return catalogRemove(name);
  return catalogUpsert(name, port, host.addr);
}

async function catalogRemove(name: string): Promise<number> {
  const cat = await readJson<McpFile>(CATALOG_FILE, { mcpServers: {} });
  if (cat.mcpServers?.[name] == null) {
    console.error(`${c.R}not in catalog:${c.N} ${name}`);
    return 1;
  }
  delete cat.mcpServers[name];
  await writeJson(CATALOG_FILE, cat);
  console.log(`${c.R}-${c.N} ${name} ${c.D}(removed from catalog)${c.N}`);
  return 0;
}

async function catalogUpsert(name: string, port: string, addr: string): Promise<number> {
  const url = buildMcpUrl(addr, port);
  const cat = await readJson<McpFile>(CATALOG_FILE, { mcpServers: {} });
  const existing = cat.mcpServers?.[name];

  if (existing) {
    const oldPort = urlPort(existing.url);
    if (oldPort === port) {
      warn(`${name} already in catalog at :${port}`);
      return 0;
    }
    existing.url = url;
    await writeJson(CATALOG_FILE, cat);
    console.log(`${c.Y}~${c.N} ${name} ${c.D}:${oldPort} → :${port}${c.N}`);
  } else {
    cat.mcpServers[name] = { type: "http", url };
    await writeJson(CATALOG_FILE, cat);
    info(`${name} ${c.D}:${port} → catalog${c.N}`);
  }
  return 0;
}
