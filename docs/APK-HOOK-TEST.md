# Test: `apk` commit hook repairs the workaround by itself

**Question.** Once the LD_PRELOAD workaround is installed, a `cups` package
upgrade silently overwrites `/usr/lib/cups/backend/ipp` (the package owns that
path, and it is not a protected config path, so there is no `.apk-new`). Can the
repair be made automatic, with no user action?

**Method.** `/etc/apk/commit_hooks.d/cups-stackfix` was installed with
`cups-stackfix --apk-hook`. `apk fix cups` is then used as the test transaction:
it re-extracts the `cups` package, i.e. performs exactly the same
file-overwriting transaction as `apk upgrade cups`, but deterministically and
without needing a newer version to exist.

Two properties matter, and both were checked:

1. a transaction that clobbers the wrapper must be repaired automatically, and
2. a transaction that does *not* clobber it must be a complete no-op (no log
   entries, and above all no gratuitous `cupsd` restart that could kill a job).

## 1. Clobbering transaction -> automatic repair

```
BEFORE
  cups-stackfix --check                    rc=0 (healthy)
  grep -c re-applying /var/log/cups-stackfix.log   1

  apk fix cups
    (1/1) Reinstalling cups (2.4.19-r0)
    Installing file to etc/cups/cupsd.conf.apk-new     <- protected path, ours kept
    OK: 3349.3 MiB in 847 packages

AFTER
  cups-stackfix --check                    rc=0 (healthy again, unassisted)
  grep -c re-applying /var/log/cups-stackfix.log   2
  tail /var/log/cups-stackfix.log
    2026-10-17T14:53:00+00:00: apk transaction left the CUPS thread-stack fix broken - re-applying
    == building ==
    == installing shim -> /usr/local/lib/cups-thread-stackfix.so ==
    == wrapping /usr/lib/cups/backend/ipp ==
       preserving real backend -> /usr/lib/cups/backend/ipp.real
    == restarting cupsd ==
     * Stopping CUPS ... [ ok ]
     * Starting CUPS ... [ ok ]
```

Nothing else was disturbed: `/etc/cups/printers.conf` hashes identically before
and after (`a8c180fe…58f68a`) because it is not package-owned, and both queues
(`EPSON_L3260_ALPINE`, `KONICA206_ALPINE`) remain present and enabled. The only
debris is `/etc/cups/cupsd.conf.apk-new`, which apk writes because `cupsd.conf`
*is* package-owned and locally modified — apk correctly preserved our version.
That file is inert and can be deleted.

## 2. Healthy transaction -> true no-op

```
  grep -c re-applying /var/log/cups-stackfix.log   2
  grep -c 'Starting CUPS'  /var/log/cups-stackfix.log   2

  apk fix logrotate
    OK: 3349.3 MiB in 847 packages

  grep -c re-applying /var/log/cups-stackfix.log   2   (unchanged)
  grep -c 'Starting CUPS'  /var/log/cups-stackfix.log   2   (unchanged)
```

The hook short-circuits on `cups-stackfix --check --quiet`, so a routine
transaction costs two file tests and touches nothing.

## Why `post-commit` and why `--no-enable`

* The hook ignores `pre-commit`. Doing the work before the transaction would be
  pointless: apk would then overwrite the wrapper afterwards.
* The hook repairs with `--no-enable`, so it never un-pauses a queue. The
  upgrade itself does *not* pause anything (CUPS only pauses after a backend
  actually crashes), so by repairing at commit time the failure never gets a
  chance to happen — and the hook therefore never needs to touch queue state.
  A queue that a user paused deliberately stays paused. To re-enable one after a
  manual investigation, run `sudo cups-stackfix` (which does re-enable, and says
  how many queued jobs that will release).
* The hook always exits 0, so a broken workaround can never fail an apk
  transaction.

## Does the hook fire on a *general* upgrade?

Yes. apk commit hooks are attached to the **commit step**, not to a particular
operation, so any real transaction triggers them: `apk upgrade` (whole system or
a single package), `apk add`, `apk del`, `apk fix`. There is nothing
cups-specific about the mechanism.

Verified with a purpose-built throwaway package (`stackfix-dummy` 1.0.0/1.0.1 in
a scratch local repository — since this machine has pending `ghostscript` and
`linux-lts` updates, running a real system-wide `apk upgrade` just to test would
have installed them):

| apk operation | wrapper clobbered beforehand | hook fired? | result |
|---|---|---|---|
| `apk fix cups` (the upgrade-shaped transaction) | yes | **yes** | repaired |
| `apk fix logrotate` (unrelated transaction) | yes | **yes** | repaired |
| `apk add <file>.apk` | yes | **yes** | repaired |
| `apk upgrade <pkg>` (literal upgrade subcommand) | yes | **yes** | repaired |
| `apk upgrade <pkg> --simulate` | yes | **no** | left broken (no commit happened) |
| `apk upgrade` / `apk fix` with the fix already healthy | no | yes (runs) | **no-op** — no log entry, no cupsd restart |

Two things worth noting from that table:

* The `--simulate` row is the useful control: it proves the repair really comes
  from the commit hook rather than from anything else on the system, because the
  identical command without `--simulate` does repair.
* The hook runs for **every** real transaction, even one that changes nothing
  (a real `apk upgrade` that has nothing to do still reaches the commit step).
  That is harmless precisely because of the fast path: the hook re-checks and
  short-circuits, so routine apk use costs two file tests and restarts nothing.

Because a hook runs at *post*-commit, on a large system-wide upgrade `cups` may
be overwritten early and the wrapper re-armed only at the end of the
transaction. Nothing normally prints inside that window, and any print attempt
afterwards finds a working backend.

## Limitation

This covers any change made *through apk* (`upgrade`, `fix`, reinstall of
`cups`). A wrapper clobbered by hand — e.g. copying a backend over it outside
apk — is not caught until the next transaction, which `cups-stackfix --check`
detects, or by the alternative `--boot-hook`.
