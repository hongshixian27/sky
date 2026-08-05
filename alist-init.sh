#!/bin/sh
set -eu

if [ -z "${ALIST_ADMIN_PASSWORD:-}" ]; then
  exit 1
fi

attempt=0
until curl --fail --silent --output /dev/null http://127.0.0.1:5244/api/public/settings; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    echo "[ALIST] service did not become ready"
    exit 1
  fi
  sleep 1
done

cd /opt/alist
/opt/alist/alist admin set "$ALIST_ADMIN_PASSWORD" >/dev/null

if [ -n "${ALIST_BACKUP_KEY:-}" ]; then
  /usr/local/bin/alist-bootstrap
  # The exported backup intentionally contains no passwords. Force the
  # administrator password from Koyeb Secret after every restore and restart.
  /opt/alist/alist admin set "$ALIST_ADMIN_PASSWORD" >/dev/null
fi
