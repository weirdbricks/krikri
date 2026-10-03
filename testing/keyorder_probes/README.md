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

All run as root on a fresh Atlantic.net VM - Ubuntu 22.04 for the first
five roles, Rocky Linux 9 for `kop_rocky` (see its row).

| Role | Modules probed | Notes |
|---|---|---|
| `kop_accounts` | `ansible.builtin.user`, `ansible.builtin.group`, `ansible.posix.authorized_key`, `ansible.builtin.known_hosts` | embedded throwaway ed25519 key |
| `kop_kernel` | `ansible.posix.sysctl` (vm.swappiness only, `reload: true`, no `sysctl_file`), `ansible.builtin.mount_facts` (read-only), `community.general.modprobe` (`dummy` module) | if `dummy` is unavailable on the kernel, `modprobe_load`/`modprobe_exists` fail and are captured as-is (the module itself is still exercised) |
| `kop_firewall` | `community.general.ufw` | installs ufw via apt; forces `state: disabled` first and never `state: enabled`, so SSH can't be locked out; only adds/deletes an allow rule for 8080/tcp |
| `kop_storage` | `community.general.lvg`, `community.general.lvol`, `community.general.parted`, `community.general.zfs`, `ansible.builtin.mount` (tmpfs mount/unmount only) | loop devices from sparse files under `/var/tmp` created and detached by the role; zfs probes a *dataset* on a `zpool create`d pool (`community.general.zfs` does not create pools) |
| `kop_pkg_misc` | `ansible.posix.synchronize`, `ansible.builtin.subversion`, `community.general.apache2_module`, `community.general.java_cert`, `community.crypto.openssl_csr_info` | synchronize copies between two `/var/tmp` dirs in push mode, delegated to the host itself (`delegate_to: inventory_hostname`) so rsync reads and writes on the host and never needs the controller; subversion checks out from a local `svnadmin create` repo; apache2 (harmless modules: headers/rewrite/proxy_http) and default-jdk-headless are installed via apt first |
| `kop_rocky` | `ansible.posix.selinux`, `ansible.posix.seboolean`, `community.general.sefcontext`, `community.general.seport`, `ansible.posix.firewalld` | Rocky Linux 9 only (needs a real SELinux/firewalld host; see `queue_rocky.txt`). SELinux is never set to `disabled` and never switched to `enforcing` from permissive - the `state: enforcing` probe and the cleanup restore only run when the host booted enforcing (`getenforce` guard via helper + `set_fact` + `when:`). firewalld is started first, the ssh service and the default zone are never touched, and every added rule (http service, 8789/tcp port, rich rule) is removed again; sefcontext/seport use throwaway paths (`/srv/kop_web(/.*)?`) and port 8789/tcp on `http_port_t` |
| *(not probed)* | `community.general.snap`, `community.general.homebrew` | **deliberately skipped**: installing snapd via apt is slow and flaky in a fresh-VM round, and homebrew is macOS-only. Not worth the round time for a key-order probe. |

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

### Rocky Linux 9 round (`kop_rocky`)

`kop_rocky` needs an SELinux/firewalld-capable RHEL-family host, so it gets
its own queue file, `queue_rocky.txt`, with an explicit backend/OS suffix on
the line (the rest of this directory targets Ubuntu):

```
local:$KRIKRI_ROOT/testing/keyorder_probes/kop_rocky atlantic rocky
```

Run it the same way, with `--os rocky`:

```
bin/krikri-role-tester run testing/keyorder_probes/queue_rocky.txt \
  --backend atlantic --os rocky --atlantic-hosts N \
  --results-dir ~/scratch/krt-results --round-start <N>
```

## Local validation status

Validated locally on the dev laptop (no root, no real kernel):

- `ansible-playbook --syntax-check` (2.19.11) over all five roles via
  `syntax_check.yml` - pass.
- krikri-playbook parse/syntax check (`--syntax-check` and `--list-tasks`)
  over the same wrapper - pass, task list matches real ansible.
- `ansible-lint` over the roles (run from inside this directory so
  `.ansible-lint` applies; the deliberate per-probe `ignore_errors` is
  skipped there) - pass, only the intentional `ufw_fail` bogus-rule probe
  warns.

`kop_rocky` (Rocky-only) was validated with the same three static checks
(`--syntax-check`/`--list-tasks` over `syntax_check.yml` on both engines,
with matching task lists, and `ansible-lint` - pass). It has **no local
smoke coverage at all**: every module it probes needs a real kernel with
SELinux and/or firewalld running (rootless containers can't do either), so
all of its probes are untested-locally and the Atlantic.net Rocky round is
their first real run:

- `selinux`/`seboolean`/`sefcontext`/`seport` - libselinux/libsemanage
  userspace plus a real SELinux-enabled kernel.
- `firewalld` - the firewalld daemon and its D-Bus API (`python3-firewall`).

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

NOT smoke-tested locally (kernel-dependent; need a real root VM, exactly
what the Atlantic.net round provides):

- `kop_kernel` in full (sysctl, modprobe need the real kernel; mount_facts
  needs real mounts).
- `kop_firewall` in full (ufw manipulates iptables/ufw state).
- `kop_storage` in full (losetup/LVM/parted/zfs/mount need a real kernel
  and loop-device privileges; tmpfs mounts fail in a rootless container).

## Files

- `kop_*/tasks/main.yml` - the probe roles.
- `roles/` - symlinks to the six roles (both ansible-playbook and
  krikri-playbook resolve roles next to the playbook, so the wrapper
  playbooks need no `ANSIBLE_ROLES_PATH`).
- `syntax_check.yml` - wrapper for `--syntax-check`/`--list-tasks` over all
  five roles.
- `smoke_wrapper.yml` + `smoke_inside.sh` - rootless-podman smoke test for
  the container-safe roles (containers named `km-probes-*`, removed after
  the run).
- `queue.txt` - the five `local:` queue lines for `krikri-role-tester run`.
- `queue_rocky.txt` - the `local:` queue line for the Rocky Linux 9
  `kop_rocky` round (backend/OS suffix: `atlantic rocky`).
