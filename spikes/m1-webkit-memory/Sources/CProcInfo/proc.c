#include "include/CProcInfo.h"
#include <libproc.h>
#include <string.h>
#include <sys/proc_info.h>

int mp_mem(pid_t pid, uint64_t *phys_footprint, uint64_t *resident) {
    rusage_info_current ri;
    memset(&ri, 0, sizeof(ri));
    int rc = proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, (rusage_info_t *)&ri);
    if (rc != 0) return rc;
    if (phys_footprint) *phys_footprint = ri.ri_phys_footprint;
    if (resident) *resident = ri.ri_resident_size;
    return 0;
}

int mp_cpu_ns(pid_t pid, uint64_t *user_ns, uint64_t *system_ns) {
    rusage_info_current ri;
    memset(&ri, 0, sizeof(ri));
    int rc = proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, (rusage_info_t *)&ri);
    if (rc != 0) return rc;
    if (user_ns) *user_ns = ri.ri_user_time;
    if (system_ns) *system_ns = ri.ri_system_time;
    return 0;
}

int mp_list_pids(pid_t *buf, int cap) {
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, buf, (int)(cap * sizeof(pid_t)));
    if (bytes <= 0) return -1;
    return bytes / (int)sizeof(pid_t);
}

int mp_pid_path(pid_t pid, char *buf, int cap) {
    return proc_pidpath(pid, buf, (uint32_t)cap);
}
