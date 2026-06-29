# CML

A collection of scripts and tooling I use to **build, reach, and automate Cisco
Modeling Labs (CML)** — and to wire CML into [Claude Code](https://claude.com/claude-code)
as an MCP server so labs can be driven by natural language.

The typical environment is a **Cisco dCloud** CML instance reachable over an
AnyConnect VPN, on the `198.18.128.0/18` lab network. The scripts here handle the
three things you need before any automation works: get on the lab network, install
the local dependencies, and register the CML MCP server with Claude Code.

---

## Quick start

```bash
# 1. Get onto the lab network (dCloud VPN)
sudo ./vpn_dcloud-up.sh

# 2. Install local dependencies (jq, Node/npm, pyATS)
./install-dependencies.sh

# 3. Register the CML MCP server with Claude Code
#    (edit the CML URL + credentials at the top of the script first)
./install-claude-cml-mcp-v2.sh

# ...drive CML from Claude Code via the MCP server...

# 4. Tear the VPN down when finished
sudo ./vpn_dcloud-down.sh
```

> Steps 2 and 3 can be combined by running the all-in-one
> [`install-claude-cml-mcp.sh`](install-claude-cml-mcp.sh) instead.

---

## What's in here

### Networking — reach the lab

| Script | Purpose |
|--------|---------|
| [`vpn_dcloud-up.sh`](vpn_dcloud-up.sh) | Connects to the Cisco dCloud Sydney AnyConnect VPN via **OpenConnect** as a split tunnel. Always routes `198.18.128.0/18` (the CML/lab network) through the tunnel; extra subnets/hosts can be added as arguments. Uses `vpn-slice` so only lab routes/DNS are touched and the rest of your traffic stays on the normal internet path. Run with `sudo`. |
| [`vpn_dcloud-down.sh`](vpn_dcloud-down.sh) | Cleanly disconnects the VPN started above (SIGTERM so OpenConnect tears down its routes/DNS, with a forced fallback). Run with `sudo`. |

**Why:** the CML controller and lab devices live on `198.18.128.0/18`, which is
only reachable through the dCloud VPN. Nothing else here works until the tunnel is up.

### Setup — install dependencies & register the MCP server

| Script | Purpose |
|--------|---------|
| [`install-dependencies.sh`](install-dependencies.sh) | Installs the local prerequisites: `jq` (JSON editing), **Node.js/npm** (provides `npx` for `mcp-remote`), and **Cisco pyATS** into a Python virtualenv (`~/pyats` by default). Distro-aware (apt/dnf/yum/pacman/zypper) and idempotent. Skip pyATS with `INSTALL_PYATS=0`. |
| [`install-claude-cml-mcp-v2.sh`](install-claude-cml-mcp-v2.sh) | **Recommended config installer.** Assumes dependencies are already present (run `install-dependencies.sh` first) and only writes the CML MCP server entry into `~/.claude.json`. Backs the file up first and validates the JSON before/after. |
| [`install-claude-cml-mcp.sh`](install-claude-cml-mcp.sh) | All-in-one variant: does everything `install-dependencies.sh` does (deps + pyATS) **and** writes the MCP config in a single run. Handy for a fresh machine. |

**Why:** Claude Code talks to CML through an MCP server. Cisco ships the MCP
endpoint on the controller itself (`https://<cml>/mcp`); these scripts launch it
locally with `npx mcp-remote` and merge the right entry (URL + auth header) into
your `~/.claude.json` so Claude Code can connect.

**Before running the config installers**, set the controller URL and credentials
at the top of the script (or via environment variables):

```bash
CML_URL="https://<your-cml-host>/mcp" \
CML_AUTH_HEADER="Basic $(printf 'admin:YOURPASSWORD' | base64)" \
./install-claude-cml-mcp-v2.sh
```

> Note: the MCP config sets `NODE_TLS_REJECT_UNAUTHORIZED=0` because CML uses a
> self-signed certificate by default.

### Tooling — extend what the MCP can do

| Folder | Purpose |
|--------|---------|
| [`cml-images-mcp/`](cml-images-mcp/) | A standalone **TypeScript MCP server** that adds CML **image & node definition management** — uploading disk images (`.qcow2`, from a local path or URL) and creating/deleting image and node definitions. These operations are *not* exposed by Cisco's built-in CML MCP. Built against the CML 2.10 `/api/v0` REST API. See its [README](cml-images-mcp/README.md) for tools and setup. |

**Why:** the stock CML MCP can build topologies and drive nodes but can't install
new platform images. `cml-images-mcp` fills that gap so you can onboard images
(e.g. FTDv, FMCv, ASAv) end-to-end from Claude Code.

---

## Requirements

- Linux with `bash` and one of: apt / dnf / yum / pacman / zypper
- `sudo` and **OpenConnect** + [`vpn-slice`](https://github.com/dlenski/vpn-slice) for the VPN scripts
- Node.js ≥ 18 (installed by `install-dependencies.sh`)
- A CML instance reachable on the lab network, plus valid credentials

## Security note

These scripts target a lab environment and some carry example/default credentials.
**Always replace the default CML URL and credentials with your own** before running,
and never commit real passwords. The MCP config disables TLS verification for CML's
self-signed certificate.
