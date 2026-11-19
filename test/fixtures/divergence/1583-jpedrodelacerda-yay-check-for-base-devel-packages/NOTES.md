# jpedrodelacerda.yay: Check for base-devel packages (check mode)

- issue: #1583
- role: jpedrodelacerda.yay (round `logs___1795043292/jpedrodelacerda_yay`)
- phase: check (`--check`, the round's block 4)
- task: `Check for base-devel packages`
- divergence: task results differ: ansible=fatal, krikri=skipping (and krikri
  went on to the next tasks, then exited 4 with `uses unimplemented plugin:
  pacman` instead of ansible's 2)

## What diverged

`jpedrodelacerda.yay` calls `pacman:` on Ubuntu. Ansible resolves it to
`community.general.pacman`, whose `Pacman.__init__` runs
`get_bin_path(executable, required=True)` before any package work -
`supports_check_mode=True`, so `--check` still probes the binary and the task
fails with

    Failed to find required executable "pacman" in paths: ...

krikri had no pacman plugin, so it answered the task with the graceful
unavailable-module skip ("skipping: [testhost]"), ran on into the role's `git:`
task (another divergence), and finished with the engine-limit exit 4.

The fix registers `community.general.pacman` (plus the
`ansible.builtin.pacman` / `ansible.legacy.pacman` runtime redirects) and ports
the module's argument validation and the executable probe; see
`plugins/pacman.cr`. A successful probe still answers a plain ok (the package
inventory/install work is unported and recorded in `KNOWN_MISSING.md`); that
part is not reachable from this case, whose first task fatals.

## Case adaptations

- `roles/jpedrodelacerda.yay/tasks/main.yml` keeps the role's first two tasks
  verbatim but drops their `become: yes` (the round's testhost ran the role as
  root; a localhost capture cannot sudo, and the probe needs no root) and the
  tasks below them (real ansible's fatal ends the play there, so they never
  run, and `git:`/`makepkg` would mutate the machine). `defaults/main.yml` and
  the rest of the role tree are untouched.
- `expected.out` is a real ansible-core 2.21.6 transcript captured with
  `bin/krikri-capture-case` (exit 2).
- The transcript quotes the module's searched `PATH`, so
  `Krikri::DivergenceCase.env` pins the standard system `PATH` for every case
  (the developer shell's PATH carries a random AppImage mount point, which made
  each recording differ).
