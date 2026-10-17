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

### It is not only the printer backend — `cupsd` crashes too

The same fault kills the **scheduler** while it is *creating* a driverless
queue, so on a musl system you cannot even set printing up:

```console
$ sudo lpadmin -p QUEUE -E -v ipp://host/ipp/print -m everywhere
lpadmin: Broken pipe
$ lpstat -r
scheduler is not running            # rc-service cupsd status -> crashed
$ sudo dmesg | grep cupsd
cupsd[8994]: segfault at ... error 6 in libcups.so.2[3074d,...]
```

`scheduler/ipp.c` generates the PPD in a background thread started with a
default stack — `create_local_bg_thread()` at `ipp.c:2697` and `ipp.c:5809` —
and that thread reaches the same ~65 KiB `httpPrintf()` frame.  Both call sites
are unconditional on the printer-add path.  Three faults (`cupsd` ×2,
`ipp` ×1) share the identical signature: `error 6`, `sp ==` fault address, and
libcups offset `0x3074d`.  Full run:
[`docs/CLEAN-REINSTALL-TEST.md`](docs/CLEAN-REINSTALL-TEST.md).

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
| [`evidence/dmesg-cupsd-and-ipp-noshim.txt`](evidence/dmesg-cupsd-and-ipp-noshim.txt) | **shim-free run**: `cupsd` ×2 and `ipp` ×1, all at libcups offset `0x3074d`, with the kernel's own `Code:` dump of the faulting probe |
| [`evidence/error-log-job7-noshim.txt`](evidence/error-log-job7-noshim.txt) | **shim-free job**: `status -11 (crashed)`, queue paused, nothing reached the printer |
| [`docs/CLEAN-REINSTALL-TEST.md`](docs/CLEAN-REINSTALL-TEST.md) | clean-reinstall A/B procedure and results |
| [`docs/APK-HOOK-TEST.md`](docs/APK-HOOK-TEST.md) | proof that the apk commit hook self-repairs, and that healthy transactions stay a no-op |

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

Whichever you choose, the bundled [`fix-cups-stack.sh`](fix-cups-stack.sh)
(= `cups-stackfix`) keeps the workaround alive:

```sh
# install the command once
sudo ln -sf "$PWD/fix-cups-stack.sh" /usr/local/bin/cups-stackfix

# optional: the short names 'fixcups' (repair) and 'cupsok' (check)
sudo cups-stackfix --commands

# and then never think about it again: apk runs this hook after every
# transaction, so a `cups` upgrade repairs itself before anything can fail
sudo cups-stackfix --apk-hook

# ...or, if you would rather do it by hand every time
sudo cups-stackfix              # (re-)apply the fix; re-enable paused queues
cups-stackfix --check           # is it still active?  exit 0 = yes, 1 = clobbered
sudo cups-stackfix --boot-hook  # alternative self-heal, at boot instead of at apk time
```

> **`fixcups`/`cupsok` are real executables in `/usr/local/bin`, not shell
> aliases.** Aliases only exist in the shell that read the file that defines
> them, and on Alpine that is `~/.profile` — which only *login* shells read
> (`ENV` is unset, so there is no rc file for interactive non-login shells).
> An alias added to `~/.profile` is therefore invisible in an ordinary terminal
> and in scripts, and stays invisible until the next login even though the file
> says otherwise. A file on `PATH` works in every shell, immediately, with no
> re-login — which is why `--commands` writes executables. They call the script
> by absolute path, so they do not depend on `PATH` either.

### Why `apk upgrade cups` breaks it, and how the hook fixes that

`/usr/lib/cups/backend/ipp` is **owned by the `cups` package**. The workaround
wraps that file, so a `cups` upgrade unpacks the stock backend straight over the
wrapper — silently, with no `.apk-new`, because the path is not a protected
config path. The next print then fails exactly as before, which is why "just
patch it once" is not good enough on a rolling/upgraded system.

`cups-stackfix --apk-hook` installs
[`hooks/apk-commit-hook-cups-stackfix.sh`](hooks/apk-commit-hook-cups-stackfix.sh)
as `/etc/apk/commit_hooks.d/cups-stackfix`. apk runs commit hooks after every
transaction (the stage arrives as `$1`), so the hook:

1. exits immediately on `pre-commit`;
2. runs `cups-stackfix --check --quiet` — a couple of file tests — and exits if
   all is well, so healthy transactions stay a **true no-op** (no log spam, no
   `cupsd` restart);
3. otherwise re-applies the fix and appends to `/var/log/cups-stackfix.log`;
4. always exits 0, so it can never fail an apk transaction.

Verified here against a real `apk fix cups`, which is the same file-overwriting
transaction as an upgrade:

```
BEFORE   cups-stackfix --check   rc=0   (healthy)
         apk fix cups            (Reinstalling cups 2.4.19-r0 -> wrapper overwritten)
AFTER    cups-stackfix --check   rc=0   (health restored by the hook)
         /var/log/cups-stackfix.log: "apk transaction left the CUPS thread-stack fix broken - re-applying"
queue    EPSON_L3260_ALPINE unchanged, still idle/enabled (printers.conf hash identical)
```

The script is idempotent (a no-op when the fix is already active), rebuilds from
source when a compiler is present, falls back to a cached build when one is not,
and re-enables any queue that CUPS paused.

### 1. Upstream patch — recommended

See [`patches/cups-2.4.19-thread-stacksize.patch`](patches/cups-2.4.19-thread-stacksize.patch).
It makes `_cupsThreadCreate()` raise the stack size to 8 MiB when the libc's
default is below 1 MiB (so glibc behaviour is unchanged).

```sh
# in a CUPS source tree
patch -p1 < patches/cups-2.4.19-thread-stacksize.patch
```

An Alpine (`aports`) package could carry this as a normal APKBUILD patch.

> Filed upstream as **OpenPrinting/cups#1766**:
> <https://github.com/OpenPrinting/cups/issues/1766>

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

> ### ⚠️ This silently stops working when `cups` is upgraded
>
> `/usr/lib/cups/backend/ipp` is **owned by the `cups` package**
> (`apk info --who-owns /usr/lib/cups/backend/ipp` → `cups-2.4.19-r0`).  apk
> simply unpacks the new package over it: `/usr/lib/cups/backend/ipp` is not a
> protected config path (only `/etc` gets `.apk-new` handling), so there is no
> warning, no `.apk-new` file, and no error.  The wrapper is gone, the shim is
> never loaded again, and your queue goes back to being paused by
> `Backend ipp returned status -11 (crashed)` — with the same misleading status
> text as before, so it is easy not to connect the two.
>
> Check and repair:
>
> ```sh
> ./scripts/check-stackfix.sh                  # exit 0 = healthy, 1 = broken
> sudo ./workaround/ld-preload/install.sh      # re-install; idempotent
> ```
>
> `install.sh` is safe to re-run: the wrapper embeds a marker string, so the
> installer can tell its own wrapper from a genuine backend and refresh
> `ipp.real` after an upgrade instead of copying the wrapper over it.  It also
> renames a temporary file into place rather than writing over `ipp.real`
> directly, because writing onto a file that a still-running backend is
> executing fails with `ETXTBSY` ("Text file busy").
>
> The shim in `/usr/local/lib` is *not* touched by apk (no package owns it) but
> is useless on its own.
>
> **The upstream patch (option 1) has no such problem**: the fix is compiled
> into `libcups.so.2` (which provides the exported `_cupsThreadCreate` that the
> `ipp` backend calls), so the package apk installs already contains it and
> there is nothing to re-install.

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
