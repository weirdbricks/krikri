#!/usr/bin/env bash
# Output-parity harness: runs the same fixture playbook under
# ansible-playbook and krikri-playbook with identical arguments
# (`-i localhost, -c local`, stdin from /dev/null) and compares the
# captured RAW bytes of stdout and stderr separately, plus the exit
# codes. The goal is byte-for-byte console-output parity; any diff this
# script reports that is not masked below is a real formatting or
# behavioral divergence.
#
#   ./scripts/output_parity.sh [out-dir] [playbook.yml ...]
#
# Default out-dir: /tmp/krikri-output-parity. Default playbooks: a small
# set of testing/test-*.yml fixtures that run entirely on localhost with
# no network or root requirements (debug/command/set_fact/loop/include/
# roles/handlers).
#
# Each playbook runs twice per engine: once for real (in a fresh temp
# cwd) and once under --check. Every run gets its own temp dir per
# engine so the two engines never share writable state.
#
# Allowed substitutions policy: NONE by default. A mask entry may only
# be added for a substitution that is provably unavoidable (absolute
# paths in Ansible's `Origin:` lines, timestamps/durations), and
# each entry must carry a comment justifying why it cannot be matched
# byte-for-byte by both engines. The mask list currently contains ONE
# justified entry (the interpreter-discovery warning, below); nothing
# else may be masked.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KRIKRI="${KRIKRI_PLAYBOOK:-$REPO/bin/krikri-playbook}"
REAL="${REAL_ANSIBLE_PLAYBOOK:-/usr/bin/ansible-playbook}"

