#!/bin/sh
set -eu

ACTIVE_EGRESS=""
SINGBOX_PID=""
KEEPALIVE_PID=""

start_singbox() {
  mode="$1"
  if [ "$mode" = "$ACTIVE_EGRESS" ] && [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
    return
  fi

  sed "s/__EGRESS__/$mode/g" /app/config.json > /app/config.runtime.json
  if [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
    kill "$SINGBOX_PID"
    wait "$SINGBOX_PID" 2>/dev/null || true
  fi

  echo "[EGRESS] switching to $mode"
  /usr/local/bin/sing-box run -c /app/config.runtime.json &
  SINGBOX_PID="$!"
  ACTIVE_EGRESS="$mode"
}

configure_warp() {
  warp-cli --accept-tos status >/dev/null 2>&1 || return 1
  if ! warp-cli --accept-tos registration show >/dev/null 2>&1; then
    echo "[WARP] registering client..."
    warp-cli --accept-tos registration new || return 1
  fi
  warp-cli --accept-tos mode proxy >/dev/null || return 1
  warp-cli --accept-tos proxy port 40000 >/dev/null || return 1
  warp-cli --accept-tos connect >/dev/null || return 1
}

warp_verified() {
  warp-cli --accept-tos status 2>/dev/null | grep -qi "Connected" || return 1
  curl --fail --silent --show-error --max-time 15     --socks5-hostname 127.0.0.1:40000     https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q '^warp=on$'
}

keepalive() {
  if [ -z "${SUBDOMAIN:-}" ]; then
    echo "[KEEPALIVE] SUBDOMAIN is empty; heartbeat disabled"
    return
  fi
  echo "[KEEPALIVE] heartbeat enabled (240s)"
  while :; do
    sleep 240
    curl --silent --show-error --output /dev/null --max-time 15       --user-agent "koyeb-self-keepalive/1.0"       "https://${SUBDOMAIN}/" || true
  done
}

cleanup() {
  if [ -n "$KEEPALIVE_PID" ] && kill -0 "$KEEPALIVE_PID" 2>/dev/null; then
    kill "$KEEPALIVE_PID"
    wait "$KEEPALIVE_PID" 2>/dev/null || true
  fi
  if [ -n "$SINGBOX_PID" ] && kill -0 "$SINGBOX_PID" 2>/dev/null; then
    kill "$SINGBOX_PID"
    wait "$SINGBOX_PID" 2>/dev/null || true
  fi
}
trap cleanup INT TERM EXIT

keepalive &
KEEPALIVE_PID="$!"

echo "[WARP] initializing preferred egress..."
ready=0
if configure_warp; then
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    if warp_verified; then
      ready=1
      break
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
fi

if [ "$ready" -eq 1 ]; then
  echo "[WARP] connected and verified (warp=on)"
  start_singbox warp
else
  echo "[WARP] unavailable; using direct fallback"
  start_singbox direct
fi

while :; do
  sleep 30
  if warp_verified; then
    start_singbox warp
  else
    start_singbox direct
    configure_warp || true
  fi
done
