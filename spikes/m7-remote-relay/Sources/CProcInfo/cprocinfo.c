#include "cprocinfo.h"
#include <libproc.h>
#include <sys/resource.h>
uint64_t cproc_footprint(int pid) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return 0;
    return ri.ri_phys_footprint;
}
