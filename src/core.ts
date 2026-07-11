// core — constants, colors, shared helpers (paths, json, url, prompts)
//
// Naming conventions used across src/:
//   *_FILE          absolute path to a JSON state file
//   cmd<Name>       top-level command invoked from the main router
//   ensure<Thing>   precondition check (dies or creates on demand)
//
// The bash original juggled tempdirs and `set -e` traps; in TS that machinery
// collapses into async/await + try/catch, so this module is deliberately small.

import { promises as fs, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import * as readline from "node:readline/promises";

export const VERSION = "0.4.0";

// --- paths ----------------------------------------------------------------

const HOME = homedir();

export const CONFIG_DIR = process.env.MCPX_CONFIG_DIR ?? join(HOME, ".config", "mcpx");
export const CONFIG_FILE = join(CONFIG_DIR, "config.json");
export const CATALOG_FILE = join(CONFIG_DIR, "catalog.json");
export const PROFILES_FILE = join(CONFIG_DIR, "profiles.json");
export const OVERRIDES_FILE = join(CONFIG_DIR, "overrides.json");

// The per-project config that `mcpx` reads/writes in the CWD.
export const PROJECT_FILE = ".mcp.json";

// --- shared types ---------------------------------------------------------

export interface McpEntry {
  type?: string;
  url?: string;
  httpUrl?: string;
  [k: string]: unknown;
}

export interface McpFile {
  mcpServers: Record<string, McpEntry>;
  [k: string]: unknown;
}

export interface HostConfig {
  address: string;
  port_min: number;
  port_max: number;
}

export interface Config {
  default_host?: string;
  hosts: Record<string, HostConfig>;
  sync?: Record<string, boolean>;
}

// A resolved host, returned by loadHost (replaces the bash HOST_* globals).
export interface Host {
  name: string;
  addr: string;
  portMin: number;
  portMax: number;
}

// --- colors (ANSI) --------------------------------------------------------
// Semantic mapping:
//   R = error    G = success    Y = warning
//   C = name/id  B = bold       D = dim/secondary    N = reset
export const c = {
  R: "\x1b[0;31m",
  G: "\x1b[0;32m",
  Y: "\x1b[0;33m",
  C: "\x1b[0;36m",
  B: "\x1b[1m",
  D: "\x1b[0;90m",
  N: "\x1b[0m",
} as const;

// --- user-facing messaging -----------------------------------------------

// Thrown by die(); caught in main() to produce a non-zero exit without a
// stack trace. This mirrors bash `die` (print to stderr, exit 1).
export class DieError extends Error {}

export function die(msg: string): never {
  console.error(`${c.R}error:${c.N} ${msg}`);
  throw new DieError(msg);
}

export function info(msg: string): void {
  console.log(`${c.G}+${c.N} ${msg}`);
}

export function warn(msg: string): void {
  console.log(`${c.Y}~${c.N} ${msg}`);
}

export function dim(msg: string): void {
  console.log(`${c.D}${msg}${c.N}`);
}

// --- filesystem / json helpers -------------------------------------------

export async function ensureConfigDir(): Promise<void> {
  await fs.mkdir(CONFIG_DIR, { recursive: true });
}

export function ensureCatalog(): void {
  if (!existsSync(CATALOG_FILE)) die("no catalog — run: mcpx init");
}

// Guarantees the file exists and contains valid JSON (or the supplied default).
export async function ensureJsonFile(path: string, def = "{}"): Promise<void> {
  await ensureConfigDir();
  if (!existsSync(path)) await fs.writeFile(path, def + "\n");
}

// readJson — parse a JSON file, returning `fallback` on any error (missing
// file, invalid JSON). Callers pass a typed fallback to keep the shape known.
export async function readJson<T>(path: string, fallback: T): Promise<T> {
  try {
    return JSON.parse(await fs.readFile(path, "utf8")) as T;
  } catch {
    return fallback;
  }
}

// writeJson — atomic write (tmp → rename), 2-space indent to match jq output.
export async function writeJson(path: string, data: unknown): Promise<void> {
  const tmp = `${path}.tmp`;
  await fs.writeFile(tmp, JSON.stringify(data, null, 2) + "\n");
  await fs.rename(tmp, path);
}

// --- URL helpers ----------------------------------------------------------

// urlPort — the numeric port embedded in `://host:PORT/...`, or "".
export function urlPort(url: string | null | undefined): string {
  if (!url) return "";
  const m = url.match(/:(\d+)(\/|$)/);
  return m ? m[1] : "";
}

// buildMcpUrl — canonical MCP endpoint URL.
export function buildMcpUrl(host: string, port: string | number): string {
  return `http://${host}:${port}/mcp`;
}

// --- misc helpers ---------------------------------------------------------

// tildify — collapse a leading $HOME to `~` for display.
export function tildify(p: string): string {
  return p.startsWith(HOME) ? "~" + p.slice(HOME.length) : p;
}

// commandExists — is `cmd` an executable on $PATH? (replaces `command -v`).
export function commandExists(cmd: string): boolean {
  const paths = (process.env.PATH ?? "").split(":");
  return paths.some((p) => p && existsSync(join(p, cmd)));
}

// ask — read one line from the user (replaces bash `read -rp`).
export async function ask(question: string): Promise<string> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try {
    return (await rl.question(question)).trim();
  } finally {
    rl.close();
  }
}
