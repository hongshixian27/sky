#!/bin/sh
set -eu

if [ -z "${UUID:-}" ]; then
  echo "[ERROR] UUID is required"
  exit 1
fi

sed -i "s/00000000-0000-0000-0000-000000000000/$UUID/g" /app/config.json
mkdir -p /data /var/lib/tailscale /var/run/tailscale /run/cloudflare-warp

if [ -c /dev/net/tun ]; then
  sysctl -w net.ipv4.ip_forward=1
  sysctl -w net.ipv6.conf.all.forwarding=1 || true
  echo "[TAILSCALE] kernel TUN and IP forwarding enabled"
else
  echo "[TAILSCALE] /dev/net/tun is unavailable"
fi

echo "========================================"
echo " Koyeb: AList + VLESS + WARP + Tailscale"
echo "========================================"
if [ -n "${SUBDOMAIN:-}" ]; then
  echo "[ALIST] https://${SUBDOMAIN}/"
  echo "[VLESS] vless://${UUID}@${SUBDOMAIN}:443?encryption=none&security=tls&type=ws&host=${SUBDOMAIN}&path=%2Fblog#Koyeb-WARP"
fi
echo "[INFO] WARP is preferred; direct egress is automatic fallback"

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
