#!/usr/bin/env bash
# Runs one Galaxy role against a fresh Kata pair: real ansible-playbook on
# host A, krikri-playbook on host B, cold + warm on each, PLAY RECAP diffed.
#
#   ./run_role.sh <role> <octetA> <octetB> <results_dir>
#
# Exit code is always 0 (result goes in the summary file, not the exit
# code) so a batch of these can run under `&` without one bad role
# killing the caller's script under `set -e`.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
KATA_DIR="$(pwd)"
REPO_DIR="$(cd "$KATA_DIR/../.." && pwd)"

role="${1:?role}"
octet_a="${2:?octetA}"
octet_b="${3:?octetB}"
results_dir="${4:?results_dir}"

name_a="r${octet_a}a"
name_b="r${octet_b}b"
work="$(mktemp -d)"
out="$results_dir/$role"
mkdir -p "$out"

log() { echo "[$role] $*" >&2; }

cleanup() {
  ./kata-host.sh down "$name_a" >/dev/null 2>&1
  ./kata-host.sh down "$name_b" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

echo "PENDING" > "$out/status"

ip_a="$(timeout 200 ./kata-host.sh up "$name_a" "$octet_a" 2>>"$out/boot.log")"
rc_a=$?
ip_b="$(timeout 200 ./kata-host.sh up "$name_b" "$octet_b" 2>>"$out/boot.log")"
rc_b=$?

if [ "$rc_a" -ne 0 ] || [ "$rc_b" -ne 0 ] || [ -z "$ip_a" ] || [ -z "$ip_b" ]; then
  echo "BOOT_FAILED" > "$out/status"
  log "boot failed (a=$rc_a b=$rc_b)"
  exit 0
fi

mkdir -p "$work/roles"
if ! timeout 120 ansible-galaxy role install "$role" -p "$work/roles" -f \
      > "$out/galaxy_install.log" 2>&1; then
  echo "GALAXY_404" > "$out/status"
  log "galaxy install failed"
  exit 0
fi

role_name="$(ls "$work/roles")"
cat > "$work/play.yml" <<EOF
- hosts: all
  become: true
  gather_facts: true
  roles:
    - $role_name
EOF

key="$KATA_DIR/key"

cat > "$work/inv_a.ini" <<EOF
target ansible_host=$ip_a ansible_user=root ansible_ssh_private_key_file=$key ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
EOF
cat > "$work/inv_b.ini" <<EOF
target ansible_host=$ip_b ansible_user=root ansible_ssh_private_key_file=$key ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
EOF

run_ansible() {
  local label="$1"
  timeout 900 env ANSIBLE_ALLOW_BROKEN_CONDITIONALS=true ANSIBLE_HOST_KEY_CHECKING=false \
    ANSIBLE_NOCOLOR=1 ANSIBLE_FORCE_COLOR=0 \
    ANSIBLE_CACHE_PLUGIN= ANSIBLE_CACHE_PLUGIN_CONNECTION= ANSIBLE_GATHERING=implicit \
    ansible-playbook -i "$work/inv_a.ini" "$work/play.yml" --forks 1 \
    > "$out/ansible_$label.log" 2>&1
  echo $?
}

run_krikri() {
  local label="$1"
  timeout 900 "$REPO_DIR/bin/krikri-playbook" -i "$work/inv_b.ini" "$work/play.yml" --forks 1 \
    > "$out/krikri_$label.log" 2>&1
  local rc=$?
  # Real concurrency bug, not host load: when multiple krikri-playbook
  # processes run at once from this control machine (any concurrent-pair
  # batch - this harness AND the Atlantic.net 4-pairs-parallel workflow),
  # uploading the same local plugin binary to different remote hosts races
  # and intermittently corrupts the transfer ("Failed to upload .../plugins/X
  # to IP: @@@@..." then UNREACHABLE). See KNOWN_ISSUES.md. Retrying against
  # the SAME host does NOT reliably recover - whatever the race corrupts
  # (an SSH control socket? a half-written remote file?) seems to stick to
  # that host/connection. For "cold" this is harmless to fix: reboot host B
  # at a fresh octet and retry there instead. For "warm" a reboot would
  # silently turn the idempotency check into a second cold run - NOT done;
  # a warm UNREACHABLE just retries against the same (already-cold) host a
  # couple more times and gives up if that doesn't clear.
  local attempt=1
  while [ "$attempt" -le 3 ] && grep -q "UNREACHABLE" "$out/krikri_$label.log" 2>/dev/null; do
    attempt=$((attempt+1))
    log "krikri $label hit UNREACHABLE (plugin-upload race, see KNOWN_ISSUES.md), retry $attempt/3"
    sleep "0.$((RANDOM % 9 + 1))"
    if [ "$label" = "cold" ]; then
      local retry_octet=$((octet_b + 100 * attempt))
      local retry_name="r${retry_octet}b"
      ./kata-host.sh down "$name_b" >/dev/null 2>&1
      local new_ip
      new_ip="$(timeout 200 ./kata-host.sh up "$retry_name" "$retry_octet" 2>>"$out/boot.log")"
      if [ -n "$new_ip" ]; then
        name_b="$retry_name"
        ip_b="$new_ip"
        cat > "$work/inv_b.ini" <<EOF
target ansible_host=$ip_b ansible_user=root ansible_ssh_private_key_file=$key ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
EOF
      fi
    fi
    timeout 900 "$REPO_DIR/bin/krikri-playbook" -i "$work/inv_b.ini" "$work/play.yml" --forks 1 \
      > "$out/krikri_$label.log" 2>&1
    rc=$?
  done
  echo $rc
}

recap() { grep -E '^target *:' "$1" | tail -1; }

a_cold_rc=$(run_ansible cold)
a_cold_recap=$(recap "$out/ansible_cold.log")
a_warm_rc=$(run_ansible warm)
a_warm_recap=$(recap "$out/ansible_warm.log")

k_cold_rc=$(run_krikri cold)
k_cold_recap=$(recap "$out/krikri_cold.log")
k_warm_rc=$(run_krikri warm)
k_warm_recap=$(recap "$out/krikri_warm.log")

{
  echo "role=$role_name"
  echo "ansible_cold_rc=$a_cold_rc recap: $a_cold_recap"
  echo "krikri_cold_rc=$k_cold_rc recap: $k_cold_recap"
  echo "ansible_warm_rc=$a_warm_rc recap: $a_warm_recap"
  echo "krikri_warm_rc=$k_warm_rc recap: $k_warm_recap"
} > "$out/summary.txt"

norm() { echo "$1" | grep -oE '(ok|changed|unreachable|failed|skipped|rescued|ignored)=[0-9]+' | tr '\n' ' '; }

if [ "$(norm "$a_cold_recap")" = "$(norm "$k_cold_recap")" ] && \
   [ "$(norm "$a_warm_recap")" = "$(norm "$k_warm_recap")" ]; then
  if [ "$a_cold_rc" = "0" ] && [ "$a_warm_rc" != "0" ]; then
    echo "MATCH_BUT_ANSIBLE_NONIDEMPOTENT" > "$out/status"
  else
    echo "MATCH" > "$out/status"
  fi
else
  echo "DIVERGENT" > "$out/status"
fi

log "done: $(cat "$out/status")"
exit 0
