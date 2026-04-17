# mcpx

Fast MCP config manager for self-hosted Model Context Protocol servers.

```
mcpx +pg +ssh-d        add MCPs to .mcp.json (fuzzy match)
mcpx -pg               remove
mcpx scan              discover live MCPs on your network
```

## Why mcpx?

Tools like [mcpm](https://mcpm.sh) and [mcp-get](https://github.com/michaellatman/mcp-get) work great for **public** MCP registries. But if you run your own MCP servers on a local machine, VPS, or homelab — there's nothing to manage them.

**mcpx** fills that gap:

- **Private catalog** — your own registry of self-hosted MCPs
- **Fuzzy matching** — `pg` → `pg-enterprise`, `ssh-d` → `ssh-dev`
- **Port scanning** — discover live MCPs across your network
- **Zero dependencies** — just bash, jq, and curl

## Install

```bash
# Option 1: curl
curl -fsSL https://raw.githubusercontent.com/nunoquispe/mcpx/main/install.sh | bash

# Option 2: Homebrew
brew install nunoquispe/tap/mcpx

# Option 3: manual
curl -fsSL https://raw.githubusercontent.com/nunoquispe/mcpx/main/mcpx -o /usr/local/bin/mcpx
chmod +x /usr/local/bin/mcpx
```

**Requirements:** `jq` and `curl` (both pre-installed on macOS).

## Quick start

```bash
# 1. Initialize with your MCP host
mcpx init
# → Host name: mini
# → Host address: 192.168.1.50
# → Port range: 3200-3250

# 2. Scan for live MCPs
mcpx scan
#   * :3201 mysql-enterprise
#   * :3202 pg-enterprise
#   ? :3205 (not in catalog)

# 3. Register unknown MCPs
mcpx @duckdb 3205

# 4. Add MCPs to your project's .mcp.json
mcpx +pg +mysql
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

### Catalog management

```bash
mcpx ls                # list catalog (* = active in current .mcp.json)
mcpx @my-server 3201   # add to catalog
mcpx @my-server 3205   # update port
mcpx @my-server        # remove from catalog
```

### Discovery

```bash
mcpx scan              # scan default host
mcpx scan staging      # scan a specific host
```

### Multi-host

```bash
mcpx hosts                          # list hosts
mcpx host add staging 10.0.0.5     # add host (default port range 3200-3250)
mcpx host add prod 10.0.0.6 8000 8050  # custom port range
```

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
├── config.json     # hosts and settings
└── catalog.json    # your MCP registry
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

## How it works

mcpx manages two things:

1. **Catalog** (`~/.config/mcpx/catalog.json`) — your private registry of all available MCPs
2. **Project config** (`.mcp.json` in cwd) — which MCPs are active for this project

`mcpx +name` copies an entry from the catalog into your project's `.mcp.json`. That's it — no daemons, no lock files, no magic.

`mcpx scan` does parallel HTTP probes across a port range to find live MCP servers, then shows which ones are already in your catalog.

## License

MIT
