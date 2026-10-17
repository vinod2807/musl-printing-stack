#!/bin/sh
#
# cups-stackfix - re-apply the musl thread-stack workaround for CUPS.
#
# WHY THIS EXISTS
#   CUPS starts threads with the libc's *default* stack size.  glibc defaults to
#   8 MiB; musl (Alpine) defaults to only 128 KiB, which is too small for the
#   ~64 KiB stack frame that httpPrintf() reserves.  On Alpine that makes both
#
#     * cupsd - die while creating a driverless queue (`lpadmin -m everywhere`)
#     * the ipp backend - die while printing
#
#   with SIGSEGV, after which CUPS pauses the queue and the printer looks
#   "broken" for no visible reason.
#
# WHY YOU RE-RUN IT
#   The fix works by wrapping /usr/lib/cups/backend/ipp, which is OWNED BY THE
#   cups PACKAGE.  `apk upgrade cups` silently overwrites the wrapper, so the
#   fix stops working - with exactly the same symptoms as before.  Run this
#   script again after every cups upgrade.
#
#   This script is idempotent: if the fix is already active it takes the fast
#   path and changes nothing.
#
# USAGE
#   cups-stackfix                 re-apply the fix, re-enable paused queues
#   cups-stackfix --check         report only; exit 0 if the fix is active
#   cups-stackfix --no-enable     do not re-enable paused queues
#   cups-stackfix --apk-hook      install the apk commit hook (do it once!)
#   cups-stackfix --no-apk-hook   remove that hook
#   cups-stackfix --commands      install the short names fixcups/cupsok
#   cups-stackfix --no-commands   remove them
#   cups-stackfix --boot-hook     also install a boot-time self-heal
#   cups-stackfix --no-boot-hook  remove that boot-time self-heal
#   cups-stackfix -q|--quiet      less chatty
#
# NOTE ON SHORT NAMES
#   `fixcups` and `cupsok` are installed as real executables in /usr/local/bin,
#   NOT as shell aliases.  Aliases only exist in shells that read the file they
#   are defined in - on Alpine that is just ~/.profile, i.e. login shells - so
#   they are invisible in an ordinary terminal and in scripts.  A file on PATH
#   works everywhere, immediately, with no re-login.
#
# IF YOU NEVER WANT TO THINK ABOUT THIS AGAIN
#   sudo cups-stackfix --apk-hook
#   ...and then `apk upgrade cups` repairs itself, because apk runs the hook
#   after every transaction.  See hooks/apk-commit-hook-cups-stackfix.sh.
#
# Upstream bug:    https://github.com/OpenPrinting/cups/issues/1766
# This repository: https://github.com/vinod2807/musl-printing-stack
#
set -eu

SELF=$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")
ROOT=$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd)
LD_DIR="$ROOT/workaround/ld-preload"
CACHE_DIR="$ROOT/.cache"

BACKEND=${BACKEND:-/usr/lib/cups/backend/ipp}
PREFIX=${PREFIX:-/usr/local}
SO="$PREFIX/lib/cups-thread-stackfix.so"
MARKER=cups-thread-stackfix-wrapper
LOCALD_DIR=${LOCALD_DIR:-/etc/local.d}
HOOK_NAME=cups-stackfix.start

APK_HOOK_DIR=${APK_HOOK_DIR:-/etc/apk/commit_hooks.d}
APK_HOOK_NAME=cups-stackfix
APK_HOOK_SRC="$ROOT/hooks/apk-commit-hook-cups-stackfix.sh"

BIN_DIR=${BIN_DIR:-/usr/local/bin}

mode=fix
quiet=0
enable=1
boot=0
apk=0
cmds=0

usage() {
  cat <<'EOF'
cups-stackfix - re-apply the musl thread-stack workaround for CUPS

  cups-stackfix                 re-apply the fix, re-enable paused queues
  cups-stackfix --check         report only; exit 0 if the fix is active
  cups-stackfix --no-enable     do not re-enable paused queues
  cups-stackfix --apk-hook      install the apk commit hook (do it once!)
  cups-stackfix --no-apk-hook   remove that hook
  cups-stackfix --commands      install the short names fixcups/cupsok
  cups-stackfix --no-commands   remove them
  cups-stackfix --boot-hook     also install a boot-time self-heal
  cups-stackfix --no-boot-hook  remove that boot-time self-heal
  cups-stackfix -q|--quiet      less chatty
  cups-stackfix -h|--help       this text

`apk upgrade cups` silently overwrites the wrapper this fix relies on, so it
has to be re-applied.  Either run this script again, or install the hook once
and let it repair itself:

  sudo cups-stackfix --apk-hook

For the short names (`fixcups`, `cupsok`):

  sudo cups-stackfix --commands
EOF
}

