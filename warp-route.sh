#!/bin/sh
set -eu

BOOTSTRAP_CHAIN="WARP_BOOTSTRAP"
WARP_API_HOSTS="api.cloudflareclient.com api.devices.cloudflare.com zero-trust-client.cloudflareclient.com notifications.cloudflareclient.com"
WARP_API_IPV4="162.159.137.105 162.159.138.105"

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
  iptables -t nat -D OUTPUT -p tcp --dport 443 -j "$BOOTSTRAP_CHAIN" 2>/dev/null || true
  iptables -t nat -F "$BOOTSTRAP_CHAIN" 2>/dev/null || true
  iptables -t nat -X "$BOOTSTRAP_CHAIN" 2>/dev/null || true
}

bootstrap_enable() {
  bootstrap_disable
  iptables -t nat -N "$BOOTSTRAP_CHAIN" || return 1
  addresses="$WARP_API_IPV4"
  for host in $WARP_API_HOSTS; do
    resolved="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
    addresses="$addresses $resolved"
  done
  for address in $addresses; do
    case "$address" in
      *.*.*.*)
        iptables -t nat -A "$BOOTSTRAP_CHAIN" -d "$address/32" -j REDIRECT --to-ports 12347
        ;;
    esac
  done
  iptables -t nat -A "$BOOTSTRAP_CHAIN" -j RETURN
  iptables -t nat -A OUTPUT -p tcp --dport 443 -j "$BOOTSTRAP_CHAIN"
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
  # Use the requested VMess node for WARP registration and control-plane setup.
  # The actual tunnel endpoints and subsequent user traffic do not stay on the
  # bootstrap node after WARP has been verified.
  if bootstrap_enable && configure_warp && wait_warp_connected; then
    bootstrap_disable
    select_warp
    echo "[WARP] registered through VMess bootstrap; user TCP uses WARP"
    return 0
  fi

  echo "[WARP] VMess registration failed; disabling WARP and using direct fallback" >&2
  bootstrap_disable
  warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
  select_direct
  echo "[WARP] disabled; TCP falls back to Koyeb direct" >&2
  return 1
}

configure_tailscale_tcp() {
  ip rule del fwmark 1 table 100 2>/dev/null || true
  ip route flush table 100 2>/dev/null || true
  ip rule add fwmark 1 table 100
  ip route add local 0.0.0.0/0 dev lo table 100

  iptables -t mangle -D PREROUTING -i tailscale0 -p tcp -j KOYEB_TS_EGRESS 2>/dev/null || true
  iptables -t mangle -F KOYEB_TS_EGRESS 2>/dev/null || true
  iptables -t mangle -X KOYEB_TS_EGRESS 2>/dev/null || true
  iptables -t mangle -N KOYEB_TS_EGRESS
  iptables -t mangle -A KOYEB_TS_EGRESS -d 100.64.0.0/10 -j RETURN
  iptables -t mangle -A KOYEB_TS_EGRESS -d 127.0.0.0/8 -j RETURN
  iptables -t mangle -A KOYEB_TS_EGRESS -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1/1
  iptables -t mangle -A PREROUTING -i tailscale0 -p tcp -j KOYEB_TS_EGRESS
  echo "[ROUTE] Tailscale TCP policy enabled; all UDP bypasses proxy"
}

cleanup() {
  bootstrap_disable
  select_direct
}
trap cleanup INT TERM EXIT

wait_for SING-BOX sh -c "ss -ltn | grep -q ':12347 '"
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
