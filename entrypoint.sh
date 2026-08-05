#!/bin/sh
set -eu

[ -n "${UUID:-}" ] || exit 1

sed -i "s/00000000-0000-0000-0000-000000000000/$UUID/g" /app/config.json
mkdir -p /data /var/lib/tailscale /var/run/tailscale /run/cloudflare-warp

if [ -c /dev/net/tun ]; then
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
fi

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
