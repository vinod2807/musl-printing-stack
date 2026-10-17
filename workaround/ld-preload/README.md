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

* A `cups` package upgrade replaces `/usr/lib/cups/backend/ipp`, silently
  removing the wrapper.  Re-run `install.sh` after such an upgrade
  (or use the upstream patch instead).
* Only affects threads created with `pthread_create(..., NULL, ...)`; threads
  that pass explicit attributes are untouched.
