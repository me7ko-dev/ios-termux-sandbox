#include "include/cpython_embed.h"

#include <stdio.h>

// Framework-style include, resolved against the vendored Python.xcframework's
// Headers/ dir. Several CPython headers this needs (cpython/initconfig.h,
// which declares PyConfig/PyStatus/Py_InitializeFromConfig) are marked
// `exclude header` in Python.framework's own module.modulemap — that only
// walls them off from Clang's *module* view (relevant to a Swift `import
// Python`), not from a plain C `#include`, which is why this lives in its
// own C target rather than being called directly from Swift.
#include <Python/Python.h>

int termux_run_python(int argc, char *const *argv, const char *python_home) {
    PyStatus status;

    PyPreConfig preconfig;
    PyPreConfig_InitPythonConfig(&preconfig);
    preconfig.utf8_mode = 1;

    status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        fprintf(stderr, "python: %s\n", status.err_msg ? status.err_msg : "pre-initialization failed");
        return 1;
    }

    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    // Output already goes through ios_system's redirected C stdio, and this
    // process outlives any single command — don't let a stray buffered
    // write from a half-finished script show up under the next command.
    config.buffered_stdio = 0;
    // The app bundle is code-signed as a unit; writing .pyc next to a
    // script would just fail silently or, worse, not be picked up anyway.
    config.write_bytecode = 0;
    // No real pty/signal delivery model exists yet (Docs/NEXT_STEPS.md item
    // 2) — leave signal handling to the host app rather than have Python
    // install its own SIGINT/SIGTERM handlers.
    config.install_signal_handlers = 0;

    wchar_t *home = Py_DecodeLocale(python_home, NULL);
    if (home == NULL) {
        fprintf(stderr, "python: couldn't decode PYTHONHOME path\n");
        PyConfig_Clear(&config);
        return 1;
    }
    status = PyConfig_SetString(&config, &config.home, home);
    PyMem_RawFree(home);
    if (PyStatus_Exception(status)) {
        fprintf(stderr, "python: couldn't set PYTHONHOME: %s\n", status.err_msg ? status.err_msg : "unknown error");
        PyConfig_Clear(&config);
        return 1;
    }

    status = PyConfig_SetBytesArgv(&config, argc, argv);
    if (PyStatus_Exception(status)) {
        fprintf(stderr, "python: couldn't set argv: %s\n", status.err_msg ? status.err_msg : "unknown error");
        PyConfig_Clear(&config);
        return 1;
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        fprintf(stderr, "python: %s\n", status.err_msg ? status.err_msg : "initialization failed");
        return 1;
    }

    // Py_RunMain() runs whatever argv asked for (a script, `-m module`,
    // `-c command`, or the interactive REPL with no args) and — per
    // CPython's own Modules/main.c, where it's pymain_run_python() followed
    // unconditionally by Py_FinalizeEx() — finalizes the interpreter itself
    // before returning. That makes this whole function a self-contained,
    // repeatable init/run/finalize cycle: calling termux_run_python() again
    // for the next `python` invocation in the same shell session starts
    // clean, the same way launching the real python3 binary twice would.
    // Not independently re-verified against this exact vendored build on a
    // real device — flagged in Docs/NEXT_STEPS.md item 5 as the one thing
    // to confirm before trusting a second invocation matters.
    return Py_RunMain();
}
