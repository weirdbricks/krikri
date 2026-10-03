# Key-order probe roles

Probe roles for the `krikri-role-tester keyorder` subcommand (being added to
`../krikri-role-tester`): they run against a real Atlantic.net Ubuntu 22.04
VM with both real `ansible-core` (2.19.11) and krikri-playbook, and capture
**the order of top-level keys in each module's registered result**. Real
Ansible does not guarantee result dict key order, but whatever order each
engine emits is a real observable difference, and this is what the
`keyorder` comparer diffs.

## The convention (the comparer depends on it exactly)

Every probed case is a task pair:

```yaml
- name: <human description>
  <module>:
    ...
  register: r
  ignore_errors: true        # so a failure shape is captured without aborting

- name: Report <module>_<case>
  ansible.builtin.debug:
    msg: "KEYORDER|<module>_<case>|{{ r | to_json }}"
```

- Probe name is always `<module>_<case>`, e.g. `user_create`, `user_exists`,
  `user_remove`. Helper (non-probed) tasks that are registered anyway emit
  `KEYORDER|<module>_helper_*|...` lines so round logs stay explainable;
  the comparer can ignore them.
- `ignore_errors: true` is set on **every** probed task (not just expected
  failures) so one broken case never aborts the remaining probes; for
  success cases it changes nothing about the registered result.
- Every probed task is immediately followed by the matching debug line.
- Every case is self-contained (create -> probe -> probe again -> remove)
  with `kop_`-prefixed unique names, so the role is safe to run twice in a
  row (the tester runs cold then warm on each engine).
- Storage probes run inside a `block:` with an `always:` teardown, so a
  mid-role failure still cleans up loop devices, VGs, pools and mounts.

Per module we probe at least: a changing run, an already-in-state
(idempotent) run, and where cheap a check-mode run (`check_mode: true`) and
a failure run.

## Roles and the module -> role map

All run as root on a fresh Ubuntu 22.04 Atlantic.net VM.

| Role | Modules probed | Notes |
|---|---|---|
| `kop_accounts` | `ansible.builtin.user`, `ansible.builtin.group`, `ansible.posix.authorized_key`, `ansible.builtin.known_hosts` | embedded throwaway ed25519 key |
| `kop_kernel` | `ansible.posix.sysctl` (vm.swappiness only, `reload: true`, no `sysctl_file`), `ansible.builtin.mount_facts` (read-only), `community.general.modprobe` (`dummy` module) | if `dummy` is unavailable on the kernel, `modprobe_load`/`modprobe_exists` fail and are captured as-is (the module itself is still exercised) |
| `kop_firewall` | `community.general.ufw` | installs ufw via apt; forces `state: disabled` first and never `state: enabled`, so SSH can't be locked out; only adds/deletes an allow rule for 8080/tcp |
| `kop_storage` | `community.general.lvg`, `community.general.lvol`, `community.general.parted`, `community.general.zfs`, `ansible.builtin.mount` (tmpfs mount/unmount only) | loop devices from sparse files under `/var/tmp` created and detached by the role; zfs probes a *dataset* on a `zpool create`d pool (`community.general.zfs` does not create pools) |
| `kop_pkg_misc` | `ansible.posix.synchronize`, `ansible.builtin.subversion`, `community.general.apache2_module`, `community.general.java_cert`, `community.crypto.openssl_csr_info` | synchronize copies between two `/var/tmp` dirs in push mode, delegated to the host itself (`delegate_to: inventory_hostname`) so rsync reads and writes on the host and never needs the controller; subversion checks out from a local `svnadmin create` repo; apache2 (harmless modules: headers/rewrite/proxy_http) and default-jdk-headless are installed via apt first |
| `kop_misc2` | `community.general.deploy_helper`, `community.general.easy_install`, `community.general.maven_artifact`, `community.docker.current_container_facts`, `community.libvirt.virt_net` | deploy_helper runs present/finalize/clean/absent plus check-mode and failure probes (a regular file blocking the `current` path) in `/var/tmp/kop_deploy`, with the unfinished-file (`DEPLOY_UNFINISHED`) handling probed via `state=clean`; easy_install installs `python3-setuptools` via apt first and probes `easy_install3` (easy_install is deprecated - whatever the host lets it do, including failures, is captured); maven_artifact installs `maven` + `python3-lxml` via apt and downloads `junit:junit:4.13.2` from Maven Central into `/var/tmp`; current_container_facts is read-only (on a bare VM it just reports not-in-container facts); virt_net installs `libvirt-daemon-system` + `python3-libvirt` + `python3-lxml`, starts libvirtd, then defines/starts/stops a tiny NAT network (`10.99.99.0/24`, `command: define` with inline XML) with idempotent/check/failure probes, and undefines everything in cleanup |
| *(not probed)* | `community.general.snap`, `community.general.homebrew` | **deliberately skipped**: installing snapd via apt is slow and flaky in a fresh-VM round, and homebrew is macOS-only. Not worth the round time for a key-order probe. |
| *(not probed)* | krikri's `py_module` runner | **deliberately skipped**: `py_module` is not a real Ansible module - it is krikri's transport for role-private custom `library/*.py` modules. Real Ansible invokes such a module by its own name, so there is no matching `py_module` result shape to diff key order against. |

Note that several of these modules live in collections
(`ansible.posix`, `community.general`, `community.crypto`); the probed set
still matches krikri's supported-module list (`plugins/*.cr` has all of
them except the two deliberately skipped ones).

## Queueing a round

