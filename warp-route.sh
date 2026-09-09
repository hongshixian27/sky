#!/bin/sh
set -eu

IPTABLES="$(command -v iptables-legacy || command -v iptables)"
IP6TABLES="$(command -v ip6tables-legacy || command -v ip6tables || true)"
TAILSCALE_CHAIN="KOYEB_TS_EGRESS"

wait_for() {
  label="$1"
  shift
  attempt=0
  until "$@"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
      echo "[$label] unavailable" >&2
      return 1
    fi
    sleep 1
  done
}

select_warp() {
  curl --fail --silent --show-error --max-time 3 \
    -H 'Content-Type: application/json' \
    -X PUT -d '{"name":"warp"}' \
    http://127.0.0.1:9090/proxies/warp-or-direct >/dev/null
}

select_direct() {
  curl --fail --silent --show-error --max-time 3 \
    -H 'Content-Type: application/json' \
    -X PUT -d '{"name":"direct"}' \
    http://127.0.0.1:9090/proxies/warp-or-direct >/dev/null 2>&1 || true
}

warp_verified() {
  warp-cli --accept-tos status 2>/dev/null | grep -qi connected || return 1

  # Cloudflare's trace endpoint can report warp=off when the Linux client is
  # running in local proxy mode even though traffic exits through WARP.  Verify
  # the usable SOCKS path and require its public IP to differ from Koyeb's
  # direct public IP instead of relying on that flag.
  direct_ip="$(curl -4 --fail --silent --show-error --max-time 10 \
    https://api.ipify.org 2>/dev/null || true)"
  warp_ip="$(curl -4 --fail --silent --show-error --max-time 15 \
    --socks5-hostname 127.0.0.1:40000 \
    https://api.ipify.org 2>/dev/null || true)"
  warp_ipv6="$(curl --fail --silent --show-error --max-time 15 \
    --socks5-hostname 127.0.0.1:40000 \
    https://api6.ipify.org 2>/dev/null || true)"
  [ -n "$direct_ip" ] || return 1
  [ -n "$warp_ip" ] || return 1
  [ "$warp_ip" != "$direct_ip" ] || return 1
  case "$warp_ipv6" in
    *:*) ;;
    *) return 1 ;;
  esac
}

wait_warp_connected() {
  attempt=0
  while [ "$attempt" -lt 40 ]; do
    warp_verified && return 0
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

configure_warp() {
  if ! warp-cli --accept-tos registration show >/dev/null 2>&1; then
    timeout 90 warp-cli --accept-tos registration new || return 1
  fi
  warp-cli --accept-tos tunnel protocol set MASQUE >/dev/null 2>&1 || true
  warp-cli --accept-tos mode proxy >/dev/null || return 1
  warp-cli --accept-tos proxy port 40000 >/dev/null || return 1
  timeout 90 warp-cli --accept-tos connect >/dev/null || return 1
}

connect_warp() {
  select_direct
  warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
  if configure_warp && wait_warp_connected; then
    if select_warp; then
      echo "[WARP] direct startup complete; distinct IPv4 and IPv6 exits verified"
      return 0
    fi
  fi

  echo "[WARP] direct startup or IPv6 verification failed; disabling WARP and using direct fallback" >&2
  warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
  select_direct
  echo "[WARP] disabled; TCP falls back to Koyeb direct" >&2
  return 1
}

tailscale_redirect_disable() {
  "$IPTABLES" -t nat -D PREROUTING -i tailscale0 -p tcp -j "$TAILSCALE_CHAIN" 2>/dev/null || true
  "$IPTABLES" -t nat -F "$TAILSCALE_CHAIN" 2>/dev/null || true
  "$IPTABLES" -t nat -X "$TAILSCALE_CHAIN" 2>/dev/null || true
  if [ -n "$IP6TABLES" ]; then
    "$IP6TABLES" -t nat -D PREROUTING -i tailscale0 -p tcp -j "$TAILSCALE_CHAIN" 2>/dev/null || true
    "$IP6TABLES" -t nat -F "$TAILSCALE_CHAIN" 2>/dev/null || true
    "$IP6TABLES" -t nat -X "$TAILSCALE_CHAIN" 2>/dev/null || true
  fi
}

configure_tailscale_tcp() {
  tailscale_redirect_disable
  if ! "$IPTABLES" -t nat -N "$TAILSCALE_CHAIN" \
    || ! "$IPTABLES" -t nat -A "$TAILSCALE_CHAIN" -d 100.64.0.0/10 -j RETURN \
    || ! "$IPTABLES" -t nat -A "$TAILSCALE_CHAIN" -d 10.0.0.0/8 -j RETURN \
    || ! "$IPTABLES" -t nat -A "$TAILSCALE_CHAIN" -d 172.16.0.0/12 -j RETURN \
    || ! "$IPTABLES" -t nat -A "$TAILSCALE_CHAIN" -d 192.168.0.0/16 -j RETURN \
    || ! "$IPTABLES" -t nat -A "$TAILSCALE_CHAIN" -d 127.0.0.0/8 -j RETURN \
    || ! "$IPTABLES" -t nat -A "$TAILSCALE_CHAIN" -d 169.254.0.0/16 -j RETURN \
    || ! "$IPTABLES" -t nat -A "$TAILSCALE_CHAIN" -j REDIRECT --to-ports 12345 \
    || ! "$IPTABLES" -t nat -I PREROUTING 1 -i tailscale0 -p tcp -j "$TAILSCALE_CHAIN"; then
    tailscale_redirect_disable
    echo "[ROUTE] IPv4 REDIRECT unavailable; Tailscale TCP falls back to kernel forwarding" >&2
    return 1
  fi
  if [ -n "$IP6TABLES" ] \
    && "$IP6TABLES" -t nat -N "$TAILSCALE_CHAIN" \
    && "$IP6TABLES" -t nat -A "$TAILSCALE_CHAIN" -d fd7a:115c:a1e0::/48 -j RETURN \
    && "$IP6TABLES" -t nat -A "$TAILSCALE_CHAIN" -d fc00::/7 -j RETURN \
    && "$IP6TABLES" -t nat -A "$TAILSCALE_CHAIN" -d fe80::/10 -j RETURN \
    && "$IP6TABLES" -t nat -A "$TAILSCALE_CHAIN" -d ::1/128 -j RETURN \
    && "$IP6TABLES" -t nat -A "$TAILSCALE_CHAIN" -j REDIRECT --to-ports 12345 \
    && "$IP6TABLES" -t nat -I PREROUTING 1 -i tailscale0 -p tcp -j "$TAILSCALE_CHAIN"; then
    echo "[ROUTE] Tailscale IPv4/IPv6 TCP REDIRECT enabled; IPv6 uses WARP; UDP is direct"
  else
    echo "[ROUTE] IPv6 REDIRECT unavailable; IPv4 TCP interception remains enabled" >&2
  fi
}

cleanup() {
  tailscale_redirect_disable
  select_direct
}
trap cleanup INT TERM EXIT

wait_for SING-BOX sh -c "ss -ltn | grep -q ':12345 '"
wait_for TAILSCALE test -e /sys/class/net/tailscale0
wait_for WARP warp-cli --accept-tos status
configure_tailscale_tcp || true

connect_warp || true
while :; do
  sleep 20
  if warp_verified; then
    select_warp || true
  else
    connect_warp || true
  fi
done
