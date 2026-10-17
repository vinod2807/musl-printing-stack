/*
 * shimcheck - measure how much stack a thread created with a NULL attribute
 *             list actually has.
 *
 * It walks down from the current stack pointer, page by page, until madvise()
 * hits an unmapped page (the guard page / end of the mapping) and reports how
 * much room is left.  Run it with and without the shim:
 *
 *   cc -O0 -o shimcheck shimcheck.c -lpthread
 *   ./shimcheck
 *   LD_PRELOAD=/usr/local/lib/cups-thread-stackfix.so ./shimcheck
 *
 * Observed on Alpine musl 1.2.6 / x86_64:
 *   usable stack WITHOUT shim: 140 KiB
 *   usable stack WITH shim:    8204 KiB
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <sys/mman.h>

static void *fn(void *x)
{
  (void)x;

  unsigned long p = (unsigned long)&p & ~4095UL; /* page-align */
  unsigned long n = 0;

  while (n < (64UL << 20))
  {
    if (madvise((void *)(p - n), 4096, MADV_NORMAL) != 0)
      break;
    n += 4096;
  }

  printf("%lu\n", n / 1024); /* KiB */
  return 0;
}

int main(void)
{
  pthread_t t;
  pthread_create(&t, 0, fn, 0);
  pthread_join(t, 0);
  return 0;
}
