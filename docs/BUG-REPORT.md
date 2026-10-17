# Draft upstream bug report

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
