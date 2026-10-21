#include "AIMProcessSupport.h"
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

struct aim_terminal_control {
    atomic_int cancelled;
    pthread_mutex_t mutex;
    int master;
};

aim_terminal_control *aim_terminal_control_create(void) {
    aim_terminal_control *control = calloc(1, sizeof(*control));
    if (!control) return NULL;
    atomic_init(&control->cancelled, 0);
    control->master = -1;
    if (pthread_mutex_init(&control->mutex, NULL) != 0) {
        free(control);
        return NULL;
    }
    return control;
}

void aim_terminal_control_cancel(aim_terminal_control *control) {
    if (control) atomic_store(&control->cancelled, 1);
}

void aim_terminal_control_destroy(aim_terminal_control *control) {
    if (!control) return;
    pthread_mutex_destroy(&control->mutex);
    free(control);
}

int aim_terminal_control_write(aim_terminal_control *control, const void *bytes,
    size_t count, size_t *written) {
    if (!control || (!bytes && count) || !written) return EINVAL;
    *written = 0;
    int lock_error = pthread_mutex_lock(&control->mutex);
    if (lock_error) return lock_error;
    int error = 0;
    if (atomic_load(&control->cancelled)) error = ECANCELED;
    else if (control->master < 0) error = ENOTCONN;
    while (!error && *written < count) {
        ssize_t amount = write(control->master, (const char *)bytes + *written, count - *written);
        if (amount > 0) { *written += (size_t)amount; continue; }
        if (amount < 0 && errno == EINTR) continue;
        if (amount < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd descriptor = {control->master, POLLOUT, 0};
            if (poll(&descriptor, 1, 100) > 0) continue;
            error = atomic_load(&control->cancelled) ? ECANCELED : EAGAIN;
        } else error = amount < 0 ? errno : EIO;
    }
    pthread_mutex_unlock(&control->mutex);
    return error;
}

static void terminal_close(int *descriptor) {
    if (*descriptor >= 0) { close(*descriptor); *descriptor = -1; }
}

static double terminal_now(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}

// Interactive shells may place jobs in a different process group even when
// job control is disabled. The session leader remains unreaped while this runs,
// so its SID cannot be reused for an unrelated process.
static void signal_terminal_session(pid_t session_leader, int signal_number) {
    int capacity = proc_listallpids(NULL, 0);
    if (capacity > 0 && capacity < 100000) {
        pid_t *pids = calloc((size_t)capacity + 64, sizeof(pid_t));
        if (pids) {
            int count = proc_listallpids(pids, (capacity + 64) * (int)sizeof(pid_t));
            if (count > capacity + 64) count = capacity + 64;
            for (int index = 0; index < count; index++) {
                pid_t candidate = pids[index];
                if (candidate > 0 && candidate != session_leader && getsid(candidate) == session_leader) {
                    kill(candidate, signal_number);
                }
            }
            free(pids);
        }
    }
    kill(-session_leader, signal_number);
}

aim_process_result aim_terminal_run(const char *path, char *const argv[], char *const envp[],
    const char *directory, aim_terminal_control *control,
    aim_process_output output, void *context) {
    aim_process_result result = {0};
    int master = -1, slave = -1, has_actions = 0, has_attributes = 0, reaped = 0;
    pid_t pid = -1;
    char slave_name[128] = {0};
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    struct winsize size = {.ws_row = 30, .ws_col = 100};
    if (!path || !argv || !envp || !control) { result.error_code = EINVAL; return result; }
    if (atomic_load(&control->cancelled)) { result.cancelled = 1; return result; }
    if (openpty(&master, &slave, slave_name, NULL, &size) != 0) {
        result.error_code = errno; goto cleanup;
    }
    if (fcntl(master, F_SETFL, O_NONBLOCK) < 0 || fcntl(master, F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(slave, F_SETFD, FD_CLOEXEC) < 0) {
        result.error_code = errno; goto cleanup;
    }
#define TERMINAL_CHECK(call) do { int code = (call); if (code) { result.error_code = code; goto cleanup; } } while (0)
    TERMINAL_CHECK(posix_spawn_file_actions_init(&actions)); has_actions = 1;
    TERMINAL_CHECK(posix_spawnattr_init(&attributes)); has_attributes = 1;
    // The slave is opened after the child becomes a session leader so it can
    // acquire the controlling terminal without fork() in the multithreaded app.
    TERMINAL_CHECK(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slave_name, O_RDWR, 0));
    TERMINAL_CHECK(posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO));
    TERMINAL_CHECK(posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO));
    if (directory) TERMINAL_CHECK(posix_spawn_file_actions_addchdir_np(&actions, directory));
    sigset_t empty, defaults;
    sigemptyset(&empty); sigemptyset(&defaults);
    sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGPIPE);
    TERMINAL_CHECK(posix_spawnattr_setsigmask(&attributes, &empty));
    TERMINAL_CHECK(posix_spawnattr_setsigdefault(&attributes, &defaults));
    TERMINAL_CHECK(posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID |
        POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT));
    TERMINAL_CHECK(posix_spawn(&pid, path, &actions, &attributes, argv, envp));
    terminal_close(&slave);
    pthread_mutex_lock(&control->mutex);
    control->master = master;
    pthread_mutex_unlock(&control->mutex);
    if (output) output(context, 0, NULL, 0);

    int exited = 0, killed = 0;
    double stopping = 0;
    for (;;) {
        siginfo_t info = {0};
        if (!exited) {
            if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) == 0) {
                exited = info.si_pid == pid;
            } else if (errno != EINTR) {
                result.error_code = errno;
                // ECHILD means PID ownership was lost; do not signal a reused ID.
                if (errno != ECHILD) signal_terminal_session(pid, SIGKILL);
                goto cleanup;
            }
        }
        if (!stopping && (exited || atomic_load(&control->cancelled))) {
            result.cancelled = atomic_load(&control->cancelled);
            stopping = terminal_now();
            signal_terminal_session(pid, SIGTERM);
        }
        if (stopping && !killed && terminal_now() - stopping >= 0.25) {
            signal_terminal_session(pid, SIGKILL);
            killed = 1;
        }
        char buffer[16384];
        for (int i = 0; i < 16; i++) {
            ssize_t amount = read(master, buffer, sizeof(buffer));
            if (amount > 0 && output) output(context, 1, buffer, (size_t)amount);
            else if (amount == 0 || (amount < 0 && errno == EIO)) break;
            else if (amount < 0 && errno == EINTR) continue;
            else if (amount < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
            else if (amount < 0) { result.error_code = errno; goto cleanup; }
        }
        if (output) output(context, 2, NULL, 0);
        if (killed && exited) break;
        struct pollfd descriptor = {master, POLLIN, 0};
        poll(&descriptor, 1, 20);
    }
    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR) continue;
        result.error_code = errno; goto cleanup;
    }
    reaped = 1;
    result.exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
cleanup:
    if (pid > 0 && !reaped) {
        if (result.error_code != ECHILD) signal_terminal_session(pid, SIGKILL);
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) { }
    }
    pthread_mutex_lock(&control->mutex);
    control->master = -1;
    pthread_mutex_unlock(&control->mutex);
    if (has_actions) posix_spawn_file_actions_destroy(&actions);
    if (has_attributes) posix_spawnattr_destroy(&attributes);
    terminal_close(&master);
    terminal_close(&slave);
    return result;
#undef TERMINAL_CHECK
}
