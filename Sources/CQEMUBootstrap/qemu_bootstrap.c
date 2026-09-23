#include "qemu_bootstrap.h"

#include <dlfcn.h>
#include <os/proc.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef int (*qemu_init_fn)(int, const char **, const char **);
typedef void (*qemu_main_loop_fn)(void);
typedef void (*qemu_cleanup_fn)(void);

typedef struct {
    void *handle;
    qemu_init_fn qemu_init;
    qemu_main_loop_fn qemu_main_loop;
    qemu_cleanup_fn qemu_cleanup;
    int argc;
    char **argv;
    char **envp;
    lvm_exit_callback on_exit;
    void *context;
} lvm_launch;

static pthread_t qemu_thread;
static lvm_launch *active_launch;
static int started;

static char **copy_strings(const char *const *strings, int count) {
    char **copy = calloc((size_t)count + 1, sizeof(char *));
    for (int i = 0; i < count; i++) {
        copy[i] = strdup(strings[i]);
    }
    return copy;
}

static int count_strings(const char *const *strings) {
    int n = 0;
    while (strings && strings[n]) {
        n++;
    }
    return n;
}

/// QEMU reports fatal errors (and `-no-shutdown`-less quits in some paths)
/// by calling exit(). In-process that would kill the whole app, so — like
/// UTM — catch it with an atexit handler and, if it is the QEMU thread that
/// is exiting, report and end only that thread.
static void handle_exit(void) {
    if (active_launch && pthread_equal(pthread_self(), qemu_thread)) {
        lvm_launch *launch = active_launch;
        active_launch = NULL;
        launch->on_exit(-1, true, launch->context);
        pthread_exit(NULL);
    }
}

static void *qemu_thread_main(void *arg) {
    lvm_launch *launch = arg;
    for (int i = 0; launch->envp[i]; i++) {
        putenv(launch->envp[i]);
    }
    int status = launch->qemu_init(launch->argc, (const char **)launch->argv, (const char **)launch->envp);
    if (status == 0) {
        launch->qemu_main_loop();
        launch->qemu_cleanup();
    }
    active_launch = NULL;
    launch->on_exit(status, false, launch->context);
    return NULL;
}

int lvm_qemu_start(const char *dylib_path,
                   int argc, const char *const *argv,
                   const char *const *envp,
                   lvm_exit_callback on_exit, void *context,
                   char *error, size_t error_len) {
    if (started) {
        snprintf(error, error_len, "QEMU was already started in this process; relaunch the app to boot again.");
        return -1;
    }
    void *handle = dlopen(dylib_path, RTLD_LOCAL | RTLD_NOW);
    if (!handle) {
        snprintf(error, error_len, "dlopen failed: %s", dlerror());
        return -1;
    }
    lvm_launch *launch = calloc(1, sizeof(lvm_launch));
    launch->handle = handle;
    launch->qemu_init = (qemu_init_fn)dlsym(handle, "qemu_init");
    launch->qemu_main_loop = (qemu_main_loop_fn)dlsym(handle, "qemu_main_loop");
    launch->qemu_cleanup = (qemu_cleanup_fn)dlsym(handle, "qemu_cleanup");
    if (!launch->qemu_init || !launch->qemu_main_loop || !launch->qemu_cleanup) {
        snprintf(error, error_len, "%s does not export qemu_init/qemu_main_loop/qemu_cleanup", dylib_path);
        free(launch);
        dlclose(handle);
        return -1;
    }
    launch->argc = argc;
    launch->argv = copy_strings(argv, argc);
    launch->envp = copy_strings(envp, count_strings(envp));
    launch->on_exit = on_exit;
    launch->context = context;

    static int registered;
    if (!registered) {
        atexit(handle_exit);
        registered = 1;
    }

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    // QEMU's coroutines and TCG are stack-hungry; the 512 KiB default for
    // secondary threads on iOS is not enough.
    pthread_attr_setstacksize(&attr, 8 * 1024 * 1024);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    active_launch = launch;
    started = 1;
    int rc = pthread_create(&qemu_thread, &attr, qemu_thread_main, launch);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        active_launch = NULL;
        snprintf(error, error_len, "pthread_create failed: %d", rc);
        return -1;
    }
    return 0;
}

#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

bool lvm_jit_available(void) {
    int flags = 0;
    return csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) == 0 && (flags & CS_DEBUGGED) != 0;
}

size_t lvm_available_memory(void) {
    return os_proc_available_memory();
}
