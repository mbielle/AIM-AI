#ifndef AIM_PROCESS_SUPPORT_H
#define AIM_PROCESS_SUPPORT_H
#include <stddef.h>
#include "AIMManagedLocalEndpoint.h"
typedef struct aim_process_control aim_process_control;
aim_process_control *aim_process_control_create(void);
void aim_process_control_cancel(aim_process_control *control);
void aim_process_control_destroy(aim_process_control *control);
// A process launched with piped stdin accepts bounded writes. A write may be
// partial; the caller must never replay bytes already accepted.
int aim_process_control_write(aim_process_control *control, const void *bytes,
    size_t count, size_t *written);
int aim_process_control_close_input(aim_process_control *control);
// stream 1/2 carries stdout/stderr; stream 0 with null bytes is an idle flush tick.
typedef void (*aim_process_output)(void *context, int stream, const void *bytes, size_t count);
typedef struct {
    int exit_code;
    int error_code;
    int cancelled;
    int timed_out;
} aim_process_result;
// Synchronous worker: caller must not run this on the UI or cooperative executor.
aim_process_result aim_process_run(const char *path, char *const argv[], char *const envp[],
    const char *directory, double timeout_seconds, int pipe_stdin,
    aim_process_control *control,
    aim_process_output output, void *context);

// Interactive PTY sessions are separate from one-shot approved tool commands.
// Output stream 0 means the child and input channel are ready; stream 1 carries
// combined terminal output; stream 2 is an idle flush tick. The caller runs
// aim_terminal_run on a worker thread.
typedef struct aim_terminal_control aim_terminal_control;
aim_terminal_control *aim_terminal_control_create(void);
void aim_terminal_control_cancel(aim_terminal_control *control);
void aim_terminal_control_destroy(aim_terminal_control *control);
int aim_terminal_control_write(aim_terminal_control *control, const void *bytes,
    size_t count, size_t *written);
aim_process_result aim_terminal_run(const char *path, char *const argv[], char *const envp[],
    const char *directory, aim_terminal_control *control,
    aim_process_output output, void *context);
#endif
