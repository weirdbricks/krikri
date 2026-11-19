# #1610 - juju4.vivisect: check-mode pip task crashes when executable: is set

- Issue: https://github.com/weirdbricks/krikri/issues/1610
- Role: `juju4.vivisect` (round `round29918149`, check phase)
- Class: check-mode behavioural bug (task result, exit code)

**What diverged.** The role's `Install vivisect with pip` task installs a
GitHub zipball requirement with `executable: "{{ vivisect_pip }}"` (default
`pip3`). In check mode pip.py resolves such a non-requirement name through
`_resolve_package_names`, which reads the pip version from
`_get_package_info(module, "pip", py_bin)` - and `py_bin` is
`module.params['executable'] or sys.executable`. A pip executable cannot run
`-c` python code, so the helper returns None and pip.py dereferences it
(`pip_dep.split('==')`): the task fails with
`'NoneType' object has no attribute 'split'` after its two retries. krikri read
the pip version with `pip show pip`, resolved the URL, and reported the task
`changed`, so the rest of the play ran and the exit code was 0 instead of 2.

**Fixture.** The role's pip task and the two defaults it renders, verbatim
(tasks/main.yml, defaults/main.yml); the surrounding block's package tasks,
`import_tasks:` and the virtualenv block are dropped - they only touch host
state, so keeping them would make the recording depend on the runner's
installed packages. `--check` as the round ran it (`flags.txt`), so the case
cannot install anything.
