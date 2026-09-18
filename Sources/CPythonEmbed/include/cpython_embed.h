#ifndef CPYTHON_EMBED_H
#define CPYTHON_EMBED_H

/// Runs a full CPython init/execute/finalize cycle equivalent to invoking
/// the standalone `python3` binary with the given argv, then returns its
/// exit code. Safe to call repeatedly in the same process — see
/// cpython_embed.c for why.
///
/// `argv[0]` should be the program name ("python"), matching the usual C
/// main() convention; the CPython CLI parser reads its own flags
/// (`-c`, `-m`, a script path, or none for the REPL) out of argv[1...].
///
/// `python_home` is the PYTHONHOME directory: it must contain
/// `lib/python3.13/` with the bundled stdlib (see
/// Docs/NEXT_STEPS.md item 5 for the exact vendored layout).
int termux_run_python(int argc, char *const *argv, const char *python_home);

#endif
