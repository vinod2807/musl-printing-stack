#!/bin/sh
#
# apk commit hook: keep the musl CUPS thread-stack fix applied.
#
# WHY
#   /usr/lib/cups/backend/ipp is OWNED BY THE cups PACKAGE, so
#
#     apk upgrade cups
#
#   silently overwrites the wrapper the workaround depends on and printing
#   breaks again with the same SIGSEGV symptoms.  This hook re-applies the
#   fix immediately after any apk transaction, so nobody has to remember.
#
# INSTALLED BY
#   cups-stackfix --apk-hook        (remove with: cups-stackfix --no-apk-hook)
#
# apk passes the stage as $1: 'pre-commit' or 'post-commit'.
#
# Upstream bug:    https://github.com/OpenPrinting/cups/issues/1766
# This repository: https://github.com/vinod2807/musl-printing-stack
#
[ "${1:-}" = post-commit ] || exit 0

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

FIX=cups-stackfix
if ! command -v "$FIX" >/dev/null 2>&1; then
	# The command that installed this hook is gone.  Say so rather than
	# silently allowing the workaround to lapse.
	printf '%s: %s is missing - cannot check the CUPS thread-stack fix\n' \
		"$(date -Is 2>/dev/null || date)" "$FIX" \
		>>"${STACKFIX_LOG:-/var/log/cups-stackfix.log}" 2>&1
	exit 0
fi

# Healthy?  Then do nothing at all: no log spam, no cupsd restart, no output.
"$FIX" --check --quiet && exit 0

# The wrapper was clobbered (or never installed) - repair it, leave a trail.
{
	printf '%s: apk transaction left the CUPS thread-stack fix broken - re-applying\n' \
		"$(date -Is 2>/dev/null || date)"
	"$FIX" --quiet --no-enable
} >>"${STACKFIX_LOG:-/var/log/cups-stackfix.log}" 2>&1

# Never fail the apk transaction.
exit 0
