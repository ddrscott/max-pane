// libproc is not surfaced by Swift's Darwin module; this header is passed with
// -import-objc-header so main.swift can call proc_pid_rusage / proc_listpids.
#include <libproc.h>
#include <sys/resource.h>
#include <sys/proc_info.h>