OUT_DIR="${1:-/tmp/krikri-output-parity}"
shift || true
playbooks=("$@")
if [ ${#playbooks[@]} -eq 0 ]; then
  playbooks=(
    "$REPO/testing/test-debug-quick.yml"
    "$REPO/testing/test-command-argv.yml"
    "$REPO/testing/test-set-fact-quick.yml"
    "$REPO/testing/test-changed-when-quick.yml"
    "$REPO/testing/test-loop-quick.yml"
    "$REPO/testing/test-gather-facts-false-quick.yml"
    "$REPO/testing/test-gather-facts-true-quick.yml"
    "$REPO/testing/test-meta-noop-quick.yml"
    "$REPO/testing/test-include-tasks-quick.yml"
    "$REPO/testing/test-roles-quick.yml"
    "$REPO/testing/test-block-notify-quick.yml"
  )
fi

# Provably-unavoidable masks - ONE justified entry:
# ansible-playbook emits the interpreter-discovery warning below on
# stderr for any run that executes a Python module under an auto*
# interpreter mode. Krikri has no Python interpreter to discover, so
# this line cannot be matched by design (emulating it would be false).
# The mask strips exactly that one line - hostname and interpreter path
# wildcarded - from stderr on both sides (a no-op for krikri, which
# never emits it). Nothing else may be masked.
# Second entry, same class: Ansible also attaches the discovered
# interpreter to a failed task's result, so its `fatal: ... FAILED! => {..}`
# JSON dump carries a lone `"ansible_facts": {"discovered_interpreter_python":
# "..."}, ` key. Krikri has no Python interpreter and can never emit it.
# Only that exact lone key is stripped; any other ansible_facts stays.
MASKS=(
  "/^\\[WARNING\\]: Host '[^']*' is using the discovered Python interpreter at '[^']*', but future installation of another Python interpreter could cause a different interpreter to be discovered\\. See .* for more information\\.$/d"
  "s/\"ansible_facts\": \\{\"discovered_interpreter_python\": \"[^\"]*\"\\}, //g"
  # Third entry: convert_bool's "Valid booleans include: ..." lists Python's
  # BOOLEANS set in per-process hash-randomized iteration order (two
  # ansible runs already disagree byte-for-byte); only the order is masked.
  "s/(Valid booleans include: )[^\"]*/\\1<BOOLEAN-SET-ORDER>/g"
  # Fourth/fifth entries: command/shell results carry the run's wall-clock
  # start/end timestamps and duration (delta), different on every execution by
  # construction - only the values are masked, the keys still must match.
  "s/\"delta\": \"[0-9]+:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?\"/\"delta\": \"<DELTA>\"/g"
  "s/\"(start|end)\": \"[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:.]+\"/\"\\1\": \"<TIMESTAMP>\"/g"
  # Sixth entry: tempfile's failure message quotes the name Python's
  # tempfile.mkstemp/mkdtemp would have picked - prefix, 8 random
  # characters (lowercase letters, digits, underscore) and suffix - and
  # those 8 characters are drawn at random per run on both engines, so
  # they can never match byte for byte. Only that run is masked: it is
  # anchored on the module's own default prefix `ansible.`, on exactly 8
  # characters of mkstemp's [a-z0-9_] class, and on the rest of the
  # single quoted path (the user's suffix) up to its closing quote, so a
  # different prefix, a shorter/longer name or any unrelated text is left
  # alone. A custom prefix is not masked - it is not random, so both
  # engines must reproduce it verbatim.
  "s/(ansible\\.)[a-z0-9_]{8}([^'\"]*)(')/\\1<RND>\\2\\3/g"
  # Sixth-and-a-half entry: a CHANGED copy:/template: result quotes the
  # STAGED SOURCE file's path under "src" - Ansible stages the
  # content under a random ansible-tmp-<epoch>-<pid>-<random>/.source.txt
  # path that is different on every run by construction, so only that
  # whole key/value pair is masked (krikri has no equivalent staged path
  # to emit). ansible-local-<pid><random> staged paths (the force=false
  # copy no-op's src echo) are the same class and covered too.
  "s/\"src\": \"[^\"]*ansible-(tmp|local)[^\"]*\", //g"
  "s/, \"src\": \"[^\"]*ansible-(tmp|local)[^\"]*\"//g"
  # Seventh entry: the same mkstemp name when the user gave a CUSTOM prefix
  # (the prefix and suffix are deterministic, only the 8 characters between
  # them are random). Anchored on an Errno message's single-quoted path.
  "s/(\\[Errno [0-9]+\\] [^:]+: '[^']*\/[^'\/]*)[a-z0-9_]{8}(([.]|[^a-z0-9_'\/])[^'\/]*)?'/\\1<RND>\\2'/g"
  # Eighth entry: copy:/template: backup_file names embed the creating
  # process's PID and the wall-clock second the backup was made at
  # (`<dest>.<pid>.<yyyy-mm-dd@hh:mm:ss>~`, ansible.module_utils.
  # files.backup_local) - both are different on every run by
  # construction (the two engines are separate processes executed a
  # moment apart). Only the pid/timestamp digits are masked; the dest
  # prefix and trailing ~ must still match byte for byte.
  "s/\\.([0-9]+)\\.([0-9]{4}-[0-9]{2}-[0-9]{2}@[0-9]{2}:[0-9]{2}:[0-9]{2})~/.<PID>.<BACKUP-TIME>~/g"
  # Ninth entry: a copy:/template: validate: failure's stderr quotes the
  # STAGED copy of the content the validator ran against - Ansible
  # stages under ~/.ansible/tmp/ansible-tmp-<random>/.source<suffix>,
  # krikri under /tmp/.krikri-playbook-<module>-<random>.tmp - both
  # per-run by construction. Both sides normalize to <STAGED> so the
  # validator's own message text still compares byte for byte.
  "s#/[^ \"]*/\\.ansible/tmp/ansible-tmp-[^ \"]*/\\.source(\\.[^ :\"]*)?#<STAGED>#g"
  "s#/tmp/\\.krikri-playbook-[a-z]+-[0-9a-f]+\\.tmp#<STAGED>#g"
  # Tenth/eleventh entries: stat/find results carry the file's inode
  # number and ctime - both are filesystem-state values that differ
  # whenever the two engines create the same file in sequence (each
  # engine's run starts by wiping and recreating the work dir, so each
  # engine stats ITS OWN creation). Not reproducible byte-for-byte by
  # any engine implementation; only the values are masked, the keys and
  # every other field must still match.
  "s/(\"ctime\": )[0-9]+\\.[0-9]+/\1<CTIME>/g"
  "s/(\"inode\": )[0-9]+/\1<INODE>/g"
  # Twelfth entry, same class: atime AND mtime. A stat/find result that
  # computes a checksum READS the file, and the kernel's relatime policy
  # updates atime on the first read after creation (a fresh file's atime
  # is its creation-era value, always older than its ctime) - so
  # whichever engine's process reads first leaves a different atime
  # behind for the other. mtime is the file's own creation/rewrite
  # wall-clock second, and each engine's run creates the work files
  # seconds apart by construction. Values masked, keys and everything
  # else compared.
  "s/(\"atime\": )[0-9]+\\.[0-9]+/\1<ATIME>/g"
  "s/(\"mtime\": )[0-9]+\\.[0-9]+/\1<MTIME>/g"
)

mask() {
  local src="$1" dst="$2"
  if [ "${#MASKS[@]}" -eq 0 ]; then
    cp "$src" "$dst"
    return
  fi
  # Only reached when MASKS is non-empty; each mask is a sed -E script,
  # passed as its own -e (a bare second script arg would be read as a file).
  local args=() m
  for m in "${MASKS[@]}"; do args+=(-e "$m"); done
  # Multi-line form of the same two interpreter-discovery artifacts, as they
  # appear inside pretty-printed registered results (`debug: var: r`): the
  # `ansible_facts.discovered_interpreter_python` block and the `warnings`
  # entry carrying the discovery warning. Same justification as entries 1-2;
  # krikri can never emit either.
  sed -E "${args[@]}" "$src" | perl -0pe '
    s/^[ ]*"ansible_facts": \{\n[ ]*"discovered_interpreter_python": "[^"]*"\n[ ]*\},\n//mg;
    # -vvv module-execution mechanics lines: real interpreter discovery,
    # local-connection setup, per-module EXEC/PUT shell commands (embedding
    # the per-run random ansible-tmp staging dirs, the user name and the
    # discovered Python path) and the "Using module file"/"Pipelining"
    # notices. Krikri has no Python interpreter, no module files and no
    # staged tmp dirs - architecturally impossible to emit, and different
    # on every real run by construction. Stripped from BOTH sides (a no-op
    # for krikri, which never emits them).
    s/^<[^>]*> (?:Attempting python interpreter discovery\.|ESTABLISH LOCAL CONNECTION|EXEC |PUT ).*\n//mg;
    s/^Using module file .*\n//mg;
    # Pretty-printed form of the staged-source path mask above: a copy:/
    # template: result quotes the STAGED SOURCE file path under "src" -
    # a random ansible-tmp-<epoch>-<pid>-<random>/.source.txt path,
    # different on every real run by construction (krikri has no
    # equivalent staged path to emit). Anchored on ansible-tmp so any
    # other "src" value keeps being compared byte-for-byte.
    s/^ *"src": "[^"]*ansible-(tmp|local)[^"]*",\n//mg;
    s/^Pipelining is enabled\.\n//mg;
    # Real copy:/template: (action-plugin) result dumps carry an
    # `invocation.module_args` block that embeds the per-run random staged
    # basename (`_original_basename: ".kghfc56x"`) and the staged
    # ansible-tmp-... src path - provably different on every real run by
    # construction - and the krikri action dispatch produces no module
    # invocation wire block for these results at all. Only invocation
    # blocks containing copy-action staged-file keys (or any embedded
    # random ansible-tmp/ansible-local staged path, as in template
    # check-mode invocations) are dropped,
    # from both sides (a no-op for krikri); every other module
    # invocation block keeps being compared byte-for-byte.
    s/^ {4}"invocation": \{\n((?: {8,}.*\n)*?) {4}\}(,?)\n/$1 =~ m{_original_basename|_diff_peek|ansible-tmp|ansible-local} ? "" : "    \"invocation\": {\n$1    }$2\n"/gme;
    # A dropped last-position block leaves the previous key trailing
    # comma dangling before the closing brace; valid pretty JSON never
    # contains ",\n}", so folding it back is unambiguous.
    s/,\n( *)\}/\n$1}/g;
    # include_role/import_role list several invalid options in Python set order,
    # random per real process (string hash randomization): sort the list on both
    # sides so only the order is normalized, never the membership.
    s/(Invalid options for [\w.]+: )([\w,]+)/$1.join(",", sort split(",", $2))/ge;
    # With several wrong-typed string options Ansible reports one of them chosen by
    # random Python set order (same playbook alternates tasks_from/vars_from).
    s/Expected a string for (?:defaults_from|handlers_from|tasks_from|vars_from) but got/Expected a string for <OPT> but got/g;
    s/,\n[ ]*"warnings": \[\n[ ]*"Host \x27[^\x27]*\x27 is using the discovered Python interpreter[^\n]*"\n[ ]*\]//g;
    s/^[ ]*"warnings": \[\n[ ]*"Host \x27[^\x27]*\x27 is using the discovered Python interpreter[^\n]*"\n[ ]*\],\n//mg;
  ' >"$dst"
}

