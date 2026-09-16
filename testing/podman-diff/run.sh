#!/usr/bin/env bash
# Local differential-testing loop: runs the same edge-case fixture
# playbooks under real ansible-playbook (container A) and
# krikri-playbook (container B), both via ansible_connection=local
# inside their own throwaway podman container, and diffs the debug
# output lines so a single divergent case is visible without needing
# a full Atlantic.net round. See krikri/CLAUDE.md's "podman run
# --systemd=always ... remains sufficient" note - this is that
# replacement, scoped to module-level edge cases rather than full
# Galaxy roles.
#
#   ./run.sh                # run all cases/*.yml
#   ./run.sh file_edge_cases.yml   # run just one
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
DIFF_DIR="$(pwd)"
REPO_DIR="$(cd "$DIFF_DIR/../.." && pwd)"
IMAGE="docker.io/library/debian:bookworm-slim"
# Per-invocation suffix: container names are global to podman, so two
# concurrent run.sh sessions (e.g. two worktrees) would otherwise keep
# rm -f'ing each other's mid-run containers.
SUFFIX="-$(date +%s)-$$"
NAME_A="krikri-diff-real$SUFFIX"
NAME_B="krikri-diff-krikri$SUFFIX"
RESULTS="$DIFF_DIR/results"
mkdir -p "$RESULTS"

log() { echo "[podman-diff] $*" >&2; }

cleanup() {
  podman rm -f "$NAME_A" "$NAME_B" >/dev/null 2>&1
}
trap cleanup EXIT

# --privileged: sysctl/hostname modules need a writable /proc/sys and
# sethostname inside the container - an unprivileged podman container
# denies both, which would fail only the REAL side and manufacture
# divergences.
log "starting containers"
podman run -d --privileged --name "$NAME_A" "$IMAGE" sleep infinity >/dev/null
podman run -d --privileged --name "$NAME_B" "$IMAGE" sleep infinity >/dev/null

log "installing ansible-core in $NAME_A"
podman exec "$NAME_A" bash -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends ansible-core python3 procps cron gnupg git >/dev/null" \
  || { log "FATAL: ansible-core install failed"; exit 1; }

log "installing collections in $NAME_A (ansible.posix, community.general, community.crypto)"
podman exec "$NAME_A" bash -c "ansible-galaxy collection install ansible.posix community.general community.mysql community.crypto >/dev/null 2>&1" \
  || { log "FATAL: collection install failed"; exit 1; }

log "staging krikri-playbook in $NAME_B"
podman exec "$NAME_B" bash -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends libxml2 libssl3 libyaml-0-2 libpcre2-8-0 python3 procps cron gnupg git >/dev/null" \
  || { log "FATAL: runtime lib install failed"; exit 1; }
podman exec "$NAME_B" bash -c "mkdir -p /opt/krikri/bin"
podman cp "$REPO_DIR/bin/krikri-playbook" "$NAME_B:/opt/krikri/bin/krikri-playbook"
podman cp "$REPO_DIR/bin/plugins" "$NAME_B:/opt/krikri/bin/plugins"
podman exec "$NAME_B" bash -c "chmod +x /opt/krikri/bin/krikri-playbook /opt/krikri/bin/plugins/*"

for container in "$NAME_A" "$NAME_B"; do
  podman exec "$container" mkdir -p /work
  podman cp "$DIFF_DIR/inventory.ini" "$container:/work/inventory.ini"
  podman cp "$DIFF_DIR/templates/." "$container:/tmp/"
done

