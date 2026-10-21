    .text
# Symbol-version compat shims for binaries linked on this dev host
# (glibc 2.41) but run on older targets. glibc 2.38 added new
# symbol-version nodes both for libm's fmod and for the C23 strtol
# family (__isoc23_*), so any binary LINKED here carries a runtime
# requirement for the GLIBC_2.38 nodes and refuses to start on older
# targets - the benchmark-round Atlantic.net hosts (Ubuntu 22.04,
# Rocky 9, glibc <= 2.35) failed every plugin with
# "version `GLIBC_2.38' not found" (round 5230000, issue #164).
#
# Each shim defines the symbol LOCALLY (hidden, not exported) in the
# executable, so every internal call binds here instead of reaching the
# versioned libc symbol, then tail-jumps to the pre-2.38 version node
# via .symver. Hiding them matters: an EXPORTED unversioned name would
# satisfy the shim's own versioned lookup at runtime and recurse into
# itself forever (observed: a 100%-CPU spin on the first modulo
# evaluation when fmod was exported by mistake). Added to every dynamic
# link by build.sh; musl static builds have no symbol versioning and
# skip it. If a future build starts referencing another function that
# grew a 2.38+ node, extend the same pattern here and verify with
# objdump -T that no GLIBC_2.38+ requirement remains.
    .globl fmod
    .hidden fmod
    .type fmod, @function
fmod:
    jmp fmod_pre238
    .size fmod, .-fmod
    .symver fmod_pre238, fmod@GLIBC_2.2.5

# strtol family: the C23 variants differ from the old nodes only in
# accepting binary "0b" prefixes, which our callers never rely on, so
# binding the old node is behaviorally safe for us.
    .globl __isoc23_strtol
    .hidden __isoc23_strtol
    .type __isoc23_strtol, @function
__isoc23_strtol:
    jmp strtol_pre238
    .size __isoc23_strtol, .-__isoc23_strtol
    .symver strtol_pre238, strtol@GLIBC_2.2.5

    .globl __isoc23_strtoul
    .hidden __isoc23_strtoul
    .type __isoc23_strtoul, @function
__isoc23_strtoul:
    jmp strtoul_pre238
    .size __isoc23_strtoul, .-__isoc23_strtoul
    .symver strtoul_pre238, strtoul@GLIBC_2.2.5

    .globl __isoc23_strtoll
    .hidden __isoc23_strtoll
    .type __isoc23_strtoll, @function
__isoc23_strtoll:
    jmp strtoll_pre238
    .size __isoc23_strtoll, .-__isoc23_strtoll
    .symver strtoll_pre238, strtoll@GLIBC_2.2.5

    .globl __isoc23_strtoull
    .hidden __isoc23_strtoull
    .type __isoc23_strtoull, @function
__isoc23_strtoull:
    jmp strtoull_pre238
    .size __isoc23_strtoull, .-__isoc23_strtoull
    .symver strtoull_pre238, strtoull@GLIBC_2.2.5
