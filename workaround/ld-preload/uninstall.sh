#!/bin/sh
#
# Undo install.sh.
# Run as root.
#
set -e

PREFIX=${PREFIX:-/usr/local}
BACKEND=${BACKEND:-/usr/lib/cups/backend/ipp}
SO="$PREFIX/lib/cups-thread-stackfix.so"

[ "$(id -u)" = 0 ] || { echo "error: run as root" >&2; exit 1; }

echo "== restoring $BACKEND =="
if [ -e "$BACKEND.real" ]; then
  rm -f "$BACKEND"
  mv "$BACKEND.real" "$BACKEND"
fi

echo "== removing $SO =="
rm -f "$SO"

echo "== restarting cupsd =="
if command -v rc-service >/dev/null 2>&1; then
  rc-service cupsd restart
elif command -v systemctl >/dev/null 2>&1; then
  systemctl restart cups
fi

echo "Reverted."