cases=("$@")
if [ ${#cases[@]} -eq 0 ]; then
  cases=()
  while IFS= read -r f; do cases+=("$(basename "$f")"); done < <(find "$DIFF_DIR/cases" -name '*.yml' | sort)
fi

# mysql_* cases need a real MariaDB in BOTH containers (krikri's
# mysql_user talks the wire protocol itself, real community.mysql needs
# PyMySQL) plus community.mysql in the real one - gated on the requested
# case list so ordinary runs don't pay the mariadb-server install.
if printf '%s\n' "${cases[@]}" | grep -q '^mysql'; then
  log "installing mariadb-server (+ PyMySQL + community.mysql) for mysql cases"
  podman exec "$NAME_A" bash -c "apt-get install -y -qq --no-install-recommends mariadb-server python3-pymysql >/dev/null && service mariadb start >/dev/null && sleep 3 && ansible-galaxy collection install community.mysql >/dev/null 2>&1" \
    || { log "FATAL: mariadb/community.mysql install failed"; exit 1; }
  podman exec "$NAME_B" bash -c "apt-get install -y -qq --no-install-recommends mariadb-server >/dev/null && service mariadb start >/dev/null && sleep 3" \
    || { log "FATAL: mariadb install failed"; exit 1; }
fi

# docker_* cases run argument-validation only (there is no docker daemon
# inside either container, and no docker-in-podman) - the real side
# still needs the community.docker collection + Docker SDK importable,
# or every case fails on the SDK import instead of on the args.
if printf '%s\n' "${cases[@]}" | grep -q '^docker'; then
  log "installing community.docker + Docker SDK for docker cases"
  podman exec "$NAME_A" bash -c "apt-get install -y -qq --no-install-recommends python3-docker >/dev/null && ansible-galaxy collection install community.docker >/dev/null 2>&1" \
    || { log "FATAL: community.docker/Docker SDK install failed"; exit 1; }
fi

# deb822_repository landed in ansible-core 2.15; bookworm's apt ships
# 2.14, where the module doesn't exist yet (a harness artifact, not a
# divergence). For deb822 cases the real side gets a venv with a current
# ansible-core + python3-debian (the module's own runtime dep) and those
# cases run with that venv's ansible-playbook.
#
# dpkg_selections has the same 2.14 problem in the other direction: the
# "Failed to find package 'x' to perform selection 'y'." guard for a
# package dpkg has never heard of only landed in ansible-core 2.16
# (verified against the 2.14/2.16/2.18/devel sources) - 2.14 silently
# records a selection for the unknown package and reports changed=True.
# krikri matches 2.16+, so dpkg_selections cases run under the same
# venv's current ansible-playbook.
DEB822_ANSIBLE=""
if printf '%s\n' "${cases[@]}" | grep -qE '^(deb822|dpkg_selections)'; then
  log "installing venv ansible-core (>=2.15) for deb822/dpkg_selections cases (+ python3-debian for deb822)"
  podman exec "$NAME_A" bash -c "apt-get install -y -qq --no-install-recommends python3-venv python3-debian >/dev/null && python3 -m venv /opt/ansible215 && /opt/ansible215/bin/pip install -q ansible-core" \
    || { log "FATAL: venv ansible-core install failed"; exit 1; }
  DEB822_ANSIBLE="/opt/ansible215/bin/ansible-playbook"
fi

# package_facts cases need python3-apt in the REAL container (its apt
# manager is python-apt-based and yields nothing without it, so every
# case would fail there while krikri's dpkg-query backend succeeds) -
# gated on the requested case list like the mysql cases above.
if printf '%s\n' "${cases[@]}" | grep -q '^package_facts'; then
  log "installing python3-apt for package_facts cases"
  podman exec "$NAME_A" bash -c "apt-get install -y -qq --no-install-recommends python3-apt >/dev/null" \
    || { log "FATAL: python3-apt install failed"; exit 1; }
fi

# openssl_csr cases need the openssl CLI in BOTH containers (the case
# playbook inspects generated CSRs with `openssl req -noout -text` in the
# krikri container too, whose base image doesn't ship the binary) -
# gated on the requested case list like the mysql cases above.
if printf '%s\n' "${cases[@]}" | grep -q '^openssl'; then
  log "installing openssl CLI for openssl cases"
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" bash -c "apt-get install -y -qq --no-install-recommends openssl >/dev/null" \
      || { log "FATAL: openssl install failed in $c"; exit 1; }
  done
fi

# gem cases need a real ruby + rubygems (the `gem` CLI) in BOTH
# containers - debian:bookworm-slim ships without it, which would make
# every case fail with "Failed to find required executable" instead of
# exercising the install/idempotency logic. Gated on the requested case
# list like the modprobe cases above.
if printf '%s\n' "${cases[@]}" | grep -q '^gem'; then
  log "installing ruby for gem cases"
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" bash -c "apt-get install -y -qq --no-install-recommends ruby >/dev/null" \
      || { log "FATAL: ruby install failed in $c"; exit 1; }
  done
fi

# firewalld cases need the firewalld PACKAGE (firewall-offline-cmd +
# the python bindings the real module imports) in BOTH containers -
# without it real ansible.posix.firewalld dies on the import before any
# validation, manufacturing a divergence. No daemon runs (no systemd);
# the real module auto-detects offline mode, same backend krikri
# drives. Gated on the requested case list like the mysql cases above.
if printf '%s\n' "${cases[@]}" | grep -q '^firewalld'; then
  log "installing firewalld package (offline-cmd + bindings) for firewalld cases"
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" bash -c "apt-get install -y -qq --no-install-recommends firewalld >/dev/null" \
      || { log "FATAL: firewalld install failed in $c"; exit 1; }
  done
fi

# apache2_module cases need a real apache2 (a2enmod/a2dismod/apache2ctl)
# in BOTH containers - the module drives those binaries directly and the
# base image ships none of them. No daemon is started (none of the
# apache2_module paths need a running server; apache2ctl -M only parses
# the config). Gated on the requested case list like the firewalld cases
# above.
if printf '%s\n' "${cases[@]}" | grep -q '^apache2_module'; then
  log "installing apache2 for apache2_module cases"
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" bash -c "apt-get install -y -qq --no-install-recommends apache2 >/dev/null" \
      || { log "FATAL: apache2 install failed in $c"; exit 1; }
  done
fi

# postgresql_* cases need the community.postgresql collection in the
# REAL container (krikri talks the wire protocol itself; the real
# modules are collection modules not shipped with ansible-core).
# Validation-only cases - no PostgreSQL server is installed. Gated on
# the requested case list like the mysql cases above.
if printf '%s\n' "${cases[@]}" | grep -q '^postgresql'; then
  log "installing community.postgresql collection for postgresql cases"
  podman exec "$NAME_A" bash -c "ansible-galaxy collection install community.postgresql >/dev/null 2>&1" \
    || { log "FATAL: community.postgresql install failed"; exit 1; }
fi

# current_container_facts is a community.docker module (no Docker SDK
# import, pure /proc detection) - the REAL container still needs the
# collection or every case fails on module lookup. The two engines run
# in DIFFERENT throwaway podman containers so the detected container id
# necessarily differs; the case file prints shape checks, not the id.
# Gated on the requested case list like the postgresql cases.
if printf '%s\n' "${cases[@]}" | grep -q '^current_container_facts'; then
  log "installing community.docker collection for current_container_facts cases"
  podman exec "$NAME_A" bash -c "ansible-galaxy collection install community.docker >/dev/null 2>&1" \
    || { log "FATAL: community.docker install failed"; exit 1; }
fi

# expect cases need pexpect in the REAL container - real
# ansible.builtin.expect.py fails with "Failed to import the required
# Python library (pexpect)." before any behavior otherwise. krikri's
# plugin talks to the kernel pty directly (openpty + fork), so it needs
# nothing. Gated on the requested case list like the htpasswd cases.
if printf '%s\n' "${cases[@]}" | grep -q '^expect'; then
  log "installing python3-pexpect for expect cases"
  podman exec "$NAME_A" bash -c "apt-get install -y -qq --no-install-recommends python3-pexpect >/dev/null" \
    || { log "FATAL: python3-pexpect install failed"; exit 1; }
fi

# make cases need the real make(1) in BOTH containers - real
# community.general.make and krikri's plugin both shell to it, and
# debian:bookworm-slim ships without it. Gated on the requested case
# list like the modprobe cases above.
if printf '%s\n' "${cases[@]}" | grep -q '^make'; then
  log "installing make for make cases"
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" bash -c "apt-get install -y -qq --no-install-recommends make >/dev/null" \
      || { log "FATAL: make install failed in $c"; exit 1; }
  done
fi

# nsupdate cases need dnspython in the REAL container - real
# community.general.nsupdate fails with "Failed to import the required
# Python library (dnspython)." before any behavior otherwise. krikri
# speaks the DNS wire format natively. No DNS server runs in either
# container; the network cases exercise the refused-connection wording.
# Gated on the requested case list like the expect cases.
if printf '%s\n' "${cases[@]}" | grep -q '^nsupdate'; then
  log "installing python3-dnspython for nsupdate cases"
  podman exec "$NAME_A" bash -c "apt-get install -y -qq --no-install-recommends python3-dnspython >/dev/null" \
    || { log "FATAL: python3-dnspython install failed"; exit 1; }
fi

# ec2_metadata_facts cases need the amazon.aws collection in the REAL
# container (collection module, not shipped with ansible-core).
# Validation-only + unreachable-endpoint cases - the real IMDS endpoint
# doesn't exist inside a container, and both engines must fail cleanly
# there. Gated on the requested case list like the postgresql cases.
if printf '%s\n' "${cases[@]}" | grep -q '^ec2_metadata'; then
  log "installing amazon.aws collection for ec2_metadata_facts cases"
  podman exec "$NAME_A" bash -c "ansible-galaxy collection install amazon.aws >/dev/null 2>&1" \
    || { log "FATAL: amazon.aws install failed"; exit 1; }
fi

# rabbitmq_user cases are argument-validation only (no RabbitMQ server
# or even rabbitmqctl binary in either container - both engines must
# fail identically on the missing binary / missing args). The real side
# still needs the community.rabbitmq collection (a collection module,
# not shipped with ansible-core), or every case fails on module lookup
# instead of on the args. Gated on the requested case list like the
# postgresql cases.
if printf '%s\n' "${cases[@]}" | grep -q '^rabbitmq'; then
  log "installing community.rabbitmq collection for rabbitmq cases"
  podman exec "$NAME_A" bash -c "ansible-galaxy collection install community.rabbitmq >/dev/null 2>&1" \
    || { log "FATAL: community.rabbitmq install failed"; exit 1; }
fi

# xml cases: the real community.general.xml imports lxml in the REAL
# container - without python3-lxml every case fails on the import
# instead of exercising the xpath/mutation logic. krikri's xml plugin
# uses native libxml2 (already installed in the krikri container).
# Gated on the requested case list like the htpasswd cases.
if printf '%s\n' "${cases[@]}" | grep -q '^xml'; then
  log "installing python3-lxml for xml cases"
  podman exec "$NAME_A" bash -c "apt-get install -y -qq --no-install-recommends python3-lxml >/dev/null" \
    || { log "FATAL: python3-lxml install failed"; exit 1; }
fi

# locale_gen cases need the locales package (real /etc/locale.gen,
# /usr/share/i18n/SUPPORTED and the locale-gen binary) in BOTH
# containers - debian:bookworm-slim ships without it, which would make
# every case fail with the "Is the package 'locales' installed?"
# mechanism error instead of exercising the glibc path. locale-gen
# works fine inside a container, so real generation IS testable here.
# Gated on the requested case list like the modprobe cases above.
if printf '%s\n' "${cases[@]}" | grep -q '^locale_gen'; then
  log "installing locales for locale_gen cases"
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" bash -c "apt-get install -y -qq --no-install-recommends locales >/dev/null" \
      || { log "FATAL: locales install failed in $c"; exit 1; }
  done
fi

# modprobe cases need the kmod package (real /sbin/modprobe) in BOTH
# containers - debian:bookworm-slim ships without it, which would make
# every case fail with "Failed to find required executable" instead of
# exercising the module-state logic. Gated on the requested case list
# like the mysql/openssl cases above.
if printf '%s\n' "${cases[@]}" | grep -q '^modprobe'; then
  log "installing kmod for modprobe cases"
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" bash -c "apt-get install -y -qq --no-install-recommends kmod >/dev/null" \
      || { log "FATAL: kmod install failed in $c"; exit 1; }
  done
fi

# iptables cases need the real iptables(8) binary in BOTH containers -
# krikri's plugin shells to it exactly like real Ansible - and
# --privileged is already on for both containers; a rootless-podman
# netfilter restriction, if present, fails BOTH engines identically.
# The venv from the deb822 block below is reused when needed: bookworm's
# 2.14 doesn't have ansible.builtin.iptables yet (landed in 2.15) and
# 2.14 can't follow community.general's redirect to it, so iptables
# cases run against the venv's current ansible-core. Gated on the
# requested case list like the mysql cases above.
IPTABLES_ANSIBLE=""
if printf '%s\n' "${cases[@]}" | grep -q '^iptables'; then
  log "installing iptables for iptables cases"
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" bash -c "apt-get install -y -qq --no-install-recommends iptables >/dev/null" \
      || { log "FATAL: iptables install failed in $c"; exit 1; }
  done
  if ! podman exec "$NAME_A" test -x /opt/ansible215/bin/ansible-playbook; then
    log "installing venv ansible-core (>=2.15) for iptables cases (2.14 lacks ansible.builtin.iptables)"
    podman exec "$NAME_A" bash -c "apt-get install -y -qq --no-install-recommends python3-venv >/dev/null && python3 -m venv /opt/ansible215 && /opt/ansible215/bin/pip install -q ansible-core" \
      || { log "FATAL: venv ansible-core install failed"; exit 1; }
  fi
  IPTABLES_ANSIBLE="/opt/ansible215/bin/ansible-playbook"
fi

# seboolean/seport/selinux cases need the real modules' own python
# libs in the REAL container only - without
# python3-selinux/python3-semanage every case would fail on the
# libselinux/seobject import checks and mask all the argument-
# validation behavior the cases are actually testing. krikri's
# seboolean shells out to getenforce/getsebool, seport to semanage,
# and selinux reads/writes /etc/selinux/config itself, so krikri needs
# nothing. (The container genuinely has no SELinux - that's the point;
# see the case files' own headers.)
if printf '%s\n' "${cases[@]}" | grep -qE '^(seboolean|seport|selinux)'; then
  log "installing python3-selinux + python3-semanage for seboolean/seport/selinux cases"
  podman exec "$NAME_A" bash -c "apt-get install -y -qq --no-install-recommends python3-selinux python3-semanage >/dev/null" \
    || { log "FATAL: SELinux python libs install failed"; exit 1; }
fi

# htpasswd cases: the real community.general.htpasswd imports passlib in
# the REAL container - without python3-passlib every case fails on the
# import instead of exercising the hash/idempotency logic. krikri's
# htpasswd shells to `openssl passwd`, so BOTH containers need the
# openssl CLI on PATH (bookworm-slim ships without it). Gated on the
# requested case list like the mysql cases above.
if printf '%s\n' "${cases[@]}" | grep -q '^htpasswd'; then
  log "installing passlib (real) + openssl (both) for htpasswd cases"
  podman exec "$NAME_A" bash -c "apt-get install -y -qq --no-install-recommends python3-passlib >/dev/null" \
    || { log "FATAL: passlib install failed"; exit 1; }
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" bash -c "apt-get install -y -qq --no-install-recommends openssl >/dev/null" \
      || { log "FATAL: openssl install failed in $c"; exit 1; }
  done
fi

# npm cases need a real node + npm in BOTH containers (krikri's npm
# shells to the same npm binary real Ansible resolves via
# get_bin_path) - debian:bookworm-slim ships without either, which
# would make every case fail with "Failed to find required executable"
# on both sides and exercise nothing. Real installs hit the live npm
# registry; both engines see the same network. Gated like the gem cases.
if printf '%s\n' "${cases[@]}" | grep -q '^npm'; then
  log "installing npm for npm cases"
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" bash -c "apt-get install -y -qq --no-install-recommends npm >/dev/null" \
      || { log "FATAL: npm install failed in $c"; exit 1; }
  done
fi

# synchronize cases need the rsync binary in BOTH containers - real
# ansible.posix.synchronize and krikri's action plugin both shell to
# it, and with ansible_connection=local both rsync endpoints are the
# same machine. Gated on the requested case list like the modprobe
# cases above.
if printf '%s\n' "${cases[@]}" | grep -q '^synchronize'; then
  log "installing rsync for synchronize cases"
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" bash -c "apt-get install -y -qq --no-install-recommends rsync >/dev/null" \
      || { log "FATAL: rsync install failed in $c"; exit 1; }
  done
fi

# acl cases need the acl package (getfacl/setfacl) in BOTH containers -
# real ansible.builtin.acl and krikri's plugin both shell to it, and
# debian:bookworm-slim ships without it. Gated on the requested case
# list like the modprobe cases above.
if printf '%s\n' "${cases[@]}" | grep -q '^acl'; then
  log "installing acl for acl cases"
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" bash -c "apt-get install -y -qq --no-install-recommends acl >/dev/null" \
      || { log "FATAL: acl install failed in $c"; exit 1; }
  done
fi

# capabilities cases need libcap2-bin (getcap/setcap) in BOTH
# containers - real community.general.capabilities and krikri's plugin
# both shell to them, and debian:bookworm-slim ships without them.
# Gated on the requested case list like the modprobe cases above.
if printf '%s\n' "${cases[@]}" | grep -q '^capabilities'; then
  log "installing libcap2-bin for capabilities cases"
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" bash -c "apt-get install -y -qq --no-install-recommends libcap2-bin >/dev/null" \
      || { log "FATAL: libcap2-bin install failed in $c"; exit 1; }
  done
fi

# known_hosts cases need ssh-keygen in BOTH containers (real
# ansible.builtin.known_hosts and krikri's plugin both drive it for
# lookup, removal and host hashing). Gated on the requested case list
# like the modprobe cases above.
if printf '%s\n' "${cases[@]}" | grep -q '^known_hosts'; then
  log "installing openssh-client for known_hosts cases"
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" bash -c "apt-get install -y -qq --no-install-recommends openssh-client >/dev/null" \
      || { log "FATAL: openssh-client install failed in $c"; exit 1; }
  done
fi

# py_module cases need the playbook-dir library/ fixture modules seeded
# into BOTH containers BEFORE ansible-playbook loads the playbook:
# real Ansible resolves a task's module name at playbook-LOAD time
# against the on-disk library/ (a module written by an earlier playbook
# task is invisible to it -> "ERROR! couldn't resolve module/action",
# rc=4, zero tasks run), while krikri resolves lazily per task. The
# fixtures live in library/ next to run.sh. Gated on the requested
# case list like the mysql cases above.
if printf '%s\n' "${cases[@]}" | grep -q '^py_module'; then
  log "seeding library/ fixture modules for py_module cases"
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" mkdir -p /work/library
    for f in "$DIFF_DIR"/library/*.py; do
      podman cp "$f" "$c:/work/library/$(basename "$f")" >/dev/null \
        || { log "FATAL: library fixture copy failed in $c"; exit 1; }
    done
  done
fi

# subversion cases need the real svn + svnadmin binaries in BOTH
# containers (real ansible.builtin.subversion and krikri's plugin both
# shell out to svn), plus a seeded local file:// repo so real
# checkout/update/export/idempotency paths actually run. Gated on the
# requested case list like the modprobe cases above.
if printf '%s\n' "${cases[@]}" | grep -q '^subversion'; then
  log "installing subversion + seeding a local file:// repo for subversion cases"
  for c in "$NAME_A" "$NAME_B"; do
    podman exec "$c" bash -c "apt-get install -y -qq --no-install-recommends subversion >/dev/null" \
      || { log "FATAL: subversion install failed in $c"; exit 1; }
    podman exec "$c" bash -c "rm -rf /work/krikri_repo /work/krikri_src && mkdir -p /work/krikri_src && echo krikri > /work/krikri_src/krikri.txt && svnadmin create /work/krikri_repo && svn import --non-interactive -m krikri /work/krikri_src file:///work/krikri_repo >/dev/null" \
      || { log "FATAL: svn repo seeding failed in $c"; exit 1; }
  done
fi

# virt_net cases are argument-validation + HAS_VIRT-probe only (no
# libvirt daemon in either container). The real side needs the
# community.libvirt collection but deliberately gets NO python3-libvirt,
# so valid-argument paths fail on the module's own import probe - the
# same surface krikri's plugin mirrors with the absent `virsh` binary.
# Gated on the requested case list like the postgresql cases.
if printf '%s\n' "${cases[@]}" | grep -q '^virt_net'; then
  log "installing community.libvirt collection for virt_net cases"
  podman exec "$NAME_A" bash -c "ansible-galaxy collection install community.libvirt >/dev/null 2>&1" \
    || { log "FATAL: community.libvirt install failed"; exit 1; }
fi

# zfs cases are argument-validation only: neither container installs
# zfs/zpool (no /dev/zfs in a container anyway), so real's
# get_bin_path failure is the first reachable non-argument failure on
# both sides - no installs needed, listed here for the record.

overall_rc=0
for case_file in "${cases[@]}"; do
  case_name="${case_file%.yml}"
  log "=== $case_name ==="
  podman cp "$DIFF_DIR/cases/$case_file" "$NAME_A:/work/case.yml"
  podman cp "$DIFF_DIR/cases/$case_file" "$NAME_B:/work/case.yml"

  podman exec "$NAME_A" bash -c \
    "cd /work && ANSIBLE_NOCOLOR=1 ${IPTABLES_ANSIBLE:-${DEB822_ANSIBLE:-ansible-playbook}} -i inventory.ini case.yml" \
    > "$RESULTS/${case_name}_real.log" 2>&1
  rc_a=$?

  podman exec "$NAME_B" bash -c \
    "cd /work && /opt/krikri/bin/krikri-playbook -i inventory.ini case.yml" \
    > "$RESULTS/${case_name}_krikri.log" 2>&1
  rc_b=$?

  # Extract just the debug-line payloads. Real ansible-playbook prints
  # them as `"msg": "F1 failed=..."`, krikri-playbook as a plain
  # `  F1 failed=...` - the label+key=value pattern (not just "F1")
  # is what lets this match both formats while skipping TASK-name
  # lines like "F1 touch a file ..." that also contain "F1 " but no
  # trailing key=value. The label shape is general: one uppercase
  # letter (the case-file's prefix - F=file, T=template, S=set_fact,
  # C=command, ...), digits, and an optional lowercase a-c sub-case
  # suffix, so new case files only need to pick an unused prefix.
  msgs_a="$RESULTS/${case_name}_real.msgs"
  msgs_b="$RESULTS/${case_name}_krikri.msgs"
  # Real ansible-playbook prints msg as a JSON string, so backslashes
  # in actual on-disk content arrive doubled ("\\1" for "\1") and must
  # be unescaped to compare with krikri-playbook's raw plain-text
  # output. The placeholder pass below unescapes \\ without turning a
  # JSON \n (newline, already handled) or the trailing quote-cleanup
  # into the wrong thing. ("\\n" in JSON means literal backslash+n and
  # survives as such.)
  # Volatile backup paths (backup_file: pid + timestamp) are masked so
  # an otherwise-identical run still MATCHes.
  extract() {
    # Drop real ansible's error-context source echo first: a failed task
    # makes real ansible-playbook print the surrounding playbook lines
    # prefixed with a line number ("37         msg: \"V2b failed=...\""),
    # which would otherwise double-extract the PREVIOUS debug label with
    # its raw unrendered template and show as a phantom divergence.
    sed -E '/^[0-9]+[[:space:]]/d' "$1" \
      | grep -oE '\b[A-Z][0-9]+[a-c]? [a-zA-Z_]+=.*' \
      | sed -E 's/\\\\/\x01/g; s/\\n/ | /g; s/\x01/\\/g; s/\\"/"/g; s/"\}?(,)?$//; s/[[:space:]]*\*+[[:space:]]*$//; s/=[^ ]*[0-9]{2,6}\.[0-9]{4}-[0-9]{2}-[0-9]{2}@[0-9:]{8}~/=<backup-path>/g'
  }
  extract "$RESULTS/${case_name}_real.log" > "$msgs_a"
  extract "$RESULTS/${case_name}_krikri.log" > "$msgs_b"

  if diff -u "$msgs_a" "$msgs_b" > "$RESULTS/${case_name}.diff"; then
    log "$case_name: MATCH (rc_real=$rc_a rc_krikri=$rc_b)"
    [ "$rc_a" = "$rc_b" ] || log "$case_name: WARNING rc mismatch despite matching debug output"
  else
    log "$case_name: DIVERGENT (rc_real=$rc_a rc_krikri=$rc_b) - see $RESULTS/${case_name}.diff"
    overall_rc=1
  fi
done

exit $overall_rc
