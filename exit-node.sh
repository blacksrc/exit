#!/usr/bin/env bash
# Route your internet traffic through another computer, using Tailscale.
#
# You (the one routing traffic) create an auth key in your Tailscale account and
# send it to the exit node (the computer that shares its internet connection).
# The exit node joins your account with it, so nobody signs in there.
#
#   ./exit-node.sh               # guided setup
#   ./exit-node.sh share [key]   # make this computer an exit node, joining with the key
#   ./exit-node.sh unshare       # stop being an exit node
#   ./exit-node.sh on [node]     # send ALL traffic through an exit node
#   ./exit-node.sh off           # back to normal, direct internet
#   ./exit-node.sh status        # what this computer is doing + its public IP
#
# Works on macOS and Linux. The last exit node you used is remembered in ~/.config/exit.
set -euo pipefail

OS="$(uname -s)"
CONF="$HOME/.config/exit"
# shellcheck source=/dev/null
[[ -f "$CONF" ]] && source "$CONF"
NODE="${2:-${EXIT_NODE:-}}"
ADMIN_URL="https://login.tailscale.com/admin/machines"

usage() { awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; }

case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac
[[ "$OS" == Darwin || "$OS" == Linux ]] || { echo "Only macOS and Linux are supported."; exit 1; }

# The macOS GUI app (App Store / standalone) ships its CLI inside the bundle.
TS="$(command -v tailscale || true)"
[[ -z "$TS" && -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]] \
  && TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[[ -z "$TS" ]] && { echo "Tailscale not found. Install it from https://tailscale.com/download"; exit 1; }

# ask "Question?" [y|n]: succeeds on yes. Enter picks the default, if there is one.
ask() {
  local a hint="[y/n]"
  [[ "${2:-}" == y ]] && hint="[Y/n]"
  [[ "${2:-}" == n ]] && hint="[y/N]"
  while :; do
    read -rp "$1 $hint " a || exit 1
    case "${a:-${2:-}}" in [Yy]*) return 0 ;; [Nn]*) return 1 ;; esac
  done
}

prefs()       { "$TS" debug prefs 2>/dev/null || true; }
advertising() { [[ "$(prefs)" == *'"0.0.0.0/0"'* ]]; }
is_operator() { [[ "$(prefs)" == *"\"OperatorUser\": \"$USER\""* ]]; }

# Exit nodes on the tailnet, one hostname per line.
list_nodes() { "$TS" exit-node list 2>/dev/null | awk '$1 ~ /[.:]/ {print $2}' || true; }

# The exit node this computer is using right now, if any (its STATUS reads "selected").
current_exit() {
  "$TS" exit-node list 2>/dev/null \
    | awk '$1 ~ /[.:]/ { for (i = 3; i <= NF; i++) if ($i == "selected") print $2 }' || true
}

# Tailscale IP of exit node $1 (its listed hostname or short name). Older Tailscale
# rejects the listed hostname for --exit-node, but every version accepts the IP.
node_ip() {
  "$TS" exit-node list 2>/dev/null | awk -v n="$1" '
    $1 ~ /[.:]/ { name = tolower($2); short = name; sub(/\..*/, "", short)
                  if (tolower(n) == name || tolower(n) == short) { print $1; exit } }' || true
}

# This computer's name on the tailnet.
self_name() { "$TS" status --peers=false 2>/dev/null | awk 'NR == 1 {print $2}' || true; }

public_ip() {
  local info
  # ipinfo.io answers with one "key": "value" per line; keep ip, country and org.
  info="$(curl -s --max-time 10 https://ipinfo.io/json \
    | awk -F'"' '$2 == "ip" || $2 == "country" || $2 == "org" {printf "%s%s", sep, $4; sep = " "}')" || true
  echo "${info:-unknown (no connectivity?)}"
}

# The CLI only talks to Tailscale itself (the app on macOS, tailscaled on Linux), so
# start that if needed. `status --json` works even when logged out.
start_tailscale() {
  "$TS" status --json >/dev/null 2>&1 && return
  echo "Starting Tailscale..."
  if [[ "$OS" == Darwin ]]; then
    echo "If macOS asks to allow a VPN configuration, click Allow."
    open -a Tailscale
  else
    sudo systemctl enable --now tailscaled
  fi
  for _ in {1..30}; do
    "$TS" status --json >/dev/null 2>&1 && return
    sleep 1
  done
  echo "Tailscale still isn't running. Open the Tailscale app (macOS) or run: sudo systemctl start tailscaled"
  exit 1
}

# Log in if needed: with the auth key if one is given (no sign-in here), else in the
# browser. On Linux, --operator lets this script change settings without sudo.
ensure_up() {
  "$TS" status >/dev/null 2>&1 && return
  local args=(up)
  [[ -n "${1:-}" ]] && args+=(--auth-key="$1")
  if [[ "$OS" == Linux ]]; then sudo "$TS" "${args[@]}" --operator="$USER"; else "$TS" "${args[@]}"; fi
}