run_engine() {
  # $1 = engine binary, $2 = playbook, $3 = out prefix, $4 = cwd,
  # $5... = extra args
  local bin="$1" pb="$2" prefix="$3" cwd="$4"
  shift 4
  # test-roles-quick.yml's copy dest is a FIXED /tmp path shared by both
  # engines' runs; whichever engine runs second sees the file the first
  # created and reports ok where the first reported changed - a pure
  # harness-ordering artifact, not an engine divergence. Reset it before
  # every single run so both engines always start from the same
  # host-state (the temp cwds already isolate everything else).
  rm -f /tmp/krikri-playbook-role-greeting.txt
  (
    cd "$cwd" || exit 99
    # A hung engine must never wedge the whole harness: 20s per run,
    # reported as its own result via rc=124 (never masked away).
    timeout 20 env -u ANSIBLE_GATHERING -u ANSIBLE_CACHE_PLUGIN -u ANSIBLE_CACHE_PLUGIN_CONNECTION \
      ANSIBLE_NOCOLOR=1 \
      "$bin" -i localhost, -c local "$@" "$pb" \
      </dev/null >"$prefix.stdout" 2>"$prefix.stderr"
    echo $? >"$prefix.rc"
  )
}

mkdir -p "$OUT_DIR"
identical=0
differing=0
differing_list=""

