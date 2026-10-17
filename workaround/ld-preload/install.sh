#!/bin/sh
#
# Build and install the LD_PRELOAD shim + "ipp" backend wrapper.
# Run as root.  Safe to re-run, including after a "cups" package upgrade.
#
set -e

PREFIX=${PREFIX:-/usr/local}
BACKEND=${BACKEND:-/usr/lib/cups/backend/ipp}
SO="$PREFIX/lib/cups-thread-stackfix.so"
CC=${CC:-cc}

# Embedded in ipp-wrapper; used to recognise our own wrapper.
MARKER=cups-thread-stackfix-wrapper

[ "$(id -u)" = 0 ] || { echo "error: run as root" >&2; exit 1; }

echo "== building =="
if [ "${PREBUILT:-0}" = 1 ]; then
  # Used when no C compiler is available; artifacts come from the cache.
  [ -f thread-stackfix.so ] && [ -f ipp-wrapper ] || {
    echo "error: PREBUILT=1 but thread-stackfix.so/ipp-wrapper are missing" >&2
    exit 1
  }
  echo "   using prebuilt artifacts"
else
  $CC -O2 -Wall -shared -fPIC -o thread-stackfix.so thread-stackfix.c -ldl
  $CC -O2 -Wall -o ipp-wrapper ipp-wrapper.c
fi

if ! grep -aq "$MARKER" ipp-wrapper; then
  echo "error: built wrapper has no marker - refusing to install" >&2
  exit 1
fi

echo "== installing shim -> $SO =="
install -D -m 0755 thread-stackfix.so "$SO"

echo "== wrapping $BACKEND =="
if grep -aq "$MARKER" "$BACKEND" 2>/dev/null; then
  # $BACKEND is already our wrapper, so $BACKEND.real is the real backend.
  # Leave it alone - but say so, because after "apk upgrade cups" the wrapper
  # has been silently REPLACED and we reach this branch only when it was not.
  echo "   already wrapped; keeping existing $BACKEND.real"
else
  # Either a first install, or a package upgrade just put a fresh backend here.
  #
  # Copy to a temporary file and rename() it into place.  Writing directly onto
  # $BACKEND.real fails with ETXTBSY ("Text file busy") whenever a backend
  # process is still executing it - which is exactly the situation right after
  # an upgrade (cupsd may still have the old backend open).  rename(2) replaces
  # the directory entry and does not disturb the running process.
  echo "   preserving real backend -> $BACKEND.real"
  tmp="$BACKEND.real.new.$$"
  trap 'rm -f "$tmp"' EXIT
  cp -p "$BACKEND" "$tmp"
  mv -f "$tmp" "$BACKEND.real"
  trap - EXIT
fi
chmod 0755 "$BACKEND.real"
install -m 0755 ipp-wrapper "$BACKEND"

echo "== restarting cupsd =="
# Non-fatal: the files are already in place, so a failure here (e.g. cupsd not
# running yet, as during a boot hook) must not abort the install.
if command -v rc-service >/dev/null 2>&1; then
  rc-service cupsd restart || echo "   warning: could not restart cupsd (it will pick this up on next start)"
elif command -v systemctl >/dev/null 2>&1; then
  systemctl restart cups || echo "   warning: could not restart cups"
else
  echo "please restart cupsd manually"
fi

echo
echo "Done.  Re-enable any paused queues, e.g.:"
echo "  cupsenable <queue>"
