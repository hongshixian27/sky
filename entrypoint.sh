#!/bin/sh
set -eu

if [ -z "${UUID:-}" ]; then
  echo "[ERROR] UUID is required"
  exit 1
fi

sed -i "s/00000000-0000-0000-0000-000000000000/$UUID/g" /app/config.json
mkdir -p /data /var/lib/tailscale /var/run/tailscale /run/cloudflare-warp

echo "========================================"
echo " Koyeb: AList + VLESS + WARP + Tailscale"
echo "========================================"
if [ -n "${SUBDOMAIN:-}" ]; then
  echo "[ALIST] https://${SUBDOMAIN}/"
  echo "[VLESS] vless://${UUID}@${SUBDOMAIN}:443?encryption=none&security=tls&type=ws&host=${SUBDOMAIN}&path=%2Fblog#Koyeb-WARP"
fi
echo "[INFO] WARP is preferred; direct egress is automatic fallback"

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
