#!/bin/sh
set -eu

BOOTSTRAP_CHAIN="WARP_BOOTSTRAP"
WARP_API_HOSTS="api.cloudflareclient.com api.devices.cloudflare.com zero-trust-client.cloudflareclient.com notifications.cloudflareclient.com"
WARP_API_IPV4="162.159.137.105 162.159.138.105"
IPTABLES="$(command -v iptables-legacy || command -v iptables)"

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

bootstrap_disable() {
  "$IPTABLES" -t nat -D OUTPUT -p tcp --dport 443 -j "$BOOTSTRAP_CHAIN" 2>/dev/null || true
  "$IPTABLES" -t nat -F "$BOOTSTRAP_CHAIN" 2>/dev/null || true
  "$IPTABLES" -t nat -X "$BOOTSTRAP_CHAIN" 2>/dev/null || true
}

bootstrap_enable() {
  bootstrap_disable
  "$IPTABLES" -t nat -N "$BOOTSTRAP_CHAIN" || return 1
  addresses="$WARP_API_IPV4"
  for host in $WARP_API_HOSTS; do
    resolved="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
    addresses="$addresses $resolved"
  done
  for address in $addresses; do
    case "$address" in
      *.*.*.*)
        "$IPTABLES" -t nat -A "$BOOTSTRAP_CHAIN" -d "$address/32" -j REDIRECT --to-ports 12347
        ;;
    esac
  done
  "$IPTABLES" -t nat -A "$BOOTSTRAP_CHAIN" -j RETURN
  "$IPTABLES" -t nat -A OUTPUT -p tcp --dport 443 -j "$BOOTSTRAP_CHAIN"
  echo "[WARP] control-plane bootstrap uses VMess; tunnel endpoints remain direct"
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

bootstrap_node_verified() {
  node_ip="$(curl -4 --fail --silent --show-error --max-time 15 \
    --socks5-hostname 127.0.0.1:12348 \
    https://api.ipify.org 2>/dev/null || true)"
  [ -n "$node_ip" ] || return 1
  echo "[WARP] VMess bootstrap verified; exit ${node_ip}"
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
  [ -n "$warp_ip" ] || return 1
  [ -z "$direct_ip" ] || [ "$warp_ip" != "$direct_ip" ]
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
  # Use the requested VMess node for WARP registration and control-plane setup.
  # The actual tunnel endpoints and subsequent user traffic do not stay on the
  # bootstrap node after WARP has been verified.
  if bootstrap_enable && bootstrap_node_verified && configure_warp && wait_warp_connected; then
    if select_warp; then
      echo "[WARP] distinct exit verified; WARP routing enabled"
      bootstrap_disable
      echo "[WARP] VMess bootstrap disconnected after WARP activation"
      return 0
    fi
  fi

  echo "[WARP] VMess registration or exit verification failed; disabling WARP and using direct fallback" >&2
  bootstrap_disable
  warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
  select_direct
  echo "[WARP] disabled; TCP falls back to Koyeb direct" >&2
  return 1
}

configure_tailscale_tcp() {
  ip -4 rule del fwmark 1 table 100 2>/dev/null || true
  ip -4 route flush table 100 2>/dev/null || true
  if ! ip -4 rule add fwmark 1 table 100 2>/dev/null; then
    echo "[ROUTE] policy routing unavailable; skipping Tailscale TCP interception" >&2
    return 0
  fi
  if ! ip -4 route add local 0.0.0.0/0 dev lo table 100 2>/dev/null; then
    ip -4 rule del fwmark 1 table 100 2>/dev/null || true
    echo "[ROUTE] local route unavailable; skipping Tailscale TCP interception" >&2
    return 0
  fi

  "$IPTABLES" -t mangle -D PREROUTING -i tailscale0 -p tcp -j KOYEB_TS_EGRESS 2>/dev/null || true
  "$IPTABLES" -t mangle -F KOYEB_TS_EGRESS 2>/dev/null || true
  "$IPTABLES" -t mangle -X KOYEB_TS_EGRESS 2>/dev/null || true
  if ! "$IPTABLES" -t mangle -N KOYEB_TS_EGRESS 2>/dev/null \
    || ! "$IPTABLES" -t mangle -A KOYEB_TS_EGRESS -d 100.64.0.0/10 -j RETURN 2>/dev/null \
    || ! "$IPTABLES" -t mangle -A KOYEB_TS_EGRESS -d 127.0.0.0/8 -j RETURN 2>/dev/null \
    || ! "$IPTABLES" -t mangle -A KOYEB_TS_EGRESS -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1/1 2>/dev/null \
    || ! "$IPTABLES" -t mangle -A PREROUTING -i tailscale0 -p tcp -j KOYEB_TS_EGRESS 2>/dev/null; then
    "$IPTABLES" -t mangle -D PREROUTING -i tailscale0 -p tcp -j KOYEB_TS_EGRESS 2>/dev/null || true
    "$IPTABLES" -t mangle -F KOYEB_TS_EGRESS 2>/dev/null || true
    "$IPTABLES" -t mangle -X KOYEB_TS_EGRESS 2>/dev/null || true
    ip -4 rule del fwmark 1 table 100 2>/dev/null || true
    ip -4 route flush table 100 2>/dev/null || true
    echo "[ROUTE] TPROXY unavailable; skipping Tailscale TCP interception" >&2
    return 0
  fi
  echo "[ROUTE] Tailscale TCP policy enabled; all UDP bypasses proxy"
}

cleanup() {
  bootstrap_disable
  select_direct
}
trap cleanup INT TERM EXIT

wait_for SING-BOX sh -c "ss -ltn | grep -q ':12347 '"
wait_for SING-BOX-CHECK sh -c "ss -ltn | grep -q ':12348 '"
wait_for TAILSCALE test -e /sys/class/net/tailscale0
wait_for WARP warp-cli --accept-tos status
configure_tailscale_tcp

connect_warp || true
while :; do
  sleep 20
  if warp_verified; then
    bootstrap_disable
    select_warp || true
  else
    connect_warp || true
  fi
done
