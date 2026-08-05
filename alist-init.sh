#!/bin/sh
set -eu

if [ -z "${ALIST_ADMIN_PASSWORD:-}" ]; then
  echo "[ALIST] ALIST_ADMIN_PASSWORD is empty; keeping generated password"
  exit 0
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
echo "[ALIST] administrator password initialized"
