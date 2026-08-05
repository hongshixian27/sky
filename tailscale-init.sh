#!/bin/sh
set -eu

if [ -z "${TS_AUTHKEY:-}" ]; then
  echo "[TAILSCALE] TS_AUTHKEY is empty; private access disabled"
  exit 0
fi

attempt=0
until [ -S /var/run/tailscale/tailscaled.sock ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    echo "[TAILSCALE] tailscaled socket unavailable"
    exit 1
  fi
  sleep 1
done

tailscale up \
  --auth-key="$TS_AUTHKEY" \
  --hostname="${TS_HOSTNAME:-koyeb-sky}" \
  --accept-dns=false \
  --advertise-exit-node \
  --reset

tailscale serve --bg http://127.0.0.1:5244 || true
echo "[TAILSCALE] connected and advertising exit-node routes"
#!/bin/sh
set -eu

if [ -z "${TS_AUTHKEY:-}" ]; then
  echo "[TAILSCALE] TS_AUTHKEY is empty; private access disabled"
  exit 0
fi

attempt=0
until [ -S /var/run/tailscale/tailscaled.sock ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    echo "[TAILSCALE] tailscaled socket unavailable"
    exit 1
  fi
  sleep 1
done

tailscale up \
  --auth-key="$TS_AUTHKEY" \
  --hostname="${TS_HOSTNAME:-koyeb-sky}" \
  --accept-dns=false \
  --reset

tailscale serve --bg http://127.0.0.1:5244 || true
echo "[TAILSCALE] connected"
