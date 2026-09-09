#!/bin/sh
set -eu
# Supervisor retries failed initialization; avoid a tight restart loop.
trap 'rc=$?; if [ "$rc" -ne 0 ]; then sleep 30; fi' EXIT

if [ -z "${ALIST_ADMIN_PASSWORD:-}" ]; then
  echo "[ALIST] ALIST_ADMIN_PASSWORD is missing" >&2
  exit 1
fi

if [ -z "${ALIST_BACKUP_KEY:-}" ]; then
  echo "[ALIST] ALIST_BACKUP_KEY is missing" >&2
  exit 1
fi

attempt=0
until python3 -c 'import json, urllib.request; r=json.load(urllib.request.urlopen("http://127.0.0.1:5244/alist/api/public/settings", timeout=5)); assert r.get("code") == 200' >/dev/null 2>&1; do
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

echo "[ALIST] encrypted backup restored successfully"
exit 0
