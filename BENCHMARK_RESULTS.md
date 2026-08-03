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

## archive follow-up: xz converted to native too

**Date:** 2026-08-03

The original archive writeup above said "bz2/xz still have no native
Crystal equivalent." That was checked again more carefully by searching
for shards rather than assuming: bz2 genuinely has nothing usable - the
one hit, `jhbadger/Bzip`, isn't a real implementation at all, it's a
353-byte wrapper that shells out to `bzcat` internally, is read-only
(no writer), and hasn't been touched since 2017. xz is different:
`naqvis/xz.cr` (same author as `crystar`) is a real `liblzma` C binding
with both a reader and a writer, actively maintained (pushed
2026-03-02). Added as a new direct dependency and converted `format: xz`
from shelling to `tar`/`xz` to native `Compress::XZ::Writer`/`Reader`
wrapping the same `Crystar::Writer`/`Reader` tar path already used for
`gz`. `bz2` remains the sole shell-based format now, for a genuine
missing-library reason.

Requires `liblzma-dev` at build time (the shard falls back to `-llzma`
if `pkg-config liblzma` isn't found) - same pattern as this codebase's
existing `OpenSSL::Digest` usage needing `libssl-dev`.

### Results

Unlike `gz` (where Crystal's `Compress::Gzip` is a pure-Crystal
reimplementation that loses to real `gzip`'s C code at scale), `xz.cr`
binds directly to the same optimized `liblzma` C library the real `xz`
CLI uses, so it doesn't hit that scaling problem - native wins at both
tree sizes tested:

| files | shell (`tar` + `xz`) | native | speedup |
|---|---|---|---|
| 320 | 67.4ms | 53.2ms | **1.27x** |
| 2000 | 297.5ms | 277.9ms | **1.07x** |

Correctness verified both directions against the real `tar`/`xz` CLIs:
a native single-file `.xz` decompresses correctly with real `xz -dc`; a
native `tar.xz` directory archive lists and extracts correctly with
real `tar tvf`/`tar xf -O`; an idempotent rerun against crystal-ansible's
own previous output correctly reports `changed: false`; and reading a
pre-existing `tar.xz` built by the real `tar`/`xz` CLIs (simulating an
upgrade from the old shell-based implementation) doesn't error. Full
archive/unarchive suite (29 examples) and full project suite (495
examples) pass.

## archive follow-up 2: bz2 converted too, via a new shard written for this project

**Date:** 2026-08-03

The `bz2` search that came up empty for the earlier archive work was
checked again, more thoroughly: the one hit, `jhbadger/Bzip`, isn't a
real bzip2 implementation - it's a 353-byte wrapper that shells to
`bzcat` internally, is read-only (no writer), and hasn't been touched
since 2017. Genuinely nothing usable existed. `libbz2` itself, though,
is a small, extremely stable C library (unchanged since 1996 - the same
one Python's own `bz2` module and the `bzip2` CLI bind to), so rather
than accept `bz2` as a permanent shell-out, a real binding was written:
[`weirdbricks/bz2.cr`](https://github.com/weirdbricks/bz2.cr), a new
public shard modeled directly on `naqvis/xz.cr`'s own `Writer`/`Reader`
design (bzlib's `bz_stream` C API is close enough in shape to lzma's
`lzma_stream` that most of xz.cr's structure - the buffered-peek
decompression loop especially - translated over with only small
adjustments; bzlib's simpler action/return-code model needed no filter
chains or presets, just a block size and work factor). Requires
`libbz2-dev` at build time, same pattern as the `liblzma-dev`/`libssl-dev`
requirements already in place for `xz`/`OpenSSL::Digest`.

Converted `format: bz2` from shelling to `tar`/`bzip2` to native
`Compress::BZ2::Writer`/`Reader`, wrapping the same `Crystar::Writer`/
`Reader` tar path already used for `gz`/`xz`. No archive format shells
out anymore.

### Results

Like `xz.cr`, `bz2.cr` binds a real optimized C library rather than
reimplementing the algorithm in pure Crystal, so it doesn't hit the
`gz`-style scaling problem - native wins at both benchmarked scales:

| files | shell (`tar` + `bzip2`) | native | speedup |
|---|---|---|---|
| 320 | 37.3ms | 23.4ms | **1.59x** |
| 2000 | 139.8ms | 121.6ms | **1.15x** |

Correctness verified both directions against the real `tar`/`bzip2`
CLIs, the same way `xz` was: a native single-file `.bz2` decompresses
correctly with real `bzip2 -dc`; a native `tar.bz2` lists and extracts
correctly with real `tar tvf`/`tar xf -O`; an idempotent rerun reports
`changed: false`; reading a pre-existing `tar.bz2` built by the real
CLIs doesn't error. `bz2.cr` itself also has its own spec suite (8
examples) verifying round-trips at various sizes, cross-compatibility
with the real `bzip2` binary in both directions, and error handling on
corrupt input. Full crystal-ansible archive/unarchive suite (29
examples) and full project suite (495 examples) pass.

## file: shelling out vs native filesystem calls

**Date:** 2026-08-03

A broader survey of every plugin's `remote_exec` call sites (looking for
more `stat`/`find`-style oversights - shelling for something Crystal's
stdlib already does natively, as opposed to a genuine missing-binding
gap like `apt`/`dnf`/`firewalld`) turned up `file.cr` as the single
biggest offender: 27 separate `remote_exec` calls across its six states
(`directory`/`file`/`link`/`hard`/`touch`/`absent`), every one of them
`mkdir -p`/`test -f`/`test -e`/`readlink`/`rm -f`/`rm -rf`/`ln -s`/`ln`/
`touch` (all four variants)/`stat -c '%U'`/`'%G'`/`'%a'`/`chown`/
`chgrp`/`chmod` - all with direct Crystal stdlib equivalents
(`Dir.mkdir_p`, `File.exists?`/`File.file?`, `File.readlink`,
`File.delete?`/`FileUtils.rm_rf`, `File.symlink`/`File.link`,
`File.utime`, a raw `LibC.lstat` for reading current mode/owner/group,
`File.chown`/`File.chmod` for numeric mode).

One narrow, genuine gap remains: *symbolic* mode strings (`u+x`,
`go-w`, etc.) still shell to the real `chmod` binary to apply -
reimplementing chmod(1)'s symbolic-mode grammar (scopes, `+`/`-`/`=`,
`X`, comma-clauses) correctly is real, separate scope, and this was
already the weakest-supported path before conversion (the pre-existing
code could only detect symbolic-mode changes via a string comparison
that's essentially always "changed", never fully parsed it either).
Numeric mode - the overwhelming majority of real playbooks - is fully
native.

A correctness subtlety worth calling out: GNU `stat -c '...'` (without
`-L`) does *not* follow symlinks, while `test -e`/`test -f` *do* - the
original shell implementation relied on this same split (existence
checks follow, attribute checks don't), and the native conversion
replicates it exactly (`File.exists?`/`File.file?` follow;
`LibC.lstat` doesn't) rather than "fixing" it into single consistent
behavior, since the goal was a mechanical shell->native conversion, not
a behavior change. One actual pre-existing bug was *found* (not
introduced) during this work and deliberately left alone for the same
reason: `state: file`'s `modification_time`/`access_time` params only
take effect when `owner`/`group`/`mode` also change, because
`update_times` is only called inside the same `if changed` block that
guards `apply_file_attributes` - present in the original shell version
too, unrelated to this conversion, and out of scope for it.

### Results

No dedicated spec suite existed for `file.cr` before this (the plugin
was previously only exercised indirectly) - `spec/integration/file_spec.cr`
(21 examples, new) now covers all six states, idempotency, check mode,
force-overwrite, symbolic mode, setuid/setgid/sticky bit preservation,
and `recurse:`.

Benchmarked each state's single-invocation cost (the way `file:` is
actually used in real playbooks - once per task, often inside a loop
over many paths - rather than one big batch): 200 iterations per
scenario, comparing the compiled plugin binary before/after.

| scenario | before (shell) | after (native) | speedup |
|---|---|---|---|
| `state: directory` (create) | 7.02ms | 1.85ms | **3.79x** |
| `state: directory` (idempotent) | 4.65ms | 1.85ms | **2.51x** |
| `state: touch` (create) | 6.87ms | 1.91ms | **3.60x** |
| `state: file` (mode, idempotent) | 6.62ms | 1.90ms | **3.49x** |
| `state: link` (create) | 8.79ms | 1.81ms | **4.85x** |
| `state: absent` (remove) | 6.37ms | 1.79ms | **3.55x** |

Consistent with `stat`/`find`: the win scales with how many
`remote_exec` calls a single invocation used to make (each one spawning
a `/bin/bash -c '...'` subprocess, even for local execution - the
`LocalExecutor` used by `remote_exec` shells too, it just skips SSH),
so `state: link`'s three shelled-out checks per call show the largest
speedup. Full project suite (516 examples) passes.

## apt_repository / yum_repository: shelling out vs native file editing

**Date:** 2026-08-03

Next in the shell-out survey after `file.cr`: `apt_repository.cr` and
`yum_repository.cr` both turned out to be entirely file-editing plugins
- neither one actually calls `apt-get`/`dnf`/`yum` for anything (that's
`apt.cr`/`dnf.cr`/`package.cr`'s job). `apt_repository` was shelling to
`ls`/`grep -qxF`/`grep -vxF`/`grep -c .`/`echo >>`/`mkdir -p`/`chmod`;
`yum_repository` to `cat`/`rm -f`/`mkdir -p`/`chown`/`chgrp`/`chmod` -
all replaced with `Dir.glob`/`File.each_line`/`File.read_lines`/
`File.write`/`File.open(path, "a")`/`File.read`/`File.delete?`/
`Dir.mkdir_p`. A new shared `BasePlugin#apply_owner_group_mode` helper
(native `File.chown`/`File.chmod` for numeric mode, falling back to
shelling `chmod` only for symbolic mode strings - the same trade-off
`file.cr` already made) replaces the duplicated chown/chgrp/chmod logic
both plugins had. `apt_repository`'s one remaining shell call,
`apt-get update` after a change, is a genuine gap (same category as
`apt.cr` itself), not an oversight.

Unlike `unarchive` (considered as the next target and explicitly passed
over - real Ansible's own `unarchive` module shells to `tar --diff`/
`--extract`/`zipinfo` too, so converting it natively would mean doing
*more* than even real Ansible attempts, with real fidelity risk on
edge cases like hardlinks/sparse files/exact permission preservation),
these two are unambiguous oversights: real Ansible's own
`apt_repository`/`yum_repository` modules just read/write plain text
files with Python's own file I/O, no subprocess involved for the
file-editing itself either.

### Correctness

`apt_repository.cr` writes to real `/etc/apt/`, so its write path
wasn't exercised directly (matching the existing spec suite's own
convention of check-mode-only tests for this plugin) - the extracted
line-removal logic (the specific case a code comment already flagged:
removing the only line in a file, where `grep -v` exits 1 and a naive
`grep ... && mv` would silently skip the mv) was verified in isolation
against a throwaway file instead, confirming the native version handles
it correctly with no reliance on any command's exit code.
`yum_repository.cr` accepts a `reposdir:` override, so its full add/
remove/idempotent-rerun cycle was exercised directly against a
throwaway directory. Existing spec suites (`spec/integration/
apt_repository_spec.cr`, `spec/integration/yum_repository_spec.cr`,
`spec/unit/apt_repository_line_spec.cr` - 22 examples total) pass
unmodified in behavior.

### Results

| scenario | before (shell) | after (native) | speedup |
|---|---|---|---|
| `apt_repository` check_mode (read-only idempotency check) | 17.27ms | 3.30ms | **5.23x** |
| `yum_repository` add (new file) | 19.77ms | 3.60ms | **5.50x** |
| `yum_repository` idempotent rerun | 9.45ms | 3.54ms | **2.67x** |

Full project suite (516 examples) passes.

## authorized_key: shelling out vs native home-directory lookup

**Date:** 2026-08-03

Next in the shell-out survey: `authorized_key.cr` only had one shell call
left, `getent passwd <user>` in `home_directory` (resolving `user:` to a
home path so it can build the default `~/.ssh/authorized_keys`). Replaced
with a native `System::User.find_by?(name: user)#home_directory` lookup
(Crystal's `System::User` reads the same NSS source `getent` does, so
coverage is unchanged - including NSS-backed users like LDAP/SSSD).
Falls back to the conventional `/home/<user>` (or `/root` for root) when
the user isn't in the local passwd DB, matching the old code exactly. No
other `remote_exec` calls remain in the plugin; it is now fully native.

### Correctness

Existing spec suite (`spec/integration/authorized_key_spec.cr` - 7
examples) passes unmodified, including the `user: root` case that
exercises `home_directory` directly (asserting the resolved path is
`/root/.ssh/authorized_keys` - root's NSS home is `/root`, so the native
and fallback paths agree there). All other specs use an explicit
`path:` and never hit the shell-out, so they can't distinguish before
from after; the `user:` case is the one that now exercises native lookup.

### Results

Timing the `home_directory` primitive in isolation (200 iterations each):
`getent passwd root` shell-out vs `System::User.find_by?`.

| approach | time per call |
|---|---|
| `getent passwd root` (subprocess) | 3.507ms |
| native `System::User` lookup | 0.014ms |

**~255x speedup** on the lookup itself. The end-to-end run also drops a
fork/exec off the `path` resolution path (now one native call instead of
a `/bin/bash -c 'getent ...'` subprocess), so a task that previously
spawned a subprocess just to find the home directory now resolves it
in-process.

Full project suite (516 examples) passes.