for pb in "${playbooks[@]}"; do
  # Resolve to an absolute path: both engines run with a temp cwd, so a
  # relative path would silently resolve to a missing file inside the
  # temp dir and produce a misleading identical "file not found" pair.
  pb="$(readlink -f "$pb")"
  pb_name="$(basename "$pb" .yml)"
  for mode in run check; do
    slug="${pb_name}__${mode}"
    base="$OUT_DIR/$slug"
    mkdir -p "$base"
    real_cwd="$(mktemp -d "$base/real.XXXXXX")"
    krikri_cwd="$(mktemp -d "$base/krikri.XXXXXX")"

    extra=()
    [ "$mode" = check ] && extra+=(--check)
    # Optional extra ansible-playbook args applied to BOTH engines
    # identically, e.g. PARITY_ARGS="-vv" to compare verbosity levels.
    # Word-split on purpose; a single level of quoting is enough here.
    if [ -n "${PARITY_ARGS:-}" ]; then
      # shellcheck disable=SC2206
      extra+=($PARITY_ARGS)
    fi

    run_engine "$REAL" "$pb" "$base/real" "$real_cwd" "${extra[@]+"${extra[@]}"}"
    run_engine "$KRIKRI" "$pb" "$base/krikri" "$krikri_cwd" "${extra[@]+"${extra[@]}"}"

    rc_real="$(cat "$base/real.rc")"
    rc_krikri="$(cat "$base/krikri.rc")"

    mask "$base/real.stdout" "$base/real.stdout.masked"
    mask "$base/krikri.stdout" "$base/krikri.stdout.masked"
    mask "$base/real.stderr" "$base/real.stderr.masked"
    mask "$base/krikri.stderr" "$base/krikri.stderr.masked"

    ok=1
    if ! diff -u "$base/real.stdout.masked" "$base/krikri.stdout.masked" >"$base/stdout.diff"; then
      ok=0
    fi
    if ! diff -u "$base/real.stderr.masked" "$base/krikri.stderr.masked" >"$base/stderr.diff"; then
      ok=0
    fi
    if [ "$rc_real" != "$rc_krikri" ]; then
      ok=0
      printf 'real rc=%s, krikri rc=%s\n' "$rc_real" "$rc_krikri" >"$base/rc.diff"
    fi

    if [ "$ok" = 1 ]; then
      identical=$((identical + 1))
      echo "IDENTICAL  $slug (rc=$rc_real)"
    else
      differing=$((differing + 1))
      differing_list="$differing_list $slug"
      echo "DIFFERENT  $slug (rc_real=$rc_real rc_krikri=$rc_krikri) - see $base/{stdout,stderr}.diff"
    fi

    rmdir "$real_cwd" "$krikri_cwd" 2>/dev/null
  done
done

echo
echo "Summary: $identical identical, $differing differing (of $((identical + differing)))"
[ "$differing" -gt 0 ] && { echo "Differing:$differing_list"; exit 1; }
exit 0
