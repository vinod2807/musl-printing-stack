# `socket://` (raw port 9100) — tested, does NOT work ✗

## Idea

The crash happens in the `ipp` backend's monitor thread.  The `socket` backend
has no such thread (it uses a `select()` loop, `backendRunLoop`), so pointing the
queue at the printer's raw/AppSocket port should sidestep the bug entirely — and
it is a pure configuration change that survives package upgrades.

## Test

```sh
sudo lpadmin -p EPSON_L3260_ALPINE -v socket://192.168.1.19:9100
lp -d EPSON_L3260_ALPINE file.pdf
```

Port 9100 was **open**, and the data was streamed successfully:

```
[Job 6] Started backend /usr/lib/cups/backend/socket
[Job 6] backendRunLoop(print_fd=0, device_fd=6, snmp_fd=5, ...)
[Job 6] Read 8192 bytes of print data...
[Job 6] Wrote 8192 bytes of print data...
...
[Job 6] Read 6713 bytes of print data...
[Job 6] Wrote 6713 bytes of print data...
```

No crash, and the printer went `processing` → `idle`.

## Result: gibberish

The printer **printed garbage**.  Reason: this is a driverless
(IPP Everywhere / AirPrint) PPD, so the final content type is **Apple Raster
(`image/urf`)**:

```
*NickName: "EPSON L3260 Series, driverless, cups-filters 1.28.17"
*cupsFilter2: "image/urf image/urf 0 -"
```

The Epson L3260 does not understand a raw URF stream on port 9100 — that format
is only expected through IPP.  The raw port would need PCL/ESC-P-R (or a
converter), which the driverless PPD does not produce.

## Conclusion

`socket://` is **not** a usable workaround here.  Revert:

```sh
sudo lpadmin -p EPSON_L3260_ALPINE -v ipp://192.168.1.19/ipp/print
```

(It could still work on a printer that natively accepts PWG/URF on its raw
port, or if the queue used a PCL/ESC-P-R driver instead of a driverless PPD.)
