#!/usr/bin/env bash
#
# vpn_dcloud-up.sh — connect to the Cisco dCloud Sydney AnyConnect VPN
#                    via OpenConnect (split tunnel)
#
#   Usage: sudo ./vpn_dcloud-up.sh [extra-subnet-or-host ...]
#
#   Gateway is fixed: dcloud-syd-anyconnect.cisco.com
#   198.18.128.0/18 is ALWAYS routed through the VPN.
#   Any extra subnets/hosts you pass as arguments are added on top.
#   All other traffic stays on the normal internet path (split tunnel).
#
set -euo pipefail

# --- config ---------------------------------------------------------------
GATEWAY="dcloud-syd-anyconnect.cisco.com"     # fixed dCloud Sydney gateway
ALWAYS_ROUTES=("198.18.128.0/18")             # always tunneled
PID_FILE="/run/openconnect.pid"
VPN_SLICE="/home/reptar/.local/bin/vpn-slice"
# --------------------------------------------------------------------------

usage() {
  cat >&2 <<EOF
Usage: sudo $0 [extra-subnet-or-host ...]

  -h   show this help

  Gateway is fixed: $GATEWAY
  198.18.128.0/18 is always routed through the VPN.
  Add more subnets/hosts as positional args, e.g.:
      sudo $0 10.0.0.0/8 host.dcloud.cisco.com
EOF
  exit 1
}

while getopts ":h" opt; do
  case "$opt" in
    h)  usage ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage ;;
  esac
done
shift $((OPTIND - 1))

[ "$(id -u)" -eq 0 ] || { echo "Error: must be run as root (use sudo)." >&2; exit 1; }
[ -x "$VPN_SLICE" ] || { echo "Error: vpn-slice not found at $VPN_SLICE" >&2; exit 1; }

# already connected?
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "VPN already appears to be running (pid $(cat "$PID_FILE"))." >&2
  echo "Run vpn_dcloud-down.sh first if you want to reconnect." >&2
  exit 1
fi

# combine the always-on route with any extra args the user supplied
ROUTES=("${ALWAYS_ROUTES[@]}" "$@")

echo "Gateway:           $GATEWAY"
echo "Tunneled routes:   ${ROUTES[*]}"
echo "Connecting... (you'll be prompted for username and password)"
echo

# --background daemonizes AFTER you authenticate, so the prompts still work,
# and the pid is written to PID_FILE for vpn_dcloud-down.sh to use.
exec openconnect \
  --protocol=anyconnect \
  --background \
  --pid-file "$PID_FILE" \
  --script "$VPN_SLICE ${ROUTES[*]}" \
  "$GATEWAY"
