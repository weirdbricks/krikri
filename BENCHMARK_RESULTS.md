# Benchmark Results: crystal-ansible vs real Ansible

**Date:** 2026-08-03
**Ansible version:** ansible-core 2.19.4 (Python)
**crystal-ansible version:** 0.9.5 (bug found during this benchmark; fixed in 0.9.6)

## Methodology

A single playbook (48 top-level tasks, 53 including block sub-tasks) was run
through both engines, 3 times consecutively per engine from a clean scratch
directory - run 1 exercises fresh creation, runs 2-3 exercise idempotency.
Both engines ran the same logical playbook against `localhost` over a local
connection (no SSH), reading/writing only under a throwaway scratch directory
(`/tmp/bench_ansible` / `/tmp/bench_crystal` - not part of this repo, not
committed).

The playbook deliberately covered a wide variety of task types and loop
constructs to be representative of a "real" playbook rather than a
micro-benchmark:

- **Modules:** `file`, `copy`, `lineinfile`, `template` (Jinja2 rendering),
  `debug`, `command`/`shell` (with `creates:` idempotency guards), `stat`,
  `find`, `archive`/`unarchive` (round trip), `cron` (`cron_file:`), `sysctl`
  (`sysctl_file:`), `mount` (`fstab:`)
- **Control flow:** `block:`/`rescue:`/`always:` (including a deliberately
  failing task), `when:` conditionals (both taken and skipped), `until:`/
  `retries:`/`delay:`
- **Loops:** `loop:` (literal list and variable-referenced), `with_items`,
  `with_dict`, `with_sequence`, `with_indexed_items`, `with_fileglob`,
  `with_nested`
- A full `gather_facts: true` pass at play start

All module invocations used explicit FQCNs (`ansible.builtin.*`,
`ansible.posix.*`, `community.general.archive`) so the exact same playbook
content is valid for both engines.

## Timing

| Run | Real Ansible | crystal-ansible |
|---|---|---|
| 1 (fresh) | 22.6s | 2.8s |
| 2 (idempotent rerun) | 22.4s | 3.0s |
| 3 (idempotent rerun) | 23.5s | 3.0s |
| **Average** | **~22.8s** | **~2.9s** |

**crystal-ansible is ~7.8x faster.** The gap is dominated by Ansible's
per-task Python process-spawn/module-transfer overhead - its timing is
essentially flat across all 3 runs regardless of whether anything actually
changed, whereas crystal-ansible is both consistently faster and slightly
more stable run-to-run.

## Idempotency

Both engines settle into a stable state by the second run:

- Real Ansible: `changed=33` -> `changed=5` -> `changed=5`
- crystal-ansible: `changed=56` -> `changed=6` -> `changed=6`

The residual non-zero `changed` count on both engines is expected, not a
bug: it comes from tasks that are inherently non-idempotent by design in
this playbook (a `file: state=touch` task that always bumps mtime, the
deliberately-failing block task re-running each time, and the archive
rebuild task).

The higher absolute `changed`/`ok` counts on crystal-ansible's first run
(56 vs 33) versus real Ansible are a secondary, more minor observation -
likely a difference in how per-loop-iteration results are attributed in
the play recap between the two engines - separate from the idempotency
finding below and not further root-caused as part of this pass.

## Bug found: `loop:`/`with_*:` silently break when given a variable reference

Diffing the two engines' final directory trees (which should be
structurally identical, modulo the different scratch-dir path embedded in
some file contents) turned up a real, previously-unknown correctness bug.

**Symptom:** any of `loop:`, `with_items:`, `with_dict:`, `with_nested:`,
or `with_indexed_items:` given as a Jinja **variable reference** instead of
a literal inline list/dict silently fails to loop at all:

```yaml
vars:
  colors: [red, green, blue]
tasks:
  - name: Copy a file per color
    ansible.builtin.copy:
      content: "color: {{ item }}\n"
      dest: "/tmp/color_{{ item }}.txt"
    loop: "{{ colors }}"          # <-- variable reference, not a literal list
```

Real Ansible produces `color_red.txt`, `color_green.txt`, `color_blue.txt`.
crystal-ansible instead produces a single `color_undefined.txt` - the loop
never registers, and the task runs exactly once with `item` unresolved.
The same failure mode was confirmed for `with_dict: "{{ some_dict }}"` and
`with_indexed_items: "{{ some_list }}"` in the benchmark playbook.

