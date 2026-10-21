#include "AIMProcessSupport.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

struct aim_process_control {
    atomic_int cancelled;
    pthread_mutex_t input_mutex;
    int input_fd;
};
aim_process_control *aim_process_control_create(void) {
    aim_process_control *control = calloc(1, sizeof(*control));
    if (!control) return NULL;
    atomic_init(&control->cancelled, 0);
    control->input_fd = -1;
    if (pthread_mutex_init(&control->input_mutex, NULL) != 0) {
        free(control);
        return NULL;
    }
    return control;
}
void aim_process_control_cancel(aim_process_control *control) { atomic_store(&control->cancelled, 1); }
void aim_process_control_destroy(aim_process_control *control) {
    if (!control) return;
    pthread_mutex_lock(&control->input_mutex);
    if (control->input_fd >= 0) close(control->input_fd);
    control->input_fd = -1;
    pthread_mutex_unlock(&control->input_mutex);
    pthread_mutex_destroy(&control->input_mutex);
    free(control);
}
int aim_process_control_write(aim_process_control *control, const void *bytes,
    size_t count, size_t *written) {
    if (!control || (!bytes && count) || !written) return EINVAL;
    *written = 0;
    int lock_error = pthread_mutex_lock(&control->input_mutex);
    if (lock_error) return lock_error;
    int error = 0;
    if (atomic_load(&control->cancelled)) error = ECANCELED;
    else if (control->input_fd < 0) error = ENOTCONN;
    while (!error && *written < count) {
        if (atomic_load(&control->cancelled)) { error = ECANCELED; break; }
        ssize_t amount = write(control->input_fd, (const char *)bytes + *written, count - *written);
        if (amount > 0) { *written += (size_t)amount; continue; }
        if (amount < 0 && errno == EINTR) continue;
        if (amount < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd descriptor = {control->input_fd, POLLOUT, 0};
            if (poll(&descriptor, 1, 100) > 0) continue;
            error = atomic_load(&control->cancelled) ? ECANCELED : EAGAIN;
        } else error = amount < 0 ? errno : EIO;
    }
    pthread_mutex_unlock(&control->input_mutex);
    return error;
}
int aim_process_control_close_input(aim_process_control *control) {
    if (!control) return EINVAL;
    int lock_error = pthread_mutex_lock(&control->input_mutex);
    if (lock_error) return lock_error;
    int error = control->input_fd < 0 ? ENOTCONN : 0;
    if (!error) { close(control->input_fd); control->input_fd = -1; }
    pthread_mutex_unlock(&control->input_mutex);
    return error;
}
static double now(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}
static void close_fd(int *fd) { if (*fd >= 0) { close(*fd); *fd = -1; } }
static void drain(int *fd, int stream, aim_process_output output, void *context) {
    if (*fd < 0) return;
    char buffer[16384];
    // Bound each drain so continuous output cannot starve timeout/cancellation checks.
    for (int i = 0; i < 16; i++) {
        ssize_t count = read(*fd, buffer, sizeof(buffer));
        if (count > 0) output(context, stream, buffer, (size_t)count);
        else if (count == 0) { close_fd(fd); break; }
        else if (errno == EINTR) continue;
        else { if (errno != EAGAIN && errno != EWOULDBLOCK) close_fd(fd); break; }
    }
}

