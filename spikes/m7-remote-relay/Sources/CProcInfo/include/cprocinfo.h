#include <stdint.h>
/// phys_footprint of a process in bytes, or 0 when it cannot be read.
uint64_t cproc_footprint(int pid);
