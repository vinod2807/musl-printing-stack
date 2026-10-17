# LD_PRELOAD workaround

Gives CUPS threads created with a `NULL` attribute list an 8 MiB stack
(glibc's default), so the `ipp` backend's monitor thread no longer overflows
musl's 128 KiB default.

Because cupsd builds a fixed `envp[]` for the processes it spawns, the shim
cannot simply be exported — the installer therefore **wraps the `ipp` backend**
(a tiny binary that sets `LD_PRELOAD` and `execv`s the real backend).
The real backend is preserved as `/usr/lib/cups/backend/ipp.real`.

## Install

```sh
sudo ./install.sh
sudo cupsenable <queue>      # re-enable any queue CUPS paused
```

## Uninstall

```sh
sudo ./uninstall.sh
```

## Files

| File | Purpose |
|---|---|
| `thread-stackfix.c` | the shim itself (wraps `pthread_create`) |
| `ipp-wrapper.c` | sets `LD_PRELOAD`, execs `/usr/lib/cups/backend/ipp.real` |
| `install.sh` / `uninstall.sh` | build + install / revert |
| `shimcheck.c` | demonstrates the stack size, with and without the shim |

## Verify the shim

```sh
cc -O0 -o shimcheck shimcheck.c -lpthread
./shimcheck
LD_PRELOAD=/usr/local/lib/cups-thread-stackfix.so ./shimcheck
```

Expected on Alpine musl:

```
usable stack WITHOUT shim: 140 KiB
usable stack WITH shim:    8204 KiB
```

## Caveats

* **A `cups` package upgrade silently breaks this.**  `/usr/lib/cups/backend/ipp`
  is owned by the `cups` package, so apk unpacks the new backend straight over
  our wrapper — no warning, no `.apk-new`.  The shim is then never loaded and
  the queue goes back to being paused with `status -11 (crashed)`.
  Run `../../scripts/check-stackfix.sh` to test, then re-run `install.sh` to
  repair.  Both are safe to re-run.
* `install.sh` writes `ipp.real` via a temporary file + rename.  Writing onto it
  directly fails with `ETXTBSY` ("Text file busy") whenever a backend process is
  still executing it, which is common right after an upgrade.
* Only affects threads created with `pthread_create(..., NULL, ...)`; threads
  that pass explicit attributes are untouched.
