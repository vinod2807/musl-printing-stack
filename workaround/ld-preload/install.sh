#!/bin/sh
#
# Build and install the LD_PRELOAD shim + "ipp" backend wrapper.
# Run as root.
#
set -e

PREFIX=${PREFIX:-/usr/local}
BACKEND=${BACKEND:-/usr/lib/cups/backend/ipp}
SO="$PREFIX/lib/cups-thread-stackfix.so"
CC=${CC:-cc}

[ "$(id -u)" = 0 ] || { echo "error: run as root" >&2; exit 1; }

echo "== building =="
$CC -O2 -Wall -shared -fPIC -o thread-stackfix.so thread-stackfix.c -ldl
$CC -O2 -Wall -o ipp-wrapper ipp-wrapper.c

echo "== installing shim -> $SO =="
install -D -m 0755 thread-stackfix.so "$SO"

echo "== wrapping $BACKEND =="
if [ ! -e "$BACKEND.real" ]; then
  mv "$BACKEND" "$BACKEND.real"
fi
chmod 0755 "$BACKEND.real"
install -m 0755 ipp-wrapper "$BACKEND"

echo "== restarting cupsd =="
if command -v rc-service >/dev/null 2>&1; then
  rc-service cupsd restart
elif command -v systemctl >/dev/null 2>&1; then
  systemctl restart cups
else
  echo "please restart cupsd manually"
fi

echo
echo "Done.  Re-enable any paused queues, e.g.:"
echo "  cupsenable <queue>"
