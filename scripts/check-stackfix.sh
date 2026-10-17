#!/bin/sh
#
# Report whether the LD_PRELOAD workaround is still in effect.
#
# The wrapper at $BACKEND is a file owned by the "cups" package, so
# "apk upgrade cups" silently overwrites it and the fix silently stops working.
# Run this after any cups upgrade; exit status 0 = healthy, 1 = broken.
#
MARKER=cups-thread-stackfix-wrapper
BACKEND=${BACKEND:-/usr/lib/cups/backend/ipp}
SO=${PREFIX:-/usr/local}/lib/cups-thread-stackfix.so

rc=0

if grep -aq "$MARKER" "$BACKEND" 2>/dev/null; then
  echo "OK    $BACKEND is wrapped (overridden; owned by the cups package)"
else
  echo "FAIL  $BACKEND is the stock backend - the workaround is NOT active"
  echo "      (a 'cups' package upgrade has probably overwritten the wrapper)"
  rc=1
fi

if [ -e "$BACKEND.real" ]; then
  if grep -aq "$MARKER" "$BACKEND.real" 2>/dev/null; then
    echo "FAIL  $BACKEND.real is a wrapper, not the real backend"
    rc=1
  else
    echo "OK    real backend preserved at $BACKEND.real"
  fi
else
  echo "WARN  $BACKEND.real is missing"
fi

if [ -e "$SO" ]; then
  if [ -z "${LD_PRELOAD-}" ] && ! LD_PRELOAD="$SO" /bin/true 2>/dev/null; then
    echo "FAIL  $SO exists but cannot be preloaded"
    rc=1
  else
    echo "OK    shim at $SO"
  fi
else
  echo "FAIL  shim $SO is missing"
  rc=1
fi

exit $rc