Queue file: `queue.txt` in this directory. Queue files take absolute paths,
so the five lines use the `$KRIKRI_ROOT` placeholder (expanded to this repo
checkout's root by the runner; if the `keyorder` runner has no expansion
yet, `sed "s|\$KRIKRI_ROOT|$KRIKRI_ROOT|g" queue.txt > /tmp/kop_queue.txt`
first):

```
local:$KRIKRI_ROOT/testing/keyorder_probes/kop_accounts
local:$KRIKRI_ROOT/testing/keyorder_probes/kop_kernel
local:$KRIKRI_ROOT/testing/keyorder_probes/kop_firewall
local:$KRIKRI_ROOT/testing/keyorder_probes/kop_storage
local:$KRIKRI_ROOT/testing/keyorder_probes/kop_pkg_misc
```

Run it (Atlantic.net only, keep inside the account's 22-concurrent-host
budget shared with any other running batches):

```
bin/krikri-role-tester run testing/keyorder_probes/queue.txt \
  --backend atlantic --os ubuntu --atlantic-hosts N \
  --results-dir ~/scratch/krt-results --round-start <N>
```

The `local:` queue form and the `keyorder` subcommand are being added to
`../krikri-role-tester`; see its README there.

Additional queue files can round up a subset of the roles without re-running
the whole set. `queue_misc2.txt` currently holds just the `kop_misc2` line:

```
local:$KRIKRI_ROOT/testing/keyorder_probes/kop_misc2
```

Run it the same way as `queue.txt` above (`bin/krikri-role-tester run
testing/keyorder_probes/queue_misc2.txt --backend atlantic ...`).

## Local validation status

Validated locally on the dev laptop (no root, no real kernel):

- `ansible-playbook --syntax-check` (2.19.11) over all six roles via
  `syntax_check.yml` - pass.
- krikri-playbook parse/syntax check (`--syntax-check` and `--list-tasks`)
  over the same wrapper - pass, task list matches real ansible.
- `ansible-lint` over the roles (run from inside this directory so
  `.ansible-lint` applies; the deliberate per-probe `ignore_errors` is
  skipped there) - pass, only the intentional `ufw_fail` bogus-rule probe
  warns.

Smoke-tested in a rootless podman `ubuntu:22.04` container as root with
`ansible_connection=local` (`smoke_wrapper.yml` + `smoke_inside.sh`, run
twice to mimic cold/warm). The smoke script installs `ansible-core` 2.17.8
via pip (jammy's apt `ansible` is ancient 2.10.8, and its `python3-libcloud`
dependency can fail to unpack in overlayfs - harmless for the probes) plus
the `ansible.posix`, `community.general` and `community.crypto`
collections. Result: both runs rc=0, `failed=0`, identical 53-probe
KEYORDER set both runs (`ignored=8` = the deliberate failure probes):

- `kop_accounts` in full (user/group/authorized_key/known_hosts are all
  container-safe; the role creates `~/.ssh` first because a bare container
  root has none).
- `kop_pkg_misc` in full: synchronize (rsync local-to-local, source
  delegated to the host itself, so rsync runs entirely on the host), subversion (local svnadmin repo),
  apache2_module, java_cert (default-jdk-headless + self-signed cert),
  openssl_csr_info.
- `kop_misc2` (deploy_helper, easy_install, maven_artifact,
  current_container_facts) via its own `kop_misc2/smoke_wrapper.yml` +
  `kop_misc2/smoke_inside.sh` (containers named `kp-misc2-*`, removed after
  the run; apt-installs `python3-setuptools`, `maven`, `python3-lxml` and
  the community.general/community.docker/community.libvirt collections).
  Result: both runs rc=0, `failed=0`, identical 39-probe KEYORDER set both
  runs. Inside the container the virt_net probes all fail (no libvirtd
  socket) and are ignored - that is the expected container shape, the real
  shapes come from the Atlantic.net round. easy_install may record failures
  depending on what the deprecated `easy_install3` tool can still fetch
  from PyPI - those are captured as-is by design.

NOT smoke-tested locally (kernel-dependent; need a real root VM, exactly
what the Atlantic.net round provides):

- `kop_kernel` in full (sysctl, modprobe need the real kernel; mount_facts
  needs real mounts).
- `kop_firewall` in full (ufw manipulates iptables/ufw state).
- `kop_storage` in full (losetup/LVM/parted/zfs/mount need a real kernel
  and loop-device privileges; tmpfs mounts fail in a rootless container).
- `kop_misc2`'s `virt_net` probes (libvirtd and its dnsmasq-driven NAT
  networking do not work in a rootless container - exactly what the
  Atlantic.net round provides).

## Files

- `kop_*/tasks/main.yml` - the probe roles.
- `roles/` - symlinks to the roles (both ansible-playbook and
  krikri-playbook resolve roles next to the playbook, so the wrapper
  playbooks need no `ANSIBLE_ROLES_PATH`).
- `syntax_check.yml` - wrapper for `--syntax-check`/`--list-tasks` over all
  five roles.
- `smoke_wrapper.yml` + `smoke_inside.sh` - rootless-podman smoke test for
  the container-safe roles (containers named `km-probes-*`, removed after
  the run).
- `queue.txt` - the five `local:` queue lines for `krikri-role-tester run`.
- `queue_misc2.txt` - queue file holding only the `kop_misc2` role (see
  "Queueing a round" above).
- `kop_misc2/smoke_wrapper.yml` + `kop_misc2/smoke_inside.sh` - rootless-
  podman smoke test for kop_misc2's container-safe modules (deploy_helper,
  easy_install, maven_artifact, current_container_facts; virt_net is not
  container-runnable).
