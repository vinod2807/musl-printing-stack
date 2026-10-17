#!/bin/sh
#
# Undo install.sh.  Run as root.
#
set -e

PREFIX=${PREFIX:-/usr/local}
BACKEND=${BACKEND:-/usr/lib/cups/backend/ipp}
SO="$PREFIX/lib/cups-thread-stackfix.so"

MARKER=cups-thread-stackfix-wrapper

[ "$(id -u)" = 0 ] || { echo "error: run as root" >&2; exit 1; }

echo "== restoring $BACKEND =="
if grep -aq "$MARKER" "$BACKEND" 2>/dev/null && [ -e "$BACKEND.real" ]; then
  rm -f "$BACKEND"
  mv "$BACKEND.real" "$BACKEND"
else
  echo "   $BACKEND is not our wrapper; leaving it alone"
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
