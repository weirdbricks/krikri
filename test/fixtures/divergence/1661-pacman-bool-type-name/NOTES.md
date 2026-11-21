# #1661 - bool argument conversion reported the pre-2.21 class repr

- Issue: https://github.com/weirdbricks/krikri/issues/1661
- Class: output (the task fails identically on both engines; only the
  "is of type ..." slot of parameters.py's type error differs)

**What diverged.** ansible-core 2.21.6 builds that sentence from
`native_type_name(value)`, i.e. the Python class's `__name__`
(`is of type str`), where earlier releases interpolated the class
itself (`is of type <class 'str'>`). krikri's shared argument-validation
helper still carried the old repr, so every hand-rolled plugin that
routes an unconvertible bool through it printed the stale wording. The
issue's `Pacman #20.0` task (`remove_nosave: wwxxse`) is one of them.

The issue also named a Jinja divergence on `Pam_limits #20.1`
(`use_min: '{{ true }}'`); that case no longer diverges - both engines
agree on `Cannot use use_min and use_max at the same time.`

**Fixture.** The issue's Pacman task verbatim, on `--check`
(`flags.txt`), with `delegate_to` dropped so the task runs on the local
host. The failure happens in argument-spec validation, ahead of the
module's own `pacman` binary probe, so a host without pacman (both
reference Debian containers) fails the same way real does.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6 + community.general 12.5.0. The
`Valid booleans include:` tail is printed through the corpus
transcript's `<BOOLEAN-SET-ORDER>` mask, since that list's order is
randomized per module process on real's side; the "is of type" slot
this case pins is outside the mask.
