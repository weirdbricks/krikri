# #1772 - znerol.wkd_gpg: filter plugin import deprecations missing

- Issue: https://github.com/weirdbricks/krikri/issues/1772
- Role: znerol.wkd_gpg 1.0.0 (with znerol.wkd 1.0.0, whose
  `filter_plugins/wkd.py` is the plugin the task's loop source filters through)
- Class: output (real's PLAY RECAP block carries the one-time "can be
  disabled" hint and the plugin's two `ansible.module_utils._text` import
  deprecations; krikri printed neither)

**What diverged.** The role's first task,
`loop: "{{ wkd_gpg_uids | list }}"`, fails because `wkd_gpg_uids` is set
nowhere, so no filter ever runs. Real ansible still imports every
`filter_plugins/*.py` file of the loaded roles when it COMPILES that template,
and ansible-core 2.21 serves `ansible.module_utils._text` as a shim whose
module-level `__getattr__` deprecates `to_bytes`/`to_text` - the pair
`znerol.wkd`'s `wkd.py` imports at module level. krikri's deferred
filter_plugins scan only fired from a render that got far enough to evaluate
the filter, and this run's strict pre-flight raises the undefined-source error
first, so the plugin was never imported and the block never printed.

**Fix.** The undefined-source probe (`Krikri.undefined_filter_chain_source`)
now runs the filter_plugins scan itself before returning the failing name, so
every strict-raise site (task params, loop sources, `when:`) reports the
plugin imports real would have made.

**Fixture.** `roles/wkd_gpg/` carries the role's failing task verbatim (minus
the two `import_role:` preamble lines, which have no bearing on the
divergence) and `znerol.wkd`'s `wkd.py` verbatim as its own
`filter_plugins/` file, so the plugin import happens in the same role-local
shape as the round's run. The transcript was captured with
`bin/krikri-capture-case` from real ansible-core 2.21.6.

**Note on older controllers.** The corpus replay runs krikri with `HOME`
pointed at the case's scratch tree, which hides the pinned 2.21.6 user
site-packages; the plugin wrapper then imports an older ansible-core whose
`_text` module has no deprecating shim. The wrapper now reports the `_text`
names a plugin really imported in that case and krikri prints the 2.21.6
wording itself (the parity target's text), so the expected block replays on
either controller. That path is also why this case stays in the fast suite
instead of `live/cases.txt`.
