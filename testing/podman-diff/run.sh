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
DEB822_ANSIBLE=""
if printf '%s\n' "${cases[@]}" | grep -q '^deb822'; then
  log "installing venv ansible-core (>=2.15) + python3-debian for deb822 cases"
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

overall_rc=0
for case_file in "${cases[@]}"; do
  case_name="${case_file%.yml}"
  log "=== $case_name ==="
  podman cp "$DIFF_DIR/cases/$case_file" "$NAME_A:/work/case.yml"
  podman cp "$DIFF_DIR/cases/$case_file" "$NAME_B:/work/case.yml"

  podman exec "$NAME_A" bash -c \
    "cd /work && ANSIBLE_NOCOLOR=1 ${DEB822_ANSIBLE:-ansible-playbook} -i inventory.ini case.yml" \
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
      | sed -E 's/\\\\/\x01/g; s/\\n/ | /g; s/\x01/\\/g; s/"\}?(,)?$//; s/=[^ ]*[0-9]{2,6}\.[0-9]{4}-[0-9]{2}-[0-9]{2}@[0-9:]{8}~/=<backup-path>/g'
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
