    .text
# glibc 2.38 introduced a new default symbol-version node for libm's
# fmod, so any binary LINKED on a glibc >= 2.38 host (this dev machine
# runs Debian 13's glibc 2.41) carries a runtime requirement for
# fmod@GLIBC_2.38 and refuses to start on older targets - the
# benchmark-round Atlantic.net hosts (Ubuntu 22.04, glibc 2.35) failed
# every plugin with "version `GLIBC_2.38' not found" (round 5230000).
# The reference comes from krikri-jinja's Python-parity float `%` and
# floor-divide (PyLibM.fmod). Binding the OLD version node is also the
# parity choice: Python on those targets runs pre-2.38 fmod.
#
# This shim defines fmod LOCALLY (hidden, not exported) in the
# executable, so every internal call binds here instead of reaching
# libc's versioned symbol, then tail-jumps to the GLIBC_2.2.5 node via
# .symver. Hiding it matters: an EXPORTED unversioned fmod would
# satisfy the shim's own versioned lookup at runtime and recurse into
# itself forever (observed: a 100%-CPU spin on the first modulo
# evaluation). Added to every dynamic link by build.sh; musl static
# builds have no symbol versioning and skip it. Only fmod needs this
# today - if a future engine change starts referencing another libm
# function that grew a 2.38 node, extend the same pattern here.
    .globl fmod
    .hidden fmod
    .type fmod, @function
fmod:
    jmp fmod_pre238
    .size fmod, .-fmod
    .symver fmod_pre238, fmod@GLIBC_2.2.5
