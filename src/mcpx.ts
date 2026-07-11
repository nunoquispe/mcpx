#!/usr/bin/env bun
// mcpx — fast MCP config manager for .mcp.json
// https://github.com/nunoquispe/mcpx
//
// Entry point + command routing. Mirrors the dispatch of the bash original.

import { c, warn, die, DieError, VERSION } from "./core.ts";
import {
  cmdShow,
  cmdList,
  cmdClean,
  cmdRefresh,
  cmdCatalog,
  cmdAdd,
  cmdRm,
} from "./catalog.ts";
import { cmdInit, cmdHosts, cmdHostAdd } from "./config.ts";
import { cmdScan } from "./scan.ts";
import {
  cmdOverrideLs,
  cmdOverrideSet,
  cmdOverrideRm,
  cmdOverrideClear,
  cmdOverrideFrom,
} from "./overrides.ts";
import { cmdSyncStatus, cmdSyncSet, autoSync } from "./sync.ts";
import { cmdProfileSave, cmdProfileLs, cmdProfileRm } from "./profiles.ts";

const HELP = `mcpx — fast MCP config manager

Usage:
  mcpx                     show .mcp.json (CWD + inherited from parents)
  mcpx ls                  list catalog (* = active in .mcp.json)
  mcpx +name               add MCP to .mcp.json (fuzzy match)
  mcpx -name               remove MCP from .mcp.json (fuzzy match)
  mcpx +a +b -c            mix add/remove in one shot
  mcpx 0                   truncate .mcp.json

Profiles:
  mcpx :save dev pg ssh-d  save profile "dev" with MCPs
  mcpx :ls                 list profiles
  mcpx :rm dev             delete profile
  mcpx +dev                add all MCPs in profile (auto-detected)
  mcpx -dev                remove all MCPs in profile

Catalog:
  mcpx @name port          add/update MCP in catalog
  mcpx @name               remove MCP from catalog

Discovery:
  mcpx scan [host]         scan host ports for live MCPs
  mcpx hosts               list configured hosts

Overrides (temporary URL remapping):
  mcpx override ls                      list active overrides
  mcpx override set <name> <url>        set override for a catalog entry
  mcpx override rm <name>                remove an override
  mcpx override clear                   remove all overrides
  mcpx override from <host>             scan host, auto-create overrides
                                        flags: --dry-run, --yes
  mcpx refresh                          rewrite CWD .mcp.json to match overrides
  mcpx refresh --walk <dir>             rewrite all .mcp.json under <dir>
                                        flags: --dry-run, --no-backup

Sync:
  mcpx sync                show sync targets status
  mcpx sync codex true     enable auto-sync to Codex
  mcpx sync gemini true    enable auto-sync to Gemini
  mcpx sync <target> false disable auto-sync

Setup:
  mcpx init                initialize config (~/.config/mcpx/)
  mcpx -v, --version       show version
  mcpx -h, --help          show this help

Fuzzy matching:
  "pg"    → pg-enterprise
  "ssh-d" → ssh-dev
  "duck"  → duckdb-files-enterprise

Environment:
  MCPX_CONFIG_DIR          override config dir (default: ~/.config/mcpx)`;

// route — dispatch argv, returning the process exit code.
async function route(argv: string[]): Promise<number> {
  // No args: show current config.
  if (argv.length === 0) {
    await cmdShow();
    return 0;
  }

  const a0 = argv[0];

  // Named commands.
  switch (a0) {
    case "-v":
    case "--version":
    case "version":
      console.log(`mcpx ${VERSION}`);
      return 0;
    case "-h":
    case "--help":
    case "help":
      console.log(HELP);
      return 0;
    case "init":
      await cmdInit();
      return 0;
    case "hosts":
      await cmdHosts();
      return 0;
    case "?":
    case "ls":
    case "list":
      await cmdList();
      return 0;
    case "0":
    case "clean":
      await cmdClean();
      return 0;
    case "scan":
      await cmdScan(argv[1]);
      return 0;
    case "refresh":
      return cmdRefresh(argv.slice(1));
    case "override":
    case "ov": {
      const sub = argv[1] ?? "ls";
      const rest = argv.slice(2);
      switch (sub) {
        case "ls":
        case "list":
          await cmdOverrideLs();
          return 0;
        case "set":
          return cmdOverrideSet(rest[0], rest[1]);
        case "rm":
        case "del":
          return cmdOverrideRm(rest[0]);
        case "clear":
          await cmdOverrideClear();
          return 0;
        case "from":
          return cmdOverrideFrom(rest);
        default:
          die(`unknown: override ${sub} (use ls|set|rm|clear|from)`);
      }
      return 0;
    }
    case "sync":
      if (argv.length >= 3) {
        await cmdSyncSet(argv[1], argv[2]);
      } else {
        await cmdSyncStatus();
      }
      return 0;
    case "host": {
      const sub = argv[1];
      if (sub === "add") {
        await cmdHostAdd(argv[2], argv[3], Number(argv[4] ?? 3200), Number(argv[5] ?? 3250));
      } else {
        await cmdHosts();
      }
      return 0;
    }
  }

  // : commands — profile management.
  if (a0.startsWith(":")) {
    const subcmd = a0.slice(1);
    const rest = argv.slice(1);
    switch (subcmd) {
      case "save":
      case "s":
        return cmdProfileSave(rest[0], rest.slice(1));
      case "ls":
      case "list":
        await cmdProfileLs();
        return 0;
      case "rm":
        return cmdProfileRm(rest[0]);
      default:
        die(`unknown: :${subcmd} (use :save, :ls, :rm)`);
    }
  }

  // @ commands — catalog management.
  if (a0.startsWith("@")) {
    const name = a0.slice(1);
    if (!name) die("usage: mcpx @name [port]");
    return cmdCatalog(name, argv[1]);
  }

  // +/- operations.
  let errors = 0;
  for (const arg of argv) {
    if (arg.startsWith("+")) {
      if (!(await cmdAdd(arg.slice(1)))) errors++;
    } else if (arg.startsWith("-")) {
      if (!(await cmdRm(arg.slice(1)))) errors++;
    } else {
      warn(`unknown: ${arg} (try: mcpx --help)`);
      errors++;
    }
  }

  if (errors < argv.length) {
    console.log("");
    await cmdShow();
    await autoSync();
  }

  return errors;
}

async function main(): Promise<void> {
  try {
    process.exitCode = await route(process.argv.slice(2));
  } catch (err) {
    if (err instanceof DieError) {
      process.exitCode = 1;
      return;
    }
    // Unexpected error — surface it rather than swallowing.
    console.error(`${c.R}error:${c.N} ${err instanceof Error ? err.message : String(err)}`);
    process.exitCode = 1;
  }
}

await main();