**Root cause** (`src/crystal_play/playbook_parser.cr`, around line 487):

```crystal
if loop_yaml = task_hash["loop"]?.try(&.as_a?)
  ...
elsif with_items = task_hash["with_items"]?.try(&.as_a?)
  ...
elsif with_dict = task_hash["with_dict"]?.try(&.as_h?)
  ...
elsif with_nested = task_hash["with_nested"]?.try(&.as_a?)
  ...
elsif with_indexed_items = task_hash["with_indexed_items"]?.try(&.as_a?)
  ...
```

`.as_a?`/`.as_h?` only succeed when the raw YAML value is **already** a
literal array/hash at parse time. A Jinja template string like
`"{{ colors }}"` is just a YAML scalar string until it's rendered, so
`.as_a?` returns `nil`, the whole `if/elsif` chain falls through with no
match, and the loop is silently never registered.

**Scope:** affects `loop:`, `with_items:`, `with_dict:`, `with_nested:`,
`with_indexed_items:`. **Not affected:** `with_sequence:` and
`with_fileglob:`, since both are always parsed as strings regardless (via
`safe_yaml_to_string` / direct `.as_s`), so they never hit this literal-vs-
template distinction.

**Severity:** high. `loop: "{{ some_var }}"` - looping over a variable
defined elsewhere rather than a list written inline - is one of the most
common patterns in real-world Ansible playbooks, arguably more common than
inline literal lists. This was not caught by any of the loop-related specs
or compat-harness playbooks added earlier in this project, all of which
happened to use literal inline lists as loop sources.

**Status:** fixed. `PlaybookParser` now falls back to stashing the raw
`{{ ... }}` template string (and which keyword it came from) on the `Task`
when none of the literal `.as_a?`/`.as_h?` checks match. `TaskExecutor`
resolves it at execution time, once the variable context exists, the same
way it already handled `with_fileglob:` (`src/crystal_play/playbook_parser.cr`
`find_loop_template`, `src/crystal_play/task_executor/executor.cr`
`resolve_loop_template`/`resolve_template_value`). Covered by new specs in
`spec/unit/playbook_parser_spec.cr` and an extended
`testing/test-loop-quick.yml` fixture exercised by
`spec/integration/cli_spec.cr`; full suite (411 examples) passes.

## stat/find: shelling out vs native syscalls

**Date:** 2026-08-03

Comparing real Ansible's own Python modules against crystal-ansible's
plugins (see the earlier comparison table in this conversation) turned
up two plugins - `stat` and `find` - that shell out to `stat`/`md5sum`/
`sha1sum`/`sha256sum`/`readlink`/`test -r`/`-w`/`-x`/`find` for
operations real Ansible does natively in Python (`os.stat()`, `hashlib`,
`os.path.realpath()`, `os.access()`, `os.walk()`) - not because Crystal
lacks the equivalent capability, but because these two plugins simply
never used it. Unlike the other CLI-shelling divergences found in that
comparison (`apt`/`dnf`/`apt_repository` need `python-apt`/`libdnf`
bindings Crystal has no equivalent of; `archive` needs a tar/zip-writing
library Crystal's stdlib doesn't ship; `firewalld` needs a D-Bus binding
Crystal has none of), Crystal's standard library already has everything
`stat`/`find` need built in: `LibC.stat`/`LibC.lstat`, `OpenSSL::Digest`,
`File.readlink`/`File.realpath`, `File::Info.readable?`/`writable?`/
`executable?`, `Dir.each_child`. So this was a self-contained fix, not a
missing-library problem.

### Methodology

