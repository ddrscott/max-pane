#ifndef CPROCINFO_H
#define CPROCINFO_H
#include <sys/types.h>
#include <stdint.h>

/* Returns 0 on success. phys_footprint is the same quantity Activity Monitor
   shows as "Memory"; resident is classic RSS. */
int mp_mem(pid_t pid, uint64_t *phys_footprint, uint64_t *resident);

/* Cumulative CPU time in nanoseconds since process start. 0 on success. */
int mp_cpu_ns(pid_t pid, uint64_t *user_ns, uint64_t *system_ns);

/* Fills buf with up to cap pids; returns the count, or -1. */
int mp_list_pids(pid_t *buf, int cap);

/* Fills buf with the executable path. Returns length, or <=0 on failure. */
int mp_pid_path(pid_t pid, char *buf, int cap);

#endif
