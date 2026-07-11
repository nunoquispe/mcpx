# mcpx

Fast MCP config manager for self-hosted Model Context Protocol servers.

```
mcpx +pg +ssh-d        add MCPs to .mcp.json (fuzzy match)
mcpx -pg               remove
mcpx scan              discover live MCPs on your network
mcpx +dev              add a whole profile at once
```

## Why mcpx?

Tools like [mcpm](https://mcpm.sh) and [mcp-get](https://github.com/michaellatman/mcp-get) work great for **public** MCP registries. But if you run your own MCP servers on a local machine, VPS, or homelab — there's nothing to manage them.

**mcpx** fills that gap:

- **Private catalog** — your own registry of self-hosted MCPs
- **Fuzzy matching** — `pg` → `pg-enterprise`, `ssh-d` → `ssh-dev`
- **Port scanning** — discover live MCPs with server info and tool lists
- **Profiles** — group MCPs and add/remove them as a set
- **Multi-client sync** — auto-sync to Gemini and Codex (and more coming)
- **Single static binary** — compiled with Bun; no runtime, no jq/curl needed

## Install

```bash
# Option 1: Homebrew (builds from source)
brew install nunoquispe/tap/mcpx

# Option 2: prebuilt binary (macOS/Linux) from GitHub Releases
curl -fsSL "https://github.com/nunoquispe/mcpx/releases/latest/download/mcpx-$(uname -s)-$(uname -m)" -o /usr/local/bin/mcpx
chmod +x /usr/local/bin/mcpx

# Option 3: build from source (requires Bun)
git clone https://github.com/nunoquispe/mcpx
cd mcpx && bun install && bun run build
cp ./mcpx /usr/local/bin/mcpx
```

**Runtime requirements:** none — `mcpx` is a self-contained binary. Building from
source needs [Bun](https://bun.sh).

## Quick start

```bash
# 1. Initialize with your MCP host
mcpx init
# → Host name: mini
# → Host address: 192.168.1.50
# → Port range: 3200-3250
# → Sync to Codex? Y

# 2. Scan for live MCPs
mcpx scan
#   * :3201 mysql-mcp-server v0.1.0  7t [mysql_query,mysql_write,...]
#   * :3202 pg-mcp-server v0.1.0     3t [pg_query,pg_exec_func,pg_to_s3]
#   ? :3205 duckdb-files v0.1.0      3t [duckdb_file_query,...]

# 3. Register unknown MCPs
mcpx @duckdb 3205

# 4. Add MCPs to your project
mcpx +pg +mysql

# 5. Save a profile for reuse
mcpx :save dev pg ssh-d git deploy
mcpx +dev    # add all 4 at once next time
```

## Usage

### Project config (`.mcp.json` in current directory)

```bash
mcpx                    # show current config
mcpx +pg               # add pg-enterprise (fuzzy match)
mcpx +ssh-d +git       # add multiple
mcpx -pg               # remove
mcpx +aws -hana        # mix add/remove in one shot
mcpx 0                 # truncate to empty
```

### Profiles

```bash
mcpx :save dev pg ssh-d git   # save profile "dev"
mcpx :save obs aws cloud      # save profile "obs"
mcpx :ls                       # list profiles
mcpx +dev                      # add all MCPs in profile
mcpx -dev                      # remove all MCPs in profile
mcpx :rm dev                   # delete profile
```

Profiles are checked before the catalog, so `+dev` expands the profile if it exists, otherwise fuzzy-matches against the catalog.

### Catalog management

```bash
mcpx ls                # list catalog (* = active in current .mcp.json)
mcpx @my-server 3201   # add to catalog
mcpx @my-server 3205   # update port
mcpx @my-server        # remove from catalog
```

### Discovery

```bash
mcpx scan              # scan default host (with MCP protocol probe)
mcpx scan staging      # scan a specific host
```

Scan does a 2-phase discovery:
1. Parallel HTTP probe across the port range
2. MCP protocol handshake on live ports to get server name, version, and tool list

### Multi-host

```bash
mcpx hosts                             # list hosts
mcpx host add staging 10.0.0.5        # add host (default port range 3200-3250)
mcpx host add prod 10.0.0.6 8000 8050 # custom port range
```

### Overrides (contingency URL remapping)

When your MCP host goes down and you spin up a local fallback on different
ports, overrides redirect catalog entries to alternate URLs **without
touching the catalog**. Resolution happens at `+add` time and at `refresh`
time — catalog stays pristine and reverting is one command.

```bash
# One-shot: scan a local fallback host, auto-match by server name, apply
mcpx host add local 127.0.0.1 3100 3150
mcpx override from local --dry-run   # preview
mcpx override from local             # prompts before applying
mcpx override from local --yes       # skip prompt

# Rewrite existing .mcp.json files to pick up overrides
mcpx refresh                          # CWD only
mcpx refresh --walk ~/Dev --dry-run   # preview across tree
mcpx refresh --walk ~/Dev             # apply (backup in $MCPX_CONFIG_DIR)

# Manual control
mcpx override ls
mcpx override set pg http://127.0.0.1:3101/mcp
mcpx override rm pg

# When the original host is back
mcpx override clear
mcpx refresh --walk ~/Dev             # reverts URLs to catalog
```

`mcpx ls` marks overridden entries with `!→`, and `mcpx +name` writes the
effective URL (override-first, catalog-fallback). Entries with active
overrides appear as `name :port !` in `mcpx` (CWD show).

`override from <host>` fuzzy-matches each live MCP's `serverInfo.name`
against catalog names (token-by-token, longest-token-first). Unmatched
entries are listed so you can register them manually with `@name port`.

`refresh` only touches entries whose name exists in the catalog —
manually-added entries in your `.mcp.json` are left alone. `--walk` skips
`+archives/`, `node_modules/`, `.git/`, and prior backup directories.

### Sync

Auto-sync your `.mcp.json` to other AI coding tools:

```bash
mcpx sync                # show sync status
mcpx sync gemini true    # enable auto-sync to .gemini/settings.json
mcpx sync codex true     # enable auto-sync to ~/.codex/config.toml
mcpx sync gemini false   # disable
```

When enabled, every `+`, `-`, and `0` operation automatically updates the target config.

## Fuzzy matching

mcpx matches your input against the catalog using prefix and substring matching:

| Input | Matches |
|-------|---------|
| `pg` | `pg-enterprise` |
| `ssh-d` | `ssh-dev` |
| `duck` | `duckdb-files-enterprise` |
| `ssh` | ambiguous → shows `ssh-dev`, `ssh-hana`, `ssh-win` |

## Config

Config lives in `~/.config/mcpx/` (override with `MCPX_CONFIG_DIR`):

```
~/.config/mcpx/
├── config.json      # hosts, sync settings
├── catalog.json     # your MCP registry
├── profiles.json    # saved MCP groups
└── overrides.json   # temporary URL remaps (see Overrides)
```

### config.json

```json
{
  "default_host": "mini",
  "hosts": {
    "mini": {
      "address": "192.168.1.50",
      "port_min": 3200,
      "port_max": 3250
    }
  },
  "sync": {
    "codex": true
  }
}
```

### catalog.json

```json
{
  "mcpServers": {
    "pg-enterprise": {
      "type": "http",
      "url": "http://192.168.1.50:3202/mcp"
    }
  }
}
```

## Project structure

```
mcpx/
├── src/
│   ├── mcpx.ts      # entry + command router
│   ├── core.ts      # constants, colors, shared helpers (paths, json, url, prompts)
│   ├── fuzzy.ts     # fuzzy name matching (literal-string safe)
│   ├── overrides.ts # temporary URL remapping (override-first resolution)
│   ├── sync.ts      # auto-sync to external clients (Codex, Gemini)
│   ├── config.ts    # init, hosts, loadHost → resolved Host
│   ├── profiles.ts  # named groups of MCPs
│   ├── catalog.ts   # show/list/add/remove/refresh/catalog edit
│   └── scan.ts      # parallel HTTP probe + MCP handshake (fetch/SSE)
├── package.json     # `bun run build` → compiles the `mcpx` binary
├── tsconfig.json
├── install.sh       # curl installer
├── README.md
└── LICENSE
```

Development: edit files in `src/`, run `bun run dev <args>` to execute from
source, `bun run typecheck` to run `tsc`, and `bun run build` to compile the
`mcpx` binary.

## How it works

mcpx manages three things:

1. **Catalog** (`catalog.json`) — your private registry of all available MCPs
2. **Profiles** (`profiles.json`) — named groups of MCPs for batch operations
3. **Project config** (`.mcp.json` in cwd) — which MCPs are active for this project

`mcpx +name` copies an entry from the catalog into your project's `.mcp.json`. If sync targets are enabled, it also updates their configs. That's it — no daemons, no lock files, no magic.

`mcpx scan` does parallel HTTP probes across a port range, then performs MCP protocol handshakes on live ports to get server names, versions, and tool inventories.

## License

MIT
