# Clean reinstall test — no shim, stock packages

A/B test to confirm the diagnosis on a pristine system: the LD_PRELOAD
workaround was removed, the queue deleted, and the queue rebuilt from scratch.

## Setup

```sh
# 1. remove the workaround entirely
cd workaround/ld-preload && sudo ./uninstall.sh

# verify the backend is byte-identical to the package file again
sha256sum /usr/lib/cups/backend/ipp        # e2b95fd4...  == the stock backend
ls /usr/local/lib/cups-thread-stackfix.so  # No such file

# 2. delete the queue
sudo lpadmin -x EPSON_L3260_ALPINE

# 3. rebuild it, driverless
sudo lpadmin -p EPSON_L3260_ALPINE -E -v ipp://192.168.1.19/ipp/print -m everywhere
```

## Result 1 — rebuilding the queue crashes `cupsd`

Step 3 does not work. It does not merely fail; it **kills the scheduler**:

```console
$ sudo lpadmin -p EPSON_L3260_ALPINE -E -v ipp://192.168.1.19/ipp/print -m everywhere
lpadmin: Broken pipe
$ lpstat -r
scheduler is not running
$ sudo rc-service cupsd status
 * status: crashed
```

Reproduced twice, on demand. The kernel log:

```
cupsd[8994]: segfault at 7fdfb14160a0 ip 00007fdfb1db874d sp 00007fdfb14160a0 error 6 in libcups.so.2[3074d,...]
cupsd[9162]: segfault at 7fd7a9ade0a0 ip 00007fd7aa46c74d sp 00007fd7a9ade0a0 error 6 in libcups.so.2[3074d,...]
```

Same offset `0x3074d` as the `ipp` backend crash — the `orq $0x0,(%rsp)` probe in
`httpPrintf()`. The traversed code:

```c
/* scheduler/ipp.c:2692 — the ppd-name="everywhere" case, i.e. `lpadmin -m everywhere` */
cupsdLogClient(con, CUPSD_LOG_DEBUG, "Creating PPD in background thread.");
con->bg_pending = 1;
con->bg_printer = printer;
_cupsThreadCreate((_cups_thread_func_t)create_local_bg_thread, con);   /* NULL attrs */
```

```c
/* scheduler/ipp.c:5270 */
 * 'create_local_bg_thread()' - Background thread for creating a local print queue.
    char device_uri[1024], fromppd[1024], toppd[1024], scheme[32],
         userpass[256], host[256], resource[1024], uri[1024], line[1024];
```

`_cupsThreadCreate()` passes `NULL` for the attributes, so this thread gets
musl's 128 KiB default and then calls `httpPrintf()`, whose frame is
`0x10000 + 0xd0` ≈ 65.2 KiB.  `cupsd` therefore cannot create a local print
queue on musl at all.

Both call sites — `ipp.c:2697` and `ipp.c:5809` — are unconditional on the
printer-add path, so this is not avoidable by changing how the queue is added.

## Result 2 — printing still crashes the backend

Since the queue could not be created through `lpadmin`, it was restored by
installing the driverless PPD and rebuilding `printers.conf` directly (see the
tip below), then the original job was resubmitted:

```console
$ lp -d EPSON_L3260_ALPINE original-job3.pdf
request id is EPSON_L3260_ALPINE-7 (1 file(s))
$ sleep 6; lpstat -p EPSON_L3260_ALPINE
printer EPSON_L3260_ALPINE disabled since Sat Oct 17 14:39:16 2026 -
	Rendering completed
```

```
D [..] [Job 7] PID 9388 (/usr/lib/cups/backend/ipp) crashed on signal 11.
W [..] [Job 7] Backend ipp returned status -11 (crashed)
D [..] [Job 7] printer-state-reasons=paused
```

Job 7 stays queued forever; nothing reaches the printer.

## Paper usage

Zero. The `ipp` backend dies in its monitor thread before the document is
submitted, so a failing job consumes no paper. Confirmed against the device
itself — its job list shows only the earlier jobs (ids 4 and 5), not job 7.

## Bypassing the scheduler crash

To restore a queue without invoking the crashing background thread, put the PPD
in place yourself and leave `printers.conf` alone:

```sh
sudo rc-service cupsd stop
sudo install -o root -g lp -m 0640 saved-model.ppd /etc/cups/ppd/<queue>.ppd
sudo rc-service cupsd start
```

A `<Printer>` block already present in `printers.conf` (the failed `lpadmin`
leaves one behind, without `MakeModel`) then becomes a working driverless queue
once the PPD exists. Check with `lpoptions -p <queue> -l` — it should list the
PPD's options.
