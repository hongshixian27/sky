#!/bin/sh
set -eu

if [ -z "${ALIST_ADMIN_PASSWORD:-}" ]; then
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

restore_rc=0
if [ -n "${ALIST_BACKUP_KEY:-}" ]; then
  /usr/local/bin/alist-bootstrap || restore_rc=$?
  # The exported backup intentionally contains no passwords. Force the
  # administrator password from Koyeb Secret after every restore and restart.
  /opt/alist/alist admin set "$ALIST_ADMIN_PASSWORD" >/dev/null
fi

# AList needs its own base URL in order to generate correct asset, API, and
# locally proxied download links when it is served from /alist/.
config_changed=0
if [ -f /data/config.json ] && ! grep -Eq '"site_url"[[:space:]]*:[[:space:]]*"/alist"' /data/config.json; then
  sed -i 's#"site_url"[[:space:]]*:[[:space:]]*"[^"]*"#"site_url": "/alist"#' /data/config.json
  if grep -Eq '"site_url"[[:space:]]*:[[:space:]]*"/alist"' /data/config.json; then
    config_changed=1
  fi
fi

if [ "$config_changed" -eq 1 ]; then
  alist_pid="$(pidof alist || true)"
  if [ -n "$alist_pid" ]; then
    kill -TERM "$alist_pid"
  fi
fi

exit "$restore_rc"
