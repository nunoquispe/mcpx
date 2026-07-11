// profiles — named groups of MCPs
//
// Profiles live in $PROFILES_FILE as { "<name>": ["mcp1", "mcp2", ...] }.
// `mcpx +<name>` checks profiles before the catalog so `+dev` expands to
// every MCP in the "dev" profile.

import {
  c,
  die,
  info,
  dim,
  readJson,
  writeJson,
  ensureJsonFile,
  ensureCatalog,
  PROFILES_FILE,
} from "./core.ts";
import { fuzzyMatch } from "./fuzzy.ts";

type Profiles = Record<string, string[]>;

async function readProfiles(): Promise<Profiles> {
  return readJson<Profiles>(PROFILES_FILE, {});
}

// isProfile — true iff <name> is a defined profile.
export async function isProfile(name: string): Promise<boolean> {
  const p = await readProfiles();
  return Array.isArray(p[name]);
}

// profileMembers — the members of <name> (no validation).
export async function profileMembers(name: string): Promise<string[]> {
  const p = await readProfiles();
  return p[name] ?? [];
}

export async function ensureProfiles(): Promise<void> {
  await ensureJsonFile(PROFILES_FILE);
}

// --- commands -------------------------------------------------------------

export async function cmdProfileSave(name: string, members: string[]): Promise<number> {
  await ensureProfiles();
  ensureCatalog();

  if (!name) die("usage: mcpx :save <name> <mcp1> <mcp2> ...");
  if (members.length === 0) die("provide at least one MCP name");

  // Resolve every member through catalog fuzzy-match first: if any one fails
  // we abort before touching the profile file.
  const resolved: string[] = [];
  for (const m of members) {
    const r = await fuzzyMatch(m);
    if (!r) return 1;
    resolved.push(r);
  }

  const profiles = await readProfiles();
  profiles[name] = resolved;
  await writeJson(PROFILES_FILE, profiles);

  info(`profile ${c.C}${name}${c.N} (${resolved.length} MCPs)`);
  for (const m of resolved) console.log(`  ${m}`);
  return 0;
}

export async function cmdProfileLs(): Promise<void> {
  await ensureProfiles();
  const profiles = await readProfiles();
  const names = Object.keys(profiles);
  if (names.length === 0) {
    dim("(no profiles)");
    return;
  }

  console.log(`${c.B}profiles${c.N}`);
  for (const name of names) {
    const members = profiles[name];
    console.log(`  ${c.C}${name}${c.N} ${c.D}(${members.length})${c.N} ${c.D}${members.join(", ")}${c.N}`);
  }
}

export async function cmdProfileRm(name: string): Promise<number> {
  await ensureProfiles();
  const profiles = await readProfiles();
  if (!Array.isArray(profiles[name])) die(`profile '${name}' not found`);

  delete profiles[name];
  await writeJson(PROFILES_FILE, profiles);
  console.log(`${c.R}-${c.N} profile ${name}`);
  return 0;
}
