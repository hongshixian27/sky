#!/bin/sh
set -eu

[ -n "${UUID:-}" ] || exit 1

sed -i "s/00000000-0000-0000-0000-000000000000/$UUID/g" /app/config.json
mkdir -p /data /var/lib/tailscale /var/run/tailscale /run/cloudflare-warp

if [ -c /dev/net/tun ]; then
  # The Koyeb image does not include the sysctl command, but privileged
  # instances expose these writable kernel switches directly.
  [ ! -w /proc/sys/net/ipv4/ip_forward ] || printf '1\n' > /proc/sys/net/ipv4/ip_forward
  [ ! -w /proc/sys/net/ipv6/conf/all/forwarding ] || printf '1\n' > /proc/sys/net/ipv6/conf/all/forwarding
fi

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
