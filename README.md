# CUPS `ipp` backend segfaults on musl (Alpine Linux): 128 KiB thread stack overflow

## TL;DR

CUPS' `ipp` backend starts its printer-monitor thread with
`pthread_create(&thread, NULL, ...)`, i.e. with the **default** thread stack size.

* glibc default: **8 MiB**
* musl default: **128 KiB**

That thread calls `cupsDoRequest()` → `cupsSendRequest()` → `httpPrintf()`, and
`httpPrintf()` uses a **64 KiB** stack buffer (`char buf[65536]` in `cups/http.c`).
The 128 KiB stack overflows, the backend dies with **SIGSEGV**, and CUPS reacts
by **disabling (pausing) the print queue**:

```
W [..] [Job 3] Backend ipp returned status -11 (crashed)
D [..] [Job 3] Printer stopped due to backend errors; please consult the /var/log/cups/error_log file for details.
D [..] [Job 3] printer-state-reasons=paused
```

The queue then displays a misleading status such as `Rendering completed`, and
every job stays queued forever until the queue is re-enabled — at which point it
crashes again immediately.

## Affected

| | |
|---|---|
| OS | Alpine Linux 3.24.2 (any musl system) |
| libc | musl 1.2.6 |
| CUPS | 2.4.19 (verified) |
| cups-filters | 1.28.17 |
| Printer | EPSON L3260 Series (IPP Everywhere / AirPrint), firmware 05.24.XE13Q2 |
| URI | `ipp://192.168.1.19/ipp/print` |

**There is no upstream fix.** The same code exists in:

* `v2.4.20` — the latest CUPS release (Oct 2026)
* `master` — the development branch (`cupsThreadCreate()` was merely renamed
  from `_cupsThreadCreate()`)

glibc-based distributions are unaffected because their default thread stack is
8 MiB.

## Root cause

`backend/ipp.c` (CUPS 2.4.19, line 1497):

```c
  _cupsThreadCreate((_cups_thread_func_t)monitor_printer, &monitor);
```

`cups/thread.c` — `_cupsThreadCreate()`:

```c
_cups_thread_t
_cupsThreadCreate(_cups_thread_func_t func, void *arg)
{
  pthread_t thread;

  if (pthread_create(&thread, NULL, (void *(*)(void *))func, arg))   /* <-- default stack */
    return (0);
  else
    return (thread);
}
```

The monitor thread calls `check_printer_state()` → `cupsDoRequest()` →
`cupsSendRequest()` → `httpOptions()` → `httpPrintf()`.  And `cups/http.c`:

```c
int
httpPrintf(http_t *http, const char *format, ...)
{
  ssize_t bytes;      /* Number of bytes to write */
  char    buf[65536]; /* Buffer for formatted string */   /* <-- 64 KiB on the stack */
  ...
}
```

A single HTTP request therefore needs ~64 KiB of stack.  musl's 128 KiB thread
stack is exhausted → SIGSEGV.

## Evidence

| File | What it shows |
|---|---|
| [`evidence/dmesg-segfault.txt`](evidence/dmesg-segfault.txt) | `segfault ... error 6 in libcups.so.2` (`error 6` = user-mode write to a non-present page, `sp ==` faulting address ⇒ stack overflow) |
| [`evidence/cups-error-log-excerpt.txt`](evidence/cups-error-log-excerpt.txt) | `Backend ipp returned status -11 (crashed)` / `printer-state-reasons=paused` |
| [`evidence/source-excerpts.txt`](evidence/source-excerpts.txt) | The offending source lines |
| [`evidence/gdb-backtrace.txt`](evidence/gdb-backtrace.txt) | Backtrace showing the spawned monitor thread |
| [`evidence/environment.txt`](evidence/environment.txt) | Environment + measured 128 KiB default stack |

The faulting instruction (`ip = libcups+0x3074d`) is the compiler's stack-clash
probe inside `httpPrintf`:

```asm
httpPrintf:
  lea  -0x10000(%rsp),%r11      ; 64 KiB frame
  sub  $0x1000,%rsp
  orq  $0x0,(%rsp)              ; <-- FAULT: probing an unmapped page
  cmp  %r11,%rsp
  jne  ...
```

Measured default thread stack on musl:

```
$ ./shimcheck
usable stack WITHOUT shim: 140 KiB
usable stack WITH shim:    8204 KiB
```

## Fixes / workarounds

### 1. Upstream patch — recommended

See [`patches/cups-2.4.19-thread-stacksize.patch`](patches/cups-2.4.19-thread-stacksize.patch).
It makes `_cupsThreadCreate()` raise the stack size to 8 MiB when the libc's
default is below 1 MiB (so glibc behaviour is unchanged).

```sh
# in a CUPS source tree
patch -p1 < patches/cups-2.4.19-thread-stacksize.patch
```

An Alpine (`aports`) package could carry this as a normal APKBUILD patch.

### 2. LD_PRELOAD shim — works today, no rebuild

See [`workaround/ld-preload/`](workaround/ld-preload/). It gives threads created
with a `NULL` attribute list an 8 MiB stack.

```sh
cd workaround/ld-preload
sudo ./install.sh          # builds + installs shim and backend wrapper
```

Because CUPS sanitises the environment of the processes it spawns, the shim
cannot be injected with a plain `LD_PRELOAD`; the installer therefore wraps the
`ipp` backend (real backend is kept as `/usr/lib/cups/backend/ipp.real`).

### 3. `socket://` (raw port 9100) — ✗ NOT a fix

Switching the queue to `socket://<host>:9100` avoids the crashing monitor thread,
but the driverless PPD emits **Apple Raster (`image/urf`)**, and this printer
does not accept URF on its raw/AppSocket port — it printed **gibberish**.
See [`workaround/socket-backend/README.md`](workaround/socket-backend/README.md).

## Reproduction

1. Alpine (musl) + CUPS, an IPP Everywhere / driverless queue created with an
   `ipp://` URI.
2. Print anything.  The backend crashes as soon as it starts its monitor thread.
3. `dmesg` shows the segfault; `error_log` shows `status -11 (crashed)` and the
   queue is paused.

See [`scripts/reproduce.sh`](scripts/reproduce.sh).

## Side note: `cupsenable`/`lpadmin` return 403 on this system

Unrelated to the crash, but it blocks recovery: Alpine's `cups-files.conf`
contains `SystemGroup lpadmin`, and the `lpadmin` group is **empty** by default,
so neither the user nor `root` is authorised for administrative operations
(`client-error-forbidden` / `403`).  Fix with, e.g.:

```sh
sudo gpasswd -a root lpadmin     # or: sudo gpasswd -a <user> lpadmin
```

## License

MIT — see [LICENSE](LICENSE).
