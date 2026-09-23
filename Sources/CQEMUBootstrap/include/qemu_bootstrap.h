#ifndef QEMU_BOOTSTRAP_H
#define QEMU_BOOTSTRAP_H

#include <stdbool.h>
#include <stddef.h>

/// Called exactly once, on the QEMU thread, when the VM is gone: either
/// qemu_main_loop() returned (guest powered off) or QEMU called exit()
/// (bad argument, fatal error). `fatal` is true for the latter.
typedef void (*lvm_exit_callback)(int status, bool fatal, void *context);

/// dlopen()s a QEMU system emulator framework binary and runs it on its own
/// pthread, in-process — iOS gives third-party apps no fork/exec, so this
/// is the only way to run QEMU at all. Same approach (and the same
/// qemu_init / qemu_main_loop / qemu_cleanup entry points) as UTM's
/// Services/UTMProcess.m + UTMQemuSystem.m, which ship these frameworks.
///
/// argv/envp are copied; the caller may free them after this returns.
/// Returns 0 on success, or -1 with a message in `error`.
///
/// QEMU keeps process-global state and cannot be initialised twice in one
/// process: after the exit callback fires, the app must be relaunched
/// before another lvm_qemu_start().
int lvm_qemu_start(const char *dylib_path,
                   int argc, const char *const *argv,
                   const char *const *envp,
                   lvm_exit_callback on_exit, void *context,
                   char *error, size_t error_len);

/// True when the process may map writable+executable memory, i.e. QEMU's
/// TCG JIT can work. On stock iOS that is only the case while a debugger
/// is (or was) attached to a development-signed app — which is what
/// SideStore/AltStore + StikDebug (or Xcode) arrange. Checks the kernel's
/// CS_DEBUGGED code-signing flag via csops(), like UTM's UTMJailbreak.m.
bool lvm_jit_available(void);

/// Bytes this process may still allocate before jetsam kills it
/// (os_proc_available_memory). 0 when unknown.
size_t lvm_available_memory(void);

#endif
