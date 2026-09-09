#!/bin/sh
set -eu

[ -n "${UUID:-}" ] || exit 1

[ -n "${UPSTREAM_ADDR:-}" ] || {
  echo "UPSTREAM_ADDR is required" >&2
  exit 1
}
[ -n "${LIVE_UPSTREAM_ADDR:-}" ] || {
  echo "LIVE_UPSTREAM_ADDR is required" >&2
  exit 1
}
case "$UPSTREAM_ADDR" in
  ''|*[!A-Za-z0-9.-]*)
    echo "UPSTREAM_ADDR must be a hostname or IPv4 address" >&2
    exit 1
    ;;
esac
case "$LIVE_UPSTREAM_ADDR" in
  ''|*[!A-Za-z0-9.-]*)
    echo "LIVE_UPSTREAM_ADDR must be a hostname or IPv4 address" >&2
    exit 1
    ;;
esac
export UPSTREAM_ADDR LIVE_UPSTREAM_ADDR

sed -i "s/00000000-0000-0000-0000-000000000000/$UUID/g" /app/config.json
sed -e "s#__UPSTREAM_ADDR__#$UPSTREAM_ADDR#g" \
    -e "s#__LIVE_UPSTREAM_ADDR__#$LIVE_UPSTREAM_ADDR#g" \
  /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
nginx -t
mkdir -p /data /var/lib/tailscale /var/run/tailscale
# Establish the external base path before AList or its restore client starts.
export ALIST_SITE_URL=https://koyeb.idkwhn.ccwu.cc/alist
python3 /app/alist-prepare.py /data/config.json
if [ -n "${TS_STATE_B64:-}" ]; then
  printf '%s' "$TS_STATE_B64" | base64 -d > /var/lib/tailscale/tailscaled.state
  chmod 0600 /var/lib/tailscale/tailscaled.state
fi
[ -e /data/sky.json ] || printf '[]\n' > /data/sky.json
chmod 0600 /data/sky.json

# Exit-node forwarding is required in kernel mode.  Koyeb exposes these
# switches directly even though the slim image does not include sysctl.
[ ! -w /proc/sys/net/ipv4/ip_forward ] || printf '1\n' > /proc/sys/net/ipv4/ip_forward
[ ! -w /proc/sys/net/ipv6/conf/all/forwarding ] || printf '1\n' > /proc/sys/net/ipv6/conf/all/forwarding

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
