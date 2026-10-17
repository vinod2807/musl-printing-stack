#!/bin/sh
#
# Reproduce the crash on a musl system with CUPS.
#
# Prerequisites: Alpine/musl, cups, cups-filters, gdb, and a driverless
# (IPP Everywhere) queue created with an ipp:// URI.
#
set -u

QUEUE=${QUEUE:-EPSON_L3260_ALPINE}
URI=${URI:-ipp://192.168.1.19/ipp/print}

echo "== 1. submit a job and watch the queue =="
echo "   (use any file; the crash happens as soon as the backend starts)"
# lp -d "$QUEUE" /path/to/file.pdf

echo
echo "== 2. after it fails, look at the scheduler log =="
echo "   sudo grep -E 'crashed|backend errors|state-reasons=paused' /var/log/cups/error_log"
sudo grep -E 'Backend ipp returned status -11|Printer stopped due to backend errors|printer-state-reasons=paused' \
     /var/log/cups/error_log 2>/dev/null | tail -5

echo
echo "== 3. kernel log shows the stack overflow =="
echo "   sudo dmesg | grep 'ipp\\['"
sudo dmesg 2>/dev/null | grep 'ipp\[' | tail -5

echo
echo "== 4. run the backend directly under gdb =="
echo "   sudo env DEVICE_URI=$URI CUPS_SERVERBIN=/usr/lib/cups \\"
echo "        gdb -q -batch -ex run -ex 'bt 20' \\"
echo "        --args /usr/lib/cups/backend/ipp 999 \"\$USER\" manual 1 \\"
echo "               'document-format=image/urf' /dev/null"
printf 'hello' > /tmp/urf.bin
sudo env DEVICE_URI="$URI" CUPS_SERVERBIN=/usr/lib/cups \
     gdb -q -batch -ex 'set pagination off' -ex run -ex 'bt 20' \
     --args /usr/lib/cups/backend/ipp 999 "$USER" manual 1 \
            'document-format=image/urf' /tmp/urf.bin 2>&1 | tail -20

echo
echo "== 5. demonstrate the stack size itself =="
echo "   cc -O0 -o shimcheck shimcheck.c -lpthread && ./shimcheck"
