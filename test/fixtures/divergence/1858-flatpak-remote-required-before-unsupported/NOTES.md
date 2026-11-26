# 1858 - flatpak_remote reports the typo'd parameter instead of the missing name

Issue: https://github.com/weirdbricks/krikri/issues/1858
kpg playbook `000028-multi-flatpak_remote-chaos` (krikri 0.9.3151), check mode.

## What diverged

The task mistypes `name` as `nmae`, so the module's argument spec is invalid in
two ways at once: the required `name` is absent and `nmae` is not a spec
parameter. Real ansible fails with

    missing required arguments: name

while krikri reported the unsupported-parameter error:

    Unsupported parameters for (community.general.flatpak_remote) module: nmae. Supported parameters include: ...

ansible-core 2.21.6's `ModuleArgumentSpecValidator.validate` appends the
`UnsupportedError` after the required/types/choices checks and `basic.py` fails
with `errors[0]` only, so the missing-name error always outranks a typo'd
parameter. (Older cores ran the unsupported check first; the plugin's comment
still claimed that order.)

## Fix

`plugins/flatpak_remote.cr` (and `flatpak.cr`, which shares the ordering)
validate required -> bool types -> choices, and run the unsupported-parameter
check last.

## Notes

The play is the kpg play's flatpak_remote task copied verbatim, with `target`
and the `target2` delegate both local; `--check` (flags.txt) is the kpg round's
mode. Only the first task is replayed: the rest of that play is unrelated
(its `flatpak` task is skipped because this one fails).
