/*
 * ipp wrapper for the CUPS "ipp" backend.
 *
 * CUPS sanitises the environment of the processes it spawns, so the shim
 * cannot be injected with a plain LD_PRELOAD (the backend inherits a fixed
 * envp[] built by cupsd).  This wrapper sets LD_PRELOAD itself and then execs
 * the real backend, preserving CUPS' argument vector (argv[0] is the device
 * URI, which some code paths still use).
 *
 * Real backend: /usr/lib/cups/backend/ipp.real
 * Shim:         /usr/local/lib/cups-thread-stackfix.so
 *
 * Build:  cc -O2 -Wall -o ipp-wrapper ipp-wrapper.c
 */
#include <unistd.h>
#include <stdlib.h>

#define REAL_BACKEND "/usr/lib/cups/backend/ipp.real"
#define PRELOAD_SO   "/usr/local/lib/cups-thread-stackfix.so"

int main(int argc, char **argv)
{
  (void)argc;

  setenv("LD_PRELOAD", PRELOAD_SO, 1);

  execv(REAL_BACKEND, argv);

  /* execv only returns on error. */
  return 126;
}
