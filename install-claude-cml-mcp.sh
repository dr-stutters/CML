#!/usr/bin/env bash
#
# install-claude-cml-mcp.sh
# Installs the Cisco Modeling Labs (CML) MCP server configuration for Claude Code into .claude.json
# and any required Linux dependencies (Node.js/npm for `npx mcp-remote`, jq for JSON editing).
#
# Idempotent: safe to re-run. Makes a timestamped backup of .claude.json before editing.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment variables before running)
# ---------------------------------------------------------------------------
MCP_NAME="${MCP_NAME:-Cisco_Modeling_Labs_CML}"
CML_URL="${CML_URL:-https://<CML_IP_ADDRESS>/mcp}"
# Basic auth header value, e.g. "Basic <base64(user:pass)>".
# Generate with: printf 'admin:YOURPASSWORD' | base64
CML_AUTH_HEADER="${CML_AUTH_HEADER:-Basic <REMOVED-ADD-PASSWORD-IN-BASE64>}"
# Project scope to install under (the key inside .claude.json -> projects).
PROJECT_DIR="${PROJECT_DIR:-$HOME}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"

# pyATS install options
INSTALL_PYATS="${INSTALL_PYATS:-1}"           # set to 0 to skip pyATS
PYATS_VENV="${PYATS_VENV:-$HOME/pyats}"        # virtualenv location
PYATS_EXTRA="${PYATS_EXTRA:-full}"            # pip extra: full | library | (empty for core)

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Detect package manager (for installing dependencies)
# ---------------------------------------------------------------------------
SUDO=""
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 && SUDO="sudo"
fi

PKG=""
if   command -v apt-get >/dev/null 2>&1; then PKG="apt"
elif command -v dnf     >/dev/null 2>&1; then PKG="dnf"
elif command -v yum     >/dev/null 2>&1; then PKG="yum"
elif command -v pacman  >/dev/null 2>&1; then PKG="pacman"
elif command -v zypper  >/dev/null 2>&1; then PKG="zypper"
fi

pkg_install() {
  local pkgs=("$@")
  case "$PKG" in
    apt)    $SUDO apt-get update -qq && $SUDO apt-get install -y "${pkgs[@]}" ;;
    dnf)    $SUDO dnf install -y "${pkgs[@]}" ;;
    yum)    $SUDO yum install -y "${pkgs[@]}" ;;
    pacman) $SUDO pacman -Sy --noconfirm "${pkgs[@]}" ;;
    zypper) $SUDO zypper install -y "${pkgs[@]}" ;;
    *)      die "No supported package manager found. Install these manually: ${pkgs[*]}" ;;
  esac
}

# ---------------------------------------------------------------------------
# 2. Ensure dependencies: jq, node, npm (npx)
# ---------------------------------------------------------------------------
log "Checking dependencies..."

if ! command -v jq >/dev/null 2>&1; then
  log "Installing jq..."
  pkg_install jq
fi
command -v jq >/dev/null 2>&1 || die "jq is required but could not be installed."
ok "jq present: $(jq --version)"

if ! command -v npx >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
  log "Installing Node.js / npm (provides npx for mcp-remote)..."
  case "$PKG" in
    apt)    pkg_install nodejs npm ;;
    dnf|yum) pkg_install nodejs npm ;;
    pacman) pkg_install nodejs npm ;;
    zypper) pkg_install nodejs npm ;;
    *)      die "Install Node.js (>=18) and npm manually." ;;
  esac
fi
command -v node >/dev/null 2>&1 || die "node is required but could not be installed."
command -v npx  >/dev/null 2>&1 || die "npx is required but could not be installed."
ok "node present: $(node --version),  npx present: $(npx --version)"

# Warn if node is too old for mcp-remote (needs >=18)
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [[ "$NODE_MAJOR" -lt 18 ]]; then
  warn "Node $(node --version) is older than v18; mcp-remote may not work. Consider nvm or NodeSource."
fi

# Pre-warm the mcp-remote package so first launch is fast (optional, non-fatal).
log "Pre-fetching mcp-remote via npx (this may take a moment)..."
npx -y mcp-remote --help >/dev/null 2>&1 || warn "Could not pre-fetch mcp-remote; it will be fetched on first use."

