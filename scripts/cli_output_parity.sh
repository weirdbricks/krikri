#!/usr/bin/env bash
# CLI-mode output-parity harness: complements output_parity.sh, which only
# exercises full playbook EXECUTION (run/check). This script compares the
# NON-EXECUTION command-line modes and common flags - --list-tasks,
# --list-tags, --list-hosts, --syntax-check, -t/--skip-tags, -l/--limit,
# --start-at-task, --forks, -e variants, missing playbook, unknown option,
# --version, --help - against real ansible-playbook, using the fixture
# corpus under /tmp/kpg-x/cli.
#
#   ./scripts/cli_output_parity.sh [out-dir] [case-name ...]
#
# Default out-dir: /tmp/kpg-x/cli-out. Each case runs both engines in their
# own fresh temp cwd and compares RAW stdout, RAW stderr and the exit code
# byte-for-byte. Cases marked head-compare only compare the first N lines
# of stdout (justification inline, per case). No masks otherwise.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KRIKRI="${KRIKRI_PLAYBOOK:-$REPO/bin/krikri-playbook}"
REAL="${REAL_ANSIBLE_PLAYBOOK:-/usr/bin/ansible-playbook}"
CORPUS="${CLI_PARITY_CORPUS:-/tmp/kpg-x/cli}"

OUT_DIR="${1:-/tmp/kpg-x/cli-out}"
shift || true
only_cases=("$@")