die() {
  printf 'cups-stackfix: error: %s\n' "$*" >&2
  exit 1
}

say() {
  [ "$quiet" = 1 ] || printf '%s\n' "$*"
}

# ---------------------------------------------------------------------------
# Re-exec as root, but only for operations that need it.
# ---------------------------------------------------------------------------
case "${1:-}" in
  --check|-h|--help) ;;
  *)
    if [ "$(id -u)" != 0 ]; then
      command -v sudo >/dev/null 2>&1 || die "must be run as root (no sudo found)"
      exec sudo -- "$SELF" "$@"
    fi
    ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --check)     mode=check ;;
    -q|--quiet)  quiet=1 ;;
    --no-enable) enable=0 ;;
    --apk-hook)     apk=install ;;
    --no-apk-hook)  apk=remove ;;
    --commands)     cmds=install ;;
    --no-commands)  cmds=remove ;;
    --boot-hook)    boot=install ;;
    --no-boot-hook) boot=remove ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown option '$1' (try --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Is the fix in place?
# ---------------------------------------------------------------------------
is_fixed() {
  grep -aq "$MARKER" "$BACKEND" 2>/dev/null && [ -e "$SO" ]
}

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------
if [ "$mode" = check ]; then
  if is_fixed; then
    say "cups-stackfix: ACTIVE - the upstream bug is worked around"
    [ "$quiet" = 1 ] || [ ! -x "$ROOT/scripts/check-stackfix.sh" ] || "$ROOT/scripts/check-stackfix.sh" || true
    exit 0
  fi
  say "cups-stackfix: NOT ACTIVE - the wrapper is missing (cups upgrade?)."
  say "               run: cups-stackfix"
  [ "$quiet" = 1 ] || [ ! -x "$ROOT/scripts/check-stackfix.sh" ] || "$ROOT/scripts/check-stackfix.sh" || true
  exit 1
fi

# ---------------------------------------------------------------------------
# (Re-)install the fix
# ---------------------------------------------------------------------------
ensure_fix() {
  if is_fixed; then
    say "cups-stackfix: fix already active, nothing to rebuild"
    return 0
  fi

  [ -d "$LD_DIR" ] || die "workaround sources not found in $LD_DIR"
  [ -f "$LD_DIR/install.sh" ] || die "missing $LD_DIR/install.sh"

  if command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1; then
    say "cups-stackfix: fix is missing - rebuilding and reinstalling"
    ( cd "$LD_DIR" && ./install.sh ) || die "install.sh failed"

    # Cache the artifacts so a future run works without a compiler.
    mkdir -p "$CACHE_DIR"
    cp -p "$LD_DIR/thread-stackfix.so" "$LD_DIR/ipp-wrapper" "$CACHE_DIR/" 2>/dev/null || true
  else
    say "cups-stackfix: fix is missing and there is no C compiler"
    if [ -f "$CACHE_DIR/thread-stackfix.so" ] && [ -f "$CACHE_DIR/ipp-wrapper" ]; then
      say "cups-stackfix: installing the cached build instead"
      cp -p "$CACHE_DIR/thread-stackfix.so" "$CACHE_DIR/ipp-wrapper" "$LD_DIR/"
      ( cd "$LD_DIR" && PREBUILT=1 ./install.sh ) || die "install.sh failed"
    else
      die "no compiler and no cached build in $CACHE_DIR - install gcc (apk add gcc musl-dev)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Re-enable queues that CUPS paused because of the crash
# ---------------------------------------------------------------------------
reenable_queues() {
  names=$(lpstat -p 2>/dev/null | awk '$1 == "printer" && /disabled/ { print $2 }' | sort -u) || true

  if [ -z "${names:-}" ]; then
    say "cups-stackfix: no paused queues"
    return 0
  fi

  for q in $names; do
    pending=$(lpstat -o "$q" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$pending" = 0 ]; then
      say "cups-stackfix: re-enabling queue '$q'"
    else
      say "cups-stackfix: re-enabling queue '$q' - $pending queued job(s) will now print"
    fi
    cupsenable "$q" 2>/dev/null || say "               (could not enable '$q')"
  done
}

# ---------------------------------------------------------------------------
# Optional boot-time self-heal
# ---------------------------------------------------------------------------
install_boot_hook() {
  [ -d "$LOCALD_DIR" ] || die "$LOCALD_DIR does not exist (OpenRC local service not installed?)"

  hook="$LOCALD_DIR/$HOOK_NAME"
  printf '#!/bin/sh\n# Installed by cups-stackfix - re-applies the CUPS musl thread-stack fix.\nexec %s --quiet --no-enable\n' "$SELF" > "$hook"
  chmod 0755 "$hook"
  say "cups-stackfix: installed boot hook $hook"

  if ! rc-update show default 2>/dev/null | grep -q '[[:space:]]local[[:space:]]'; then
    say "cups-stackfix: NOTE - the OpenRC 'local' service is not enabled, so the hook"
    say "               will not run at boot until you do:"
    say "                 sudo rc-update add local default"
  fi
}

remove_boot_hook() {
  hook="$LOCALD_DIR/$HOOK_NAME"
  if [ -e "$hook" ]; then
    rm -f "$hook"
    say "cups-stackfix: removed boot hook $hook"
  else
    say "cups-stackfix: no boot hook installed"
  fi
}

# ---------------------------------------------------------------------------
# apk commit hook - the "never think about it again" option
#
# apk runs these after every transaction (stage as $1), so a cups upgrade
# repairs itself before anything can fail.
# ---------------------------------------------------------------------------
apk_hook_path() {
  printf '%s/%s' "$APK_HOOK_DIR" "$APK_HOOK_NAME"
}

install_apk_hook() {
  [ -f "$APK_HOOK_SRC" ] || die "hook source not found: $APK_HOOK_SRC"
  [ -d "$APK_HOOK_DIR" ] || mkdir -p "$APK_HOOK_DIR" || die "cannot create $APK_HOOK_DIR"

  hook=$(apk_hook_path)
  install -m 0755 "$APK_HOOK_SRC" "$hook" || die "cannot install $hook"
  say "cups-stackfix: installed apk commit hook $hook"
  say "               (apk will now re-apply the fix by itself after any upgrade)"
}

remove_apk_hook() {
  hook=$(apk_hook_path)
  if [ -e "$hook" ]; then
    rm -f "$hook"
    say "cups-stackfix: removed apk commit hook $hook"
  else
    say "cups-stackfix: no apk commit hook installed"
  fi
}

# ---------------------------------------------------------------------------
# Short names (fixcups, cupsok) - real executables, not aliases
#
# Aliases live only in the shell that read the file defining them; on Alpine
# that is ~/.profile, i.e. login shells only.  An executable on PATH works in
# every shell, in scripts, and for every user, with no re-login.
# ---------------------------------------------------------------------------
write_command() {
  target=$1
  extra=$2
  cat > "$target" <<EOF
#!/bin/sh
# Installed by 'cups-stackfix --commands'.
# CUPS musl thread-stack fix: https://github.com/vinod2807/musl-printing-stack
exec "$SELF" $extra "\$@"
EOF
  chmod 0755 "$target" || die "cannot chmod $target"
}

install_commands() {
  [ -d "$BIN_DIR" ] || mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"
  write_command "$BIN_DIR/fixcups" ""
  write_command "$BIN_DIR/cupsok" "--check"
  say "cups-stackfix: installed $BIN_DIR/fixcups and $BIN_DIR/cupsok"
}

remove_commands() {
  for c in fixcups cupsok; do
    f="$BIN_DIR/$c"
    [ -e "$f" ] || continue
    if grep -q 'musl-printing-stack' "$f" 2>/dev/null; then
      rm -f "$f"
      say "cups-stackfix: removed $f"
    else
      say "cups-stackfix: $f is not ours - leaving it alone"
    fi
  done
}

# ---------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------
ensure_fix

if ! is_fixed; then
  die "the fix did not take effect - check $BACKEND and $SO"
fi
say "cups-stackfix: verified active"

if [ "$enable" = 1 ]; then
  reenable_queues
fi

case "$boot" in
  install) install_boot_hook ;;
  remove)  remove_boot_hook ;;
esac

case "$apk" in
  install) install_apk_hook ;;
  remove)  remove_apk_hook ;;
esac

case "$cmds" in
  install) install_commands ;;
  remove)  remove_commands ;;
esac

say "cups-stackfix: done"