aim_process_result aim_process_run(const char *path, char *const argv[], char *const envp[],
    const char *directory, double timeout_seconds, int pipe_stdin,
    aim_process_control *control,
    aim_process_output output, void *context) {
    aim_process_result result = {0};
    int out[2] = {-1, -1}, err[2] = {-1, -1}, in[2] = {-1, -1};
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int has_actions = 0, has_attributes = 0;
    pid_t pid = -1;
    if (atomic_load(&control->cancelled)) { result.cancelled = 1; return result; }
    if (pipe(out) || pipe(err) || (pipe_stdin && pipe(in))) { result.error_code = errno; goto cleanup; }
    for (int i = 0; i < 2; i++) {
        if (fcntl(out[i], F_SETFD, FD_CLOEXEC) < 0 || fcntl(err[i], F_SETFD, FD_CLOEXEC) < 0) {
            result.error_code = errno; goto cleanup;
        }
    }
    if (pipe_stdin) {
        for (int i = 0; i < 2; i++) {
            if (fcntl(in[i], F_SETFD, FD_CLOEXEC) < 0) { result.error_code = errno; goto cleanup; }
        }
        // A closed child stdin must return EPIPE to AIM, never terminate AIM.
        if (fcntl(in[1], F_SETNOSIGPIPE, 1) < 0 ||
            fcntl(in[1], F_SETFL, O_NONBLOCK) < 0) {
            result.error_code = errno; goto cleanup;
        }
    }
    if (fcntl(out[0], F_SETFL, O_NONBLOCK) < 0 || fcntl(err[0], F_SETFL, O_NONBLOCK) < 0) {
        result.error_code = errno; goto cleanup;
    }
#define CHECK(call) do { int code = (call); if (code) { result.error_code = code; goto cleanup; } } while (0)
    CHECK(posix_spawn_file_actions_init(&actions)); has_actions = 1;
    CHECK(posix_spawnattr_init(&attributes)); has_attributes = 1;
    if (pipe_stdin) {
        CHECK(posix_spawn_file_actions_adddup2(&actions, in[0], STDIN_FILENO));
        CHECK(posix_spawn_file_actions_addclose(&actions, in[0]));
        CHECK(posix_spawn_file_actions_addclose(&actions, in[1]));
    } else {
        CHECK(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0));
    }
    CHECK(posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO));
    CHECK(posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO));
    CHECK(posix_spawn_file_actions_addclose(&actions, out[0]));
    CHECK(posix_spawn_file_actions_addclose(&actions, err[0]));
    CHECK(posix_spawn_file_actions_addclose(&actions, out[1]));
    CHECK(posix_spawn_file_actions_addclose(&actions, err[1]));
    if (directory) CHECK(posix_spawn_file_actions_addchdir_np(&actions, directory));
    sigset_t empty, defaults;
    sigemptyset(&empty); sigemptyset(&defaults);
    sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGPIPE);
    CHECK(posix_spawnattr_setsigmask(&attributes, &empty));
    CHECK(posix_spawnattr_setsigdefault(&attributes, &defaults));
    CHECK(posix_spawnattr_setpgroup(&attributes, 0));
    CHECK(posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK |
        POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT));
    CHECK(posix_spawn(&pid, path, &actions, &attributes, argv, envp));
    close_fd(&out[1]); close_fd(&err[1]);
    if (pipe_stdin) {
        close_fd(&in[0]);
        pthread_mutex_lock(&control->input_mutex);
        control->input_fd = in[1];
        in[1] = -1;
        pthread_mutex_unlock(&control->input_mutex);
    }
    double start = now(), stopping = 0;
    int exited = 0, killed = 0;
    for (;;) {
        double time = now();
        siginfo_t info = {0};
        // Keep the leader unreaped until group cleanup, preventing PID/group-ID reuse.
        if (!exited) {
            if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) == 0) {
                exited = info.si_pid == pid;
            } else if (errno != EINTR) {
                result.error_code = errno;
                // ECHILD means ownership was lost: never signal a potentially reused PID.
                if (errno != ECHILD) {
                    kill(-pid, SIGKILL);
                    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) { }
                }
                goto cleanup;
            }
        }
        if (!stopping) {
            result.cancelled = atomic_load(&control->cancelled);
            result.timed_out = !exited && timeout_seconds >= 0 && time - start >= timeout_seconds;
            if (exited || result.cancelled || result.timed_out) {
                stopping = time;
                kill(-pid, SIGTERM);
            }
        }
        if (stopping && !killed && time - stopping >= 0.25) {
            kill(-pid, SIGKILL);
            killed = 1;
        }
        drain(&out[0], 1, output, context);
        drain(&err[0], 2, output, context);
        if (output) output(context, 0, NULL, 0);
        // Pipes inherited by detached descendants cannot keep completion blocked forever.
        if (killed && exited && ((out[0] < 0 && err[0] < 0) || time - stopping >= 0.75)) break;
        struct pollfd pipes[2] = {{out[0], POLLIN, 0}, {err[0], POLLIN, 0}};
        poll(pipes, 2, 20);
    }
    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR) continue;
        result.error_code = errno; goto cleanup;
    }
    result.exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
cleanup:
    pthread_mutex_lock(&control->input_mutex);
    if (control->input_fd >= 0) { close(control->input_fd); control->input_fd = -1; }
    pthread_mutex_unlock(&control->input_mutex);
    if (has_actions) posix_spawn_file_actions_destroy(&actions);
    if (has_attributes) posix_spawnattr_destroy(&attributes);
    close_fd(&out[0]); close_fd(&out[1]); close_fd(&err[0]); close_fd(&err[1]);
    close_fd(&in[0]); close_fd(&in[1]);
    return result;
#undef CHECK
}
