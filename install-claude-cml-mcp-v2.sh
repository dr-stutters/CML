#!/usr/bin/env bash
#
# install-claude-cml-mcp.sh
# Installs the Cisco Modeling Labs (CML) MCP server configuration for Claude Code
# into .claude.json.
#
# Dependencies (jq, node/npm for `npx mcp-remote`) are installed by the companion
# script install-dependencies.sh — run that first if they are missing.
#
# Idempotent: safe to re-run. Makes a timestamped backup of .claude.json before editing.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment variables before running)
# ---------------------------------------------------------------------------
MCP_NAME="${MCP_NAME:-Cisco_Modeling_Labs_CML}"
CML_URL="${CML_URL:-https://198.18.128.10/mcp}"
# Basic auth header value, e.g. "Basic <base64(user:pass)>".
# Default below = admin:YOURPASSWORD
CML_AUTH_HEADER="${CML_AUTH_HEADER:-Basic ***REMOVED***}"
# Project scope to install under (the key inside .claude.json -> projects).
PROJECT_DIR="${PROJECT_DIR:-$HOME}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Verify required dependencies are present (installed by install-dependencies.sh)
# ---------------------------------------------------------------------------
command -v jq  >/dev/null 2>&1 || die "jq not found. Run ./install-dependencies.sh first."
command -v npx >/dev/null 2>&1 || die "npx (Node.js) not found. Run ./install-dependencies.sh first."

# ---------------------------------------------------------------------------
# 1. Build the MCP server config and merge into .claude.json
# ---------------------------------------------------------------------------
log "Installing MCP config '$MCP_NAME' under project '$PROJECT_DIR' in $CLAUDE_JSON"

# Create .claude.json if it does not exist.
if [[ ! -f "$CLAUDE_JSON" ]]; then
  echo '{}' > "$CLAUDE_JSON"
  ok "Created new $CLAUDE_JSON"
fi

# Validate existing JSON before touching it.
jq empty "$CLAUDE_JSON" 2>/dev/null || die "$CLAUDE_JSON is not valid JSON; aborting."

# Timestamped backup.
BACKUP="${CLAUDE_JSON}.bak.$(date +%Y%m%d-%H%M%S)"
cp -p "$CLAUDE_JSON" "$BACKUP"
ok "Backed up to $BACKUP"

# The server config (matches the working mcp-remote setup).
SERVER_JSON="$(jq -n \
  --arg url  "$CML_URL" \
  --arg auth "$CML_AUTH_HEADER" \
  '{
     command: "npx",
     args: ["-y", "mcp-remote", $url, "--header", "X-Authorization:${CML_AUTH_HEADER}"],
     env: {
       CML_AUTH_HEADER: $auth,
       NODE_TLS_REJECT_UNAUTHORIZED: "0"
     }
   }')"

# Merge: ensure projects[PROJECT_DIR].mcpServers[MCP_NAME] = SERVER_JSON
TMP="$(mktemp)"
jq \
  --arg proj "$PROJECT_DIR" \
  --arg name "$MCP_NAME" \
  --argjson server "$SERVER_JSON" \
  '
   .projects               = (.projects // {})
 | .projects[$proj]        = (.projects[$proj] // {})
 | .projects[$proj].mcpServers           = (.projects[$proj].mcpServers // {})
 | .projects[$proj].mcpServers[$name]    = $server
  ' "$CLAUDE_JSON" > "$TMP"

# Validate the result before replacing.
jq empty "$TMP" 2>/dev/null || { rm -f "$TMP"; die "Generated JSON was invalid; original left untouched (backup at $BACKUP)."; }

mv "$TMP" "$CLAUDE_JSON"
ok "MCP server '$MCP_NAME' written to $CLAUDE_JSON"

# ---------------------------------------------------------------------------
# 2. Summary
# ---------------------------------------------------------------------------
echo
ok "Done. Verify the MCP config with:"
echo "    jq '.projects[\"$PROJECT_DIR\"].mcpServers[\"$MCP_NAME\"]' \"$CLAUDE_JSON\""
echo
log "Restart Claude Code (or run '/mcp' inside it) to connect to CML at $CML_URL"
warn "Note: NODE_TLS_REJECT_UNAUTHORIZED=0 disables TLS cert checks (CML uses a self-signed cert)."