# `tailscale set`. On Linux that needs root unless you're the operator, so a
# computer logged in with plain `sudo tailscale up` gets one sudo prompt, once.
ts_set() {
  if [[ "$OS" == Linux ]] && ! is_operator; then sudo "$TS" set --operator="$USER"; fi
  "$TS" set "$@"
}

share() {
  ensure_up "${1:-}"
  if [[ "$OS" == Linux ]] \
    && ! { grep -qsx 1 /proc/sys/net/ipv4/ip_forward && grep -qsx 1 /proc/sys/net/ipv6/conf/all/forwarding; }; then
    # Linux only passes on other computers' traffic when told to (saved across reboots).
    echo "Turning on IP forwarding so this computer can route traffic for others."
    printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' \
      | sudo tee -a /etc/sysctl.d/99-tailscale.conf >/dev/null
    sudo sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null
  fi
  ts_set --advertise-exit-node
  if [[ "$OS" == Darwin ]]; then
    echo "Turning off system sleep on AC power, since sleep kills the tunnel."
    sudo pmset -c sleep 0 disksleep 0
    echo "(Undo later with: sudo pmset -c sleep 10)"
  else
    echo "Tip: keep this computer from going to sleep, since sleep kills the tunnel."
  fi
  echo
  echo "This computer is now offered as an exit node: $(self_name) ($("$TS" ip -4))"
  echo "Last step, done once by the Tailscale account owner at $ADMIN_URL"
  echo "  this computer's ... menu -> Edit route settings -> Use as exit node"
  echo "  this computer's ... menu -> Disable key expiry (keeps it working after 180 days)"
}

unshare() {
  ts_set --advertise-exit-node=false
  echo "This computer is no longer an exit node."
}

pick_node() {
  local nodes def answer
  nodes="$(list_nodes)"
  if [[ -z "$nodes" ]]; then
    echo "No exit nodes yet. To add the other computer:"
    echo "  1. Create an auth key at https://login.tailscale.com/admin/settings/keys and send it over."
    echo "  2. On the other computer, run: ./exit-node.sh share <key>"
    echo "  3. Approve it at $ADMIN_URL"
    echo "     (its ... menu -> Edit route settings -> Use as exit node)"
    exit 1
  fi
  "$TS" exit-node list | sed '/^#/d; /^ *$/d'
  read -r def <<<"$nodes"
  def="${NODE:-$def}"
  read -rp "Exit node to use [$def]: " answer || exit 1
  NODE="${answer:-$def}"
}

on() {
  ensure_up
  [[ -n "$NODE" ]] || pick_node
  local ip; ip="$(node_ip "$NODE")"
  # allow-lan-access keeps your local network (printer, router, NAS) reachable.
  ts_set --exit-node="${ip:-$NODE}" --exit-node-allow-lan-access=true
  mkdir -p "${CONF%/*}"
  printf 'EXIT_NODE=%q\n' "$NODE" > "$CONF"
  sleep 2; echo -n "Now exiting from: "; public_ip
}

off() {
  ts_set --exit-node=
  echo -n "Direct again: "; public_ip
}

status() {
  local cur; cur="$(current_exit)"
  echo "This computer: $(self_name) $("$TS" ip -4 2>/dev/null || true)"
  if advertising; then echo "Exit node:     yes, sharing its connection"
  else echo "Exit node:     no"; fi
  echo "Traffic exits: ${cur:-directly (no exit node)}"
  echo -n "Public IP:     "; public_ip
}

guide() {
  local cur key=""; cur="$(current_exit)"
  echo "Route your internet traffic through another computer, using Tailscale."
  echo "The exit node is the computer that shares its internet connection; the other"
  echo "computer sends all its traffic through it. Run this script on both."
  echo
  if advertising; then
    echo "This computer is an exit node right now."
    if ask "Stop sharing its connection?" n; then unshare; fi
  elif [[ -n "$cur" ]]; then
    echo "This computer's traffic goes through $cur right now."
    if ask "Switch back to direct internet?" n; then off; fi
  elif ask "Should THIS computer be the exit node?"; then
    if ! "$TS" status >/dev/null 2>&1; then
      read -rp "Paste the auth key you were sent (or press Enter to sign in instead): " key || exit 1
    fi
    share "$key"
  else
    ensure_up
    pick_node
    on
  fi
}

case "${1:-}" in
  "") start_tailscale; guide ;;
  share) start_tailscale; share "${2:-}" ;;
  unshare|on|off|status) start_tailscale; "$1" ;;
  *) usage; exit 1 ;;
esac