Benchmarked the compiled plugin binaries directly (piping the same JSON
config `PluginManager` pipes over stdin - not a synthetic microbenchmark
of only the checksum path), before and after converting both plugins
from shell-command-based to native-syscall-based. `stat`: 200 single-file
invocations with `get_checksum: true` (sha1). `find`: 30 recursive scans
of a 320-file tree (300 top-level + 20 nested) with `get_checksum: true`.
Both engines produce byte-identical field output (verified against real
`ansible-playbook` on the same fixture files both before and after -
mode, size, checksum, permission bits, symlink resolution/`follow:`,
and `find`'s `matched` count all matched exactly).

### Results

| | Before (shelling out) | After (native) | Speedup |
|---|---|---|---|
| `stat` (mean per call) | 31.59 ms | 8.34 ms | **3.8x** |
| `find` (mean per 320-file scan) | 5,004.72 ms | 141.95 ms | **35.3x** |

`stat`'s old implementation spawned 5 subprocesses per call (`stat`,
three separate `test -r`/`-w`/`-x`, `sha1sum`); the new one makes zero.
`find`'s old implementation spawned one `find` subprocess for the
directory listing, then a `stat` **and** a `sha1sum` subprocess *per
matched file* - roughly 640 subprocess spawns for this 320-file fixture,
which is why `find` shows the much larger speedup: subprocess spawn
overhead (~5-8ms of fork/exec/dynamic-linking cost per call, all pure
overhead - not attributable to the actual file I/O all these commands
were doing anyway) dominates the shell-based version far more heavily
when it's paid per-file in a loop than when it's paid once per task.

### What changed

- New `BasePlugin#native_stat`/`#native_checksum`
  (`src/crystal_play/base_plugin.cr`) - a real `stat()`/`lstat()` syscall
  and a streaming `OpenSSL::Digest` file hash, callable from any plugin.
  Correct for both local *and* remote (SSH) targets without any
  connection-branching logic of their own: `PluginManager` already
  uploads and executes this same compiled plugin binary directly on the
  remote host for non-local connections, so "the filesystem this
  process can see" is the target host's filesystem either way - these
  two helpers don't need to know or care which case they're in.
- `src/crystal_play/plugin_helpers/stat_fields.cr` reworked from parsing
  `stat -c '%a|%s|...'` shell output into building the same hash shape
  directly from typed `LibC::Stat` fields (`StatFields.build`) - no
  string round-trip, and file-type/permission-bit derivation now mirrors
  what real Ansible's own `stat.py` does with `os.stat()`'s mode bits
  instead of parsing GNU `stat`'s human-readable type words.
- `plugins/stat.cr`: `stat`/`test -r`/`-w`/`-x`/`readlink`/`*sum` calls
  replaced by `native_stat`/`File::Info.readable?` etc./`File.readlink`/
  `native_checksum`.
- `plugins/find.cr`: the `find` shell command replaced by a small
  `Dir.each_child`-based recursive walker (`list_entries`/`walk`,
  matching real `find -mindepth 1 -maxdepth N`'s own depth numbering and
  its default behavior of not descending into symlinked directories);
  the per-entry `stat`/`readlink`/`*sum` calls replaced the same way as
  `stat.cr`.
- Both plugins' full existing test suites (`spec/unit/stat_fields_spec.cr`,
  `spec/integration/stat_spec.cr`, `spec/integration/find_spec.cr`)
  pass unmodified in behavior (the unit spec was rewritten to exercise
  the new typed `.build` API instead of parsing synthetic `stat -c`
  strings, but asserts the identical output shape). Full suite (495
  examples) passes.

## archive: shelling out vs native tar/zip writing

**Date:** 2026-08-03

`archive` was the other CLI-shelling plugin flagged in the comparison
table, marked at the time as needing "a tar/zip-writing library Crystal's
stdlib doesn't ship." That turned out to be half true: Crystal's stdlib
ships a full native `Compress::Zip` reader/writer, and `naqvis/crystar`
(already a transitive dependency via `docr`) provides a pure-Crystal tar
reader/writer. `bz2`/`xz` still have no native Crystal equivalent, so
`archive.cr` still shells to `tar`/`bzip2`/`xz` for those two formats
only; `tar`, `gz`, and `zip` are now fully native.

### Methodology

Two comparisons, because the first one turned out to be measuring the
wrong thing:

1. **vs. shelling to the real `tar`/`gzip`/`zip` CLIs** (crystal-ansible's
   own prior implementation) - a Crystal benchmark harness piping the
   same JSON config over stdin to the compiled plugin binary, timed with
   `Time.instant`, at two tree sizes (320 files, 2000 files), 10-20
   iterations each.
