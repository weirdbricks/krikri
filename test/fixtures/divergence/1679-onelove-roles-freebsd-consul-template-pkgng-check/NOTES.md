# onelove-roles.freebsd-consul-template: install packages (check mode)

- issue: #1679
- role: onelove-roles.freebsd-consul-template (round `round29920592`)
- phase: check (`--check`, the round's block 4)
- task: `install packages`
- divergence: task results differ: ansible=failed, krikri=skipping (and krikri
  went on to the role's later tasks and its `restart consul-template` handler,
  then exited 4 with `uses unimplemented plugin: pkgng` instead of ansible's 2)

## What diverged

`onelove-roles.freebsd-consul-template` (a FreeBSD role) calls `pkgng:` with
`name: consul-template` on an Ubuntu host. Ansible resolves the bare name to
`community.general.pkgng` and RUNS it; `main()` calls
`module.get_bin_path("pkg", True)` before any package work -
`supports_check_mode=True`, so `--check` still probes the binary and the task
fails with

    Failed to find required executable "pkg" in paths: ...

ending the play with exit 2.

krikri had no pkgng plugin, so it answered the task with the graceful
unavailable-module skip ("skipping: [testhost]"), ran the role's directory and
template tasks (changed in check mode), hit the handler's own `service:` fatal,
and finished with the engine-limit exit 4.

The fix registers `community.general.pkgng` (plus the
`ansible.builtin.pkgng` / `ansible.legacy.pkgng` runtime redirects) and ports
the module's argument validation and the `pkg` probe; see `plugins/pkgng.cr`.
A successful probe still answers a plain ok (the package
inventory/install/remove work is unported and recorded in `KNOWN_MISSING.md`);
that part is not reachable from this case, whose first task fatals.

## Case adaptations

- `playbook.yml` runs the role at `localhost` with `connection: local` (the
  round's testhost was reached over ssh); the role tree is copied verbatim, so
  the failing task YAML and its `with_items` loop are unchanged.
- `expected.out` is a real ansible-core 2.21.6 transcript captured with
  `bin/krikri-capture-case` (exit 2).
- The transcript quotes the module's searched `PATH`, so
  `Krikri::DivergenceCase.env` pins the standard system `PATH` for every case
  (the developer shell's PATH carries a random AppImage mount point, which made
  each recording differ).
