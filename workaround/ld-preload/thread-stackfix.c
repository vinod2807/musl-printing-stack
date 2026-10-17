/*
 * cups-thread-stackfix.so - work around CUPS' assumption of a large default
 *                           thread stack on musl (Alpine Linux).
 *
 * CUPS' "ipp" backend starts its printer-monitor thread with
 *
 *     _cupsThreadCreate((_cups_thread_func_t)monitor_printer, &monitor);
 *
 * and _cupsThreadCreate() (cups/thread.c) does
 *
 *     pthread_create(&thread, NULL, func, arg);
 *
 * i.e. it accepts the libc's *default* thread stack size.  On glibc that is
 * 8 MiB, but on musl it is only 128 KiB.  That thread then calls
 * check_printer_state() -> cupsDoRequest() -> cupsSendRequest() ->
 * httpOptions()/httpPrintf(), and httpPrintf() alone uses a 64 KiB stack
 * buffer ("char buf[65536]" in cups/http.c).  The 128 KiB stack overflows, the
 * backend dies with SIGSEGV and CUPS disables (pauses) the print queue.
 *
 * This preload gives any thread created with a NULL attribute list an 8 MiB
 * stack (matching glibc), which is what the CUPS code implicitly assumes.
 * Threads created with an explicit attribute list are left untouched.
 *
 * Build:  cc -O2 -Wall -shared -fPIC -o thread-stackfix.so thread-stackfix.c -ldl
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <dlfcn.h>

#define BIG_STACK (8UL * 1024UL * 1024UL)

int pthread_create(pthread_t *t, const pthread_attr_t *a,
                   void *(*f)(void *), void *arg)
{
  static int (*real)(pthread_t *, const pthread_attr_t *,
                     void *(*)(void *), void *);

  if (!real && !(real = dlsym(RTLD_NEXT, "pthread_create")))
    return 11; /* EAGAIN */

  /* Respect an explicit attribute list. */
  if (a)
    return real(t, a, f, arg);

  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, (size_t)BIG_STACK);

  int r = real(t, &attr, f, arg);
  pthread_attr_destroy(&attr);
  return r;
}
