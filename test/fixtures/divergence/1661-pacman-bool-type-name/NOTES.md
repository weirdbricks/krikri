# #1661 - bool conversion errors named the class repr and listed the wrong booleans

- Issue: https://github.com/weirdbricks/krikri/issues/1661
- Class: output (both engines fail the same task; the parameters.py sentence
  differs)

**What diverged.** Two things in ansible-core's bool conversion failure, both
fixed here:

- ansible-core 2.21.6 builds the "is of type ..." slot from
  `native_type_name(value)`, the Python class's `__name__`, so it says
  `is of type str`. The `"<class 'str'>"` repr belongs to an earlier core.
- The "Valid booleans include:" tail is repr'd from convert_bool's
  `BOOLEANS` frozenset. A frozenset collapses equal members, so `1`, `1.0`
  and `True` print once (as `1`) and `0`, `0.0` and `False` once (as `0`):
  14 entries, every string member single-quoted. krikri printed the 18
  literal members, four of them unquoted.

The issue's `Pacman #20.0` task (`remove_nosave: wwxxse`) surfaces both. (The
kpg report masked the whole tail as run-to-run noise, which is why the second
difference reached no issue at first.) The issue also named a Jinja
divergence on `Pam_limits #20.1` (`use_min: '{{ true }}'`); that one no longer
diverges - both engines agree on `Cannot use use_min and use_max at the same
time.`

**Fixture.** The issue's Pacman task verbatim, on `--check`, with
`delegate_to` dropped so the task runs on the local host. Validation fails
before the module's own `pacman` binary probe, so a host without pacman
fails the same way real does.

`expected.out` was captured with `bin/krikri-capture-case` from ansible-core
2.21.6 (the corpus's pinned parity target) and the community.general the
corpus environment resolves (the system-wide collection, since a case runs
with `HOME` pointed at its scratch tree). The enumeration's ORDER is
normalized by sorting its members in `Krikri::DivergenceTranscript` - real
builds it from a frozenset and its order changes per module process - while
membership and quoting stay exact, so this case now catches both halves of
the divergence.