2. **vs. what real Ansible's `archive` module actually does** - it turns
   out `community.general.archive` never shells out either; it builds
   archives with Python's `tarfile`/`zipfile` stdlib modules directly
   (confirmed by reading its source). Python's `tarfile` is pure Python,
   not a C-accelerated module, so comparison (1) - our native Crystal vs.
   optimized C `tar`/`gzip` binaries - was never the comparison that
   matters. Comparison (2) benchmarks the actual target: real Ansible's
   own `tarfile`-based implementation, building the same 2000-file tree
   with Python 3.13's `tarfile.open(..., "w")` / `"w:gz"`, 10 iterations.

### Results

**(1) vs. shell `tar`/`gzip`/`zip` CLIs:**

| format | 320 files | 2000 files |
|---|---|---|
| tar | 34.6ms &rarr; 25.8ms (**1.3x faster**) | 129.3ms &rarr; 259.0ms (**2.0x slower**) |
| gz | 48.1ms &rarr; 34.8ms (**1.4x faster**) | 136.1ms &rarr; 176.0ms (**1.3x slower**) |
| zip | 44.0ms &rarr; 27.6ms (**1.6x faster**) | 239.9ms &rarr; 146.5ms (**1.6x faster**) |

zip wins outright at every scale. tar/gz win at small scale (avoiding
subprocess spawn overhead - a ~10-15ms fixed cost - dominates) but lose
at 2000 files: `crystar`'s per-entry write path (stat + header struct +
whole-file read into memory) and Crystal's pure-Crystal `Compress::Gzip`
add up to more per-file overhead than GNU `tar`/`gzip`'s highly optimized
C I/O loop, which has next to nothing to do per file for uncompressed
tar. Two rounds of optimization (caching `System::User`/`System::Group`
name lookups per uid/gid instead of per file; caching `File::Info` so
`collect_members`'s walk and header-building don't each stat the same
path) narrowed but did not close this gap.

**(2) vs. real Ansible's own `tarfile`-based implementation, 2000 files:**

| format | shell `tar`/`gzip` (not what Ansible does) | crystal-ansible (native) | real Ansible (Python `tarfile`) |
|---|---|---|---|
| tar | 129.3ms | 259.0ms | **347.7ms** |
| tar.gz | 136.1ms | 176.0ms | **475.4ms** |

Against the thing crystal-ansible is actually trying to beat, native
wins clearly: **1.3x faster than real Ansible for tar, 2.7x faster for
gz**. The comparison-(1) "regression" was an artifact of benchmarking
against optimized C that real Ansible doesn't use either - Python's
`tarfile`, like `crystar`, pays per-entry object/dict overhead that GNU
`tar`'s C loop doesn't, and Python's interpreter overhead on top of that
makes it slower again than Crystal's compiled native path.

### What changed

- `plugins/archive.cr`: `expand_paths` (native `Dir.glob`/`File.exists?`/
  `File.symlink?`), `collect_members`/`walk` (native `Dir.each_child`
  recursion, replacing shelled `find`), `build_zip` (native
  `Compress::Zip::Writer`, including `zip.add_dir` for explicit directory
  entries to match real `zip`'s behavior), `build_tar`/`write_tar_entries`
  (native `Crystar::Writer`, gzip-wrapped via `Compress::Gzip::Writer` for
  `format: gz`), `signature`/`*_signature` methods (native reading via
  `Compress::Gzip::Reader`/`Compress::Zip::Reader`/`Crystar::Reader` for
  gz/zip/tar signature checks, `shell_tar_signature` kept for bz2/xz
  only), `remove_sources` (native `FileUtils.rm_rf`),
  `apply_dest_attributes` (native `File.chown`/`File.chmod` via
  `System::User`/`System::Group` name resolution), `dest_stat_fields`
  (now reuses `BasePlugin#native_stat`). `build_archive_via_shell`
  remains for `bz2`/`xz` only, which have no native Crystal library.
- New `crystar` dependency in `shard.yml` (`github: naqvis/crystar`) -
  already present transitively via `docr`, now a direct dependency.
- Full integration/unit suite for archive/unarchive
  (`spec/integration/archive_spec.cr`,
  `spec/integration/unarchive_spec.cr`, `spec/unit/archive_paths_spec.cr`
  - 29 examples) passes unmodified in behavior.
