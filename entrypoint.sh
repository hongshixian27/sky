#!/bin/sh
set -eu

[ -n "${UUID:-}" ] || exit 1

UPSTREAM_ADDR="${UPSTREAM_ADDR:-beta.ws.radiance.thatgamecompany.com}"
case "$UPSTREAM_ADDR" in
  ''|*[!A-Za-z0-9.-]*)
    echo "UPSTREAM_ADDR must be a hostname or IPv4 address" >&2
    exit 1
    ;;
esac
export UPSTREAM_ADDR

sed -i "s/00000000-0000-0000-0000-000000000000/$UUID/g" /app/config.json
sed "s#beta\.ws\.radiance\.thatgamecompany\.com#$UPSTREAM_ADDR#g" \
  /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
nginx -t
mkdir -p /data /var/lib/tailscale /var/run/tailscale /run/cloudflare-warp

if [ -c /dev/net/tun ]; then
  # The Koyeb image does not include the sysctl command, but privileged
  # instances expose these writable kernel switches directly.
  [ ! -w /proc/sys/net/ipv4/ip_forward ] || printf '1\n' > /proc/sys/net/ipv4/ip_forward
  [ ! -w /proc/sys/net/ipv6/conf/all/forwarding ] || printf '1\n' > /proc/sys/net/ipv6/conf/all/forwarding
fi

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