# ---------------------------------------------------------------------------
# 3. Install pyATS (Cisco test/automation framework) into a virtualenv
# ---------------------------------------------------------------------------
if [[ "$INSTALL_PYATS" == "1" ]]; then
  log "Installing pyATS into virtualenv: $PYATS_VENV"

  # Ensure python3 + venv + pip + build prereqs (pyATS has C extensions).
  if ! command -v python3 >/dev/null 2>&1; then
    log "Installing python3..."
    case "$PKG" in
      apt)     pkg_install python3 python3-venv python3-pip python3-dev build-essential ;;
      dnf|yum) pkg_install python3 python3-pip python3-devel gcc gcc-c++ make ;;
      pacman)  pkg_install python python-pip base-devel ;;
      zypper)  pkg_install python3 python3-pip python3-devel gcc gcc-c++ make ;;
      *)       die "Install python3 (>=3.8), pip and venv manually." ;;
    esac
  else
    # python3 exists; make sure venv + build tooling are present (apt splits these out).
    case "$PKG" in
      apt)     pkg_install python3-venv python3-dev build-essential || true ;;
      dnf|yum) pkg_install python3-pip python3-devel gcc gcc-c++ make || true ;;
      zypper)  pkg_install python3-pip python3-devel gcc gcc-c++ make || true ;;
    esac
  fi
  command -v python3 >/dev/null 2>&1 || die "python3 is required but could not be installed."

  PY_MINOR="$(python3 -c 'import sys; print(sys.version_info[1])' 2>/dev/null || echo 0)"
  PY_MAJOR="$(python3 -c 'import sys; print(sys.version_info[0])' 2>/dev/null || echo 0)"
  if [[ "$PY_MAJOR" -lt 3 || ( "$PY_MAJOR" -eq 3 && "$PY_MINOR" -lt 8 ) ]]; then
    warn "Python $(python3 --version 2>&1) is older than 3.8; pyATS may not install."
  fi

  # Create the venv if needed (avoids PEP 668 'externally-managed-environment' errors).
  if [[ ! -x "$PYATS_VENV/bin/python" ]]; then
    python3 -m venv "$PYATS_VENV" || die "Failed to create venv at $PYATS_VENV"
    ok "Created virtualenv at $PYATS_VENV"
  else
    ok "Reusing existing virtualenv at $PYATS_VENV"
  fi

  # Upgrade pip tooling, then install pyATS.
  "$PYATS_VENV/bin/python" -m pip install --upgrade pip setuptools wheel >/dev/null
  if [[ -n "$PYATS_EXTRA" ]]; then
    PYATS_PKG="pyats[$PYATS_EXTRA]"
  else
    PYATS_PKG="pyats"
  fi
  log "Installing $PYATS_PKG (this can take several minutes)..."
  "$PYATS_VENV/bin/python" -m pip install --upgrade "$PYATS_PKG"

  PYATS_VER="$("$PYATS_VENV/bin/pyats" version check 2>/dev/null | head -n 1 || echo '(version check unavailable)')"
  ok "pyATS installed: $PYATS_VER"
  log "Activate with:  source \"$PYATS_VENV/bin/activate\""
else
  warn "Skipping pyATS install (INSTALL_PYATS=$INSTALL_PYATS)"
fi

# ---------------------------------------------------------------------------
# 4. Build the MCP server config and merge into .claude.json
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
# 5. Summary
# ---------------------------------------------------------------------------
echo
ok "Done. Verify the MCP config with:"
echo "    jq '.projects[\"$PROJECT_DIR\"].mcpServers[\"$MCP_NAME\"]' \"$CLAUDE_JSON\""
if [[ "$INSTALL_PYATS" == "1" ]]; then
  echo "Use pyATS with:"
  echo "    source \"$PYATS_VENV/bin/activate\"   # then: pyats version check"
fi
echo
log "Restart Claude Code (or run '/mcp' inside it) to connect to CML at $CML_URL"
warn "Note: NODE_TLS_REJECT_UNAUTHORIZED=0 disables TLS cert checks (CML uses a self-signed cert)."
