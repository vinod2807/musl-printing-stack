# Draft upstream bug report

**Filed as <https://github.com/OpenPrinting/cups/issues/1766>** — this file is
kept as the source of the report that was submitted.

Suggested title:

> **`ipp` backend crashes (SIGSEGV) on musl: monitor thread uses the libc's
> default thread stack (128 KiB), but `httpPrintf()` needs 64 KiB**

Suggested venue: <https://github.com/OpenPrinting/cups/issues>

---

### Environment

* OS: Alpine Linux 3.24.2 (musl 1.2.6, x86_64)
* CUPS: 2.4.19 (`2505`-ish source line numbers below are from the 2.4.19 tarball)
* cups-filters: 1.28.17
* Printer: EPSON L3260 Series (IPP Everywhere), `ipp://<host>/ipp/print`

### Symptom

Any job sent to a driverless `ipp://` queue fails.  `cupsd` logs:

```
W [..] [Job 3] Backend ipp returned status -11 (crashed)
D [..] [Job 3] Printer stopped due to backend errors; please consult the /var/log/cups/error_log file for details.
D [..] [Job 3] printer-state-reasons=paused
```

and the queue is disabled.  The queue's status text (`Rendering completed`) is
misleading.

### Analysis

`backend/ipp.c` starts a monitor thread:

```c
  _cupsThreadCreate((_cups_thread_func_t)monitor_printer, &monitor);
```

`cups/thread.c`:

```c
_cups_thread_t
_cupsThreadCreate(_cups_thread_func_t func, void *arg)
{
  pthread_t thread;

  if (pthread_create(&thread, NULL, (void *(*)(void *))func, arg))   /* default stack */
    return (0);
  else
    return (thread);
}
```

`pthread_create(..., NULL, ...)` uses the libc's **default** thread stack size:

* glibc: 8 MiB
* **musl: 128 KiB**

The monitor thread calls `check_printer_state()` → `cupsDoRequest()` →
`cupsSendRequest()` → `httpOptions()` → `httpPrintf()`, and `httpPrintf()`
reserves a 64 KiB buffer on the stack (`char buf[65536]` in `cups/http.c`).
Result: stack overflow in the thread → SIGSEGV.

`dmesg`:

```
ipp[31505]: segfault at 7fa460679a50 ip 00007fa460fda74d sp 00007fa460679a50 error 6 in libcups.so.2[3074d,7fa460fc9000+44000]
```

`error 6` = user-mode write to a not-present page and `sp` == faulting address,
i.e. the stack-clash probe in `httpPrintf` running off the end of the stack.

gdb (crash is in a spawned thread, not main()):

```
#0 httpPrintf ()           libcups.so.2
#1 ..                      libcups.so.2
#2 httpOptions ()          libcups.so.2
#3 cupsSendRequest ()      libcups.so.2
#4 cupsDoIORequest ()      libcups.so.2
#5 ..                      backend/ipp   (monitor_printer)
#7 start (pthread_create.c:207)           <- musl
```

The code is unchanged in `v2.4.20` (latest release) and on `master`
(`_cupsThreadCreate` was only renamed to `cupsThreadCreate`).

### The scheduler is affected too

The same fault kills `cupsd` itself while it *creates* a driverless queue, so on
musl the queue cannot be created in the first place:

```console
$ sudo lpadmin -p QUEUE -E -v ipp://host/ipp/print -m everywhere
lpadmin: Broken pipe
$ lpstat -r
scheduler is not running
$ sudo rc-service cupsd status
 * status: crashed
```

`scheduler/ipp.c` generates the PPD in a background thread created with a
default stack:

```c
/* ipp.c:2692 — the ppd-name="everywhere" case, i.e. `lpadmin -m everywhere` */
cupsdLogClient(con, CUPSD_LOG_DEBUG, "Creating PPD in background thread.");
con->bg_pending = 1;
con->bg_printer = printer;
_cupsThreadCreate((_cups_thread_func_t)create_local_bg_thread, con);
```

```c
/* ipp.c:5270 */
 * 'create_local_bg_thread()' - Background thread for creating a local print queue.
    char device_uri[1024], fromppd[1024], toppd[1024], scheme[32],
         userpass[256], host[256], resource[1024], uri[1024], line[1024];
```

Both call sites (`ipp.c:2697` and `ipp.c:5809`) are unconditional on the
printer-add path.  Three crashes — `cupsd` ×2 and `ipp` ×1 — share the identical
signature (`error 6`, `sp` == faulting address, libcups offset `0x3074d`), and
the kernel's `Code:` dump shows the same `orq $0x0,(%rsp)` probe:

```
Code: ... 41 54 55 53 4c 8d 9c 24 00 00 ff ff 48 81 ec 00 10 00 00 <48> 83 0c 24 00 4c 39 dc 75 ef ...
                                               sub $0x1000,%rsp   orq $0x0,(%rsp)
```

### Suggested fix

Make `_cupsThreadCreate()` / `cupsThreadCreate()` ensure a usable stack size,
only raising it when the libc default is small (so glibc behaviour is
unchanged).  Patch against 2.4.19:

```c
  pthread_attr_t attr;
  size_t         stacksize;

  pthread_attr_init(&attr);

  if (!pthread_attr_getstacksize(&attr, &stacksize) && stacksize < 1024 * 1024)
    pthread_attr_setstacksize(&attr, 8 * 1024 * 1024);

  status = pthread_create(&thread, &attr, (void *(*)(void *))func, arg);
  pthread_attr_destroy(&attr);
```

(Alternative: avoid the 64 KiB stack frame in `httpPrintf()`.)

Full patch + reproduction + evidence:
<https://github.com/vinod2807/musl-printing-stack>
