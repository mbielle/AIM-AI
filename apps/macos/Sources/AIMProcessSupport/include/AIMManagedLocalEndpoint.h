#ifndef AIM_MANAGED_LOCAL_ENDPOINT_H
#define AIM_MANAGED_LOCAL_ENDPOINT_H
#include <stdint.h>
// Fail closed unless this PID owns the exact IPv4 loopback TCP listener.
int aim_process_owns_loopback_listener(int32_t pid, uint16_t port);
#endif
