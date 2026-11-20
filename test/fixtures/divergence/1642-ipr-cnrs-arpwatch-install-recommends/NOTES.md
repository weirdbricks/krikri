# #1642 - ipr-cnrs.arpwatch: `install_recommends` accepted on a dnf host

- Issue: https://github.com/weirdbricks/krikri/issues/1642
- Role: `ipr-cnrs.arpwatch` (rocky, round round29919595)
- Class: output gap (module argument validation)

**What diverged.** The role's
`package: {name: '{{ arpwatch__base_packages | flatten }}', state: present, install_recommends: False}`
task failed on both engines, but not for the same reason: real ansible
rejected the option itself
(`Unsupported parameters for (ansible.legacy.dnf) module: install_recommends ...`)
while krikri ignored it and reported dnf's own
`Failed to install some of the specified packages` / `No package arpwatch available.`
because the host (rocky) has no arpwatch without EPEL.

**Why.** `ansible.builtin.package` is a fact-delegating module: real's
action plugin resolves the backend from `use:` or the `ansible_pkg_mgr`
fact and hands the task args to that module, so the backend's argument spec
rejects anything the backend does not declare. krikri's validator had two
gaps:

- its `ansible_pkg_mgr` map only knew `apt`, so a `pkg_mgr=dnf` host fell
  through to "no spec, no validation";
- it stripped `use:` from the params BEFORE resolving the backend, so an
  explicit `package: {use: dnf, ...}` was validated against the host fact
  (or, with no facts, against the controller's `/usr/bin/apt-get` probe)
  instead of dnf.

`ansible.builtin.dnf` keeps `no_validate` in the table because krikri's dnf
plugin owns the direct-task wording (the printed module name depends on the
action plugin's backend resolution); its captured spec is only consulted
through the package delegation.

**Fixture.** The role's task from `tasks/main.yml`, verbatim except for
`use: dnf` (the round ran on rocky, where the fact resolves to dnf; no local
run has that fact) plus the role's two defaults as play vars. The task's
`until: pkg_result is success` is kept, so the three retry lines are part of
the recorded transcript.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6 (live-verified: `package: {use: dnf, ...}` prints the
identical message on a Debian host).