# head_lines: when >0, stdout comparison uses only the first N lines
# (--help: the full usage text documents each engine's own option set and
# can never match byte-for-byte by design; the first lines still pin the
# shape of the output). stderr and rc always compare in full.
run_case() {
  local name="$1" head_lines="$2"
  shift 2
  local -a args=("$@")
  if [ ${#only_cases[@]} -gt 0 ]; then
    local c keep=0
    for c in "${only_cases[@]}"; do [ "$c" = "$name" ] && keep=1; done
    [ "$keep" = 1 ] || return 0
  fi
  local base="$OUT_DIR/$name"
  mkdir -p "$base"
  local real_cwd krikri_cwd
  real_cwd="$(mktemp -d "$base/real.XXXXXX")"
  krikri_cwd="$(mktemp -d "$base/krikri.XXXXXX")"

  local bin cwd prefix
  for bin in "$REAL" "$KRIKRI"; do
    [ "$bin" = "$REAL" ] && cwd="$real_cwd" || cwd="$krikri_cwd"
    [ "$bin" = "$REAL" ] && prefix="$base/real" || prefix="$base/krikri"
    (
      cd "$cwd" || exit 99
      timeout 20 env -u ANSIBLE_GATHERING -u ANSIBLE_CACHE_PLUGIN -u ANSIBLE_CACHE_PLUGIN_CONNECTION \
        ANSIBLE_NOCOLOR=1 "$bin" "${args[@]}" </dev/null >"$prefix.stdout" 2>"$prefix.stderr"
      echo $? >"$prefix.rc"
    )
  done

  local ok=1
  if [ "$head_lines" -gt 0 ]; then
    head -n "$head_lines" "$base/real.stdout" >"$base/real.stdout.cmp"
    head -n "$head_lines" "$base/krikri.stdout" >"$base/krikri.stdout.cmp"
  else
    cp "$base/real.stdout" "$base/real.stdout.cmp"
    cp "$base/krikri.stdout" "$base/krikri.stdout.cmp"
  fi
  if ! diff -u "$base/real.stdout.cmp" "$base/krikri.stdout.cmp" >"$base/stdout.diff"; then ok=0; fi
  if ! diff -u "$base/real.stderr" "$base/krikri.stderr" >"$base/stderr.diff"; then ok=0; fi
  if [ "$(cat "$base/real.rc")" != "$(cat "$base/krikri.rc")" ]; then
    ok=0
    printf 'real rc=%s, krikri rc=%s\n' "$(cat "$base/real.rc")" "$(cat "$base/krikri.rc")" >"$base/rc.diff"
  fi

  if [ "$ok" = 1 ]; then
    echo "IDENTICAL  $name (rc=$(cat "$base/real.rc"))"
  else
    echo "DIFFERENT  $name (rc_real=$(cat "$base/real.rc") rc_krikri=$(cat "$base/krikri.rc")) - see $base/{stdout,stderr}.diff"
  fi
  rmdir "$real_cwd" "$krikri_cwd" 2>/dev/null
  if [ ${#only_cases[@]} -gt 0 ]; then return 0; fi
  if [ "$ok" = 1 ]; then return 0; else return 1; fi
}

fail=0
run_case list-tasks            0 --list-tasks "$CORPUS/multi_play_tags.yml" || fail=1
run_case list-tags             0 --list-tags "$CORPUS/multi_play_tags.yml" || fail=1
run_case list-hosts            0 --list-hosts -i "$CORPUS/inventory.ini" "$CORPUS/host_pattern.yml" || fail=1
run_case list-hosts-all        0 --list-hosts -i "$CORPUS/inventory.ini" "$CORPUS/with_roles.yml" || fail=1
run_case syntax-check-ok       0 --syntax-check -i "$CORPUS/inventory.ini" "$CORPUS/blocks_handlers.yml" || fail=1
run_case syntax-check-yaml-err 0 --syntax-check "$CORPUS/err_yaml.yml" || fail=1
run_case syntax-check-kw-err   0 --syntax-check -i "$CORPUS/inventory.ini" "$CORPUS/err_keyword.yml" || fail=1
run_case check-mode            0 --check -i "$CORPUS/inventory.ini" "$CORPUS/changing.yml" || fail=1
run_case diff-mode             0 --check --diff -i "$CORPUS/inventory.ini" "$CORPUS/changing.yml" || fail=1
run_case diff-mode-run         0 --diff -i "$CORPUS/inventory.ini" "$CORPUS/changing.yml" || fail=1
run_case tags                  0 -t deploy -i "$CORPUS/inventory.ini" "$CORPUS/multi_play_tags.yml" || fail=1
run_case tags-long             0 --tags imported_tag -i "$CORPUS/inventory.ini" "$CORPUS/import_tasks.yml" || fail=1
run_case skip-tags             0 --skip-tags deploy -i "$CORPUS/inventory.ini" "$CORPUS/multi_play_tags.yml" || fail=1
run_case limit                 0 -l web1 -i "$CORPUS/inventory.ini" "$CORPUS/host_pattern.yml" || fail=1
run_case limit-no-match        0 -l nosuchhost -i "$CORPUS/inventory.ini" "$CORPUS/host_pattern.yml" || fail=1
run_case start-at-task         0 --start-at-task 't2' -i "$CORPUS/inventory.ini" "$CORPUS/multi_play_tags.yml" || fail=1
run_case forks                 0 --forks 3 -i "$CORPUS/inventory.ini" "$CORPUS/host_pattern.yml" || fail=1
run_case extra-kv              0 -e extra_val=from_cli -i "$CORPUS/inventory.ini" "$CORPUS/vars_extra.yml" || fail=1
run_case extra-file            0 -e @"$CORPUS/extra.yml" -i "$CORPUS/inventory.ini" "$CORPUS/vars_extra.yml" || fail=1
run_case extra-json            0 -e '{"extra_val":"from_json"}' -i "$CORPUS/inventory.ini" "$CORPUS/vars_extra.yml" || fail=1
run_case extra-malformed       0 -e '{bad' -i "$CORPUS/inventory.ini" "$CORPUS/vars_extra.yml" || fail=1
run_case missing-playbook      0 "$CORPUS/no_such_playbook.yml" || fail=1
run_case unknown-option        0 --frobnicate "$CORPUS/multi_play_tags.yml" || fail=1
run_case version               0 --version || fail=1
run_case help                  8 --help || fail=1

echo
if [ ${#only_cases[@]} -eq 0 ]; then
  echo "Done (fail=$fail)"
fi
exit "$fail"
