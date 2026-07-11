// fuzzy — fuzzy name matching (literal-string safe)
//
// Strategy (in order): exact → unique prefix → unique substring.
// Ambiguous matches are reported on stderr with the candidate list; no match
// is reported on stderr with a hint. Inputs are treated as literal strings
// (never regex) so names containing regex metacharacters are safe.

import { existsSync } from "node:fs";
import { c, die, readJson, CATALOG_FILE, PROJECT_FILE, type McpFile } from "./core.ts";

// catalogNames — one name per entry, sorted.
export async function catalogNames(): Promise<string[]> {
  const j = await readJson<McpFile>(CATALOG_FILE, { mcpServers: {} });
  return Object.keys(j.mcpServers ?? {}).sort();
}

// projectNames — names from the CWD project file, sorted.
export async function projectNames(): Promise<string[]> {
  const j = await readJson<McpFile>(PROJECT_FILE, { mcpServers: {} });
  return Object.keys(j.mcpServers ?? {}).sort();
}

// fuzzyFindIn — resolve <query> against a list of names.
// Returns the unique matched name, or null on ambiguity / no-match. When
// `quiet` is set, no diagnostics are written to stderr (used for the
// serverInfo→catalog matching in overrides, which tries many tokens).
export function fuzzyFindIn(query: string, names: string[], quiet = false): string | null {
  // 1. exact match
  if (names.includes(query)) return query;

  // 2. unique prefix match (e.g. "ssh-d" → "ssh-dev")
  const prefix = names.filter((n) => n.startsWith(query));
  if (prefix.length === 1) return prefix[0];

  // 3. unique substring match (e.g. "duck" → "duckdb-files-enterprise")
  const sub = names.filter((n) => n.includes(query));
  if (sub.length === 1) return sub[0];

  if (sub.length > 1) {
    if (!quiet) {
      console.error(`${c.Y}ambiguous:${c.N} '${query}' matches:`);
      for (const s of sub) console.error(`  ${s}`);
    }
    return null;
  }

  if (!quiet) console.error(`${c.R}no match:${c.N} '${query}'`);
  return null;
}

// fuzzyMatch — resolve against the catalog.
export async function fuzzyMatch(query: string): Promise<string | null> {
  return fuzzyFindIn(query, await catalogNames());
}

// fuzzyMatchCurrent — resolve against the current project file.
export async function fuzzyMatchCurrent(query: string): Promise<string | null> {
  if (!existsSync(PROJECT_FILE)) die(`no ${PROJECT_FILE} in current directory`);
  const names = await projectNames();
  if (names.length === 0) die(`${PROJECT_FILE} is empty`);
  return fuzzyFindIn(query, names);
}
