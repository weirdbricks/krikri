# #1782 - znerol.wkd_gpg: filter plugin import deprecations missing in --check

- Issue: https://github.com/weirdbricks/krikri/issues/1782
- Role: znerol.wkd_gpg 1.0.0 (with znerol.wkd 1.0.0, whose
  `filter_plugins/wkd.py` is the plugin the task's loop source filters through)
- Class: check-mode output (real's PLAY RECAP block carries the one-time
  "can be disabled" hint and the plugin's two `ansible.module_utils._text`
  import deprecations; krikri printed neither)

**What diverged.** The role's first task,
`loop: "{{ wkd_gpg_uids | list }}"`, fails because `wkd_gpg_uids` is set
nowhere, so no filter ever runs. Real ansible still imports every
`filter_plugins/*.py` file of the loaded roles when it COMPILES that template -
in `--check` exactly as in a real run - and ansible-core 2.21 serves
`ansible.module_utils._text` as a shim whose module-level `__getattr__`
deprecates `to_bytes`/`to_text`, the pair `znerol.wkd`'s `wkd.py` imports at
module level. krikri's deferred filter_plugins scan at the time only fired from
a render that got far enough to evaluate the filter, so the block was lost.

**Fix.** This is the check-phase twin of #1772, found in the same round; the
undefined-source probe (`Krikri.undefined_filter_chain_source`) now runs the
filter_plugins scan before raising the failing name, and check mode evaluates
the same expression through the same strict pre-flight. This case pins the
`--check` transcript so the two phases cannot drift apart again.

**Fixture.** `roles/wkd_gpg/` carries the role's failing task verbatim (minus
the two `import_role:` preamble lines, which have no bearing on the
divergence) and `znerol.wkd`'s `wkd.py` verbatim as its own `filter_plugins/`
file, so the plugin import happens in the same role-local shape as the round's
run. `flags.txt` adds the round's `--check`. The transcript was captured with
`bin/krikri-capture-case` from real ansible-core 2.21.6.
