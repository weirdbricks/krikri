# #1562 - ansibl3.ubuntu_sunjava: conflicting action statements

- Issue: https://github.com/weirdbricks/krikri/issues/1562
- Role: `ansibl3.ubuntu_sunjava` (ubuntu host, round `logs___1795043292`)
- Class: output gap (error text, load-time)

**What diverged.** The role writes its tasks in the legacy
`action: apt_repository repo=...` form together with `sudo: yes`, a keyword
ansible-core removed. Real rejects the task while loading the role -
`conflicting action statements: apt_repository, sudo` - and exits 4 before any
task runs; krikri reported `unexpected parameter type in action: <class
'bool'>` instead.

**Fixture.** The role's `tasks/main.yml` verbatim. The play fails while loading
the role, so none of its shell/apt tasks can execute.
