#!/bin/sh
set -eu

if [ -z "${ALIST_ADMIN_PASSWORD:-}" ]; then
  echo "[ALIST] ALIST_ADMIN_PASSWORD is missing" >&2
  exit 1
fi

if [ -z "${ALIST_BACKUP_KEY:-}" ]; then
  echo "[ALIST] ALIST_BACKUP_KEY is missing" >&2
  exit 1
fi

attempt=0
until curl --fail --silent --output /dev/null http://127.0.0.1:5244/alist/api/public/settings || \
  curl --fail --silent --output /dev/null http://127.0.0.1:5244/api/public/settings; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    echo "[ALIST] service did not become ready"
    exit 1
  fi
  sleep 1
done

cd /opt/alist
/opt/alist/alist admin set "$ALIST_ADMIN_PASSWORD" >/dev/null

# The encrypted backup is built into the image.  Always reconcile it on every
# container start; do not trust an ephemeral /data marker on Koyeb.
/usr/local/bin/alist-bootstrap
# The exported backup intentionally contains no passwords. Force the
# administrator password from Koyeb Secret after every restore and restart.
/opt/alist/alist admin set "$ALIST_ADMIN_PASSWORD" >/dev/null

# AList needs its own base URL in order to generate correct asset, API, and
# locally proxied download links when it is served from /alist/.
config_changed=0
if [ -f /data/config.json ] && ! grep -Eq '"site_url"[[:space:]]*:[[:space:]]*"https://koyeb\.idkwhn\.ccwu\.cc/alist"' /data/config.json; then
  sed -i 's#"site_url"[[:space:]]*:[[:space:]]*"[^"]*"#"site_url": "https://koyeb.idkwhn.ccwu.cc/alist"#' /data/config.json
  if grep -Eq '"site_url"[[:space:]]*:[[:space:]]*"https://koyeb\.idkwhn\.ccwu\.cc/alist"' /data/config.json; then
    config_changed=1
  fi
fi

if [ "$config_changed" -eq 1 ]; then
  alist_pid="$(pidof alist || true)"
  if [ -n "$alist_pid" ]; then
    kill -TERM "$alist_pid"
  fi
fi

exit 0
