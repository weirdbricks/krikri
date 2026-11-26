# mjcramer.java: --check reports the converged shell profile as changed

- issue: #1851
- role: mjcramer.java (as pulled in by mjcramer.kafka and mjcramer.zookeeper)
- round dir: `/home/labros/git_work/krikri-role-tester/logs___1795686235/mjcramer_kafka`
- phase: check
- task: `mjcramer.java : configure | create shell profile`
  (`tasks/configure.yml:16-24`: one `template:` over `with_items:
  [java.sh, "java.cscd h"]`, `dest: /etc/profile.d/{{ item }}`, `mode: 600`)
- divergence: `ansible=[ok,ok] krikri=[changed,changed]`; the recap's
  `changed=0` vs `changed=1` is the same task
- round versions: krikri 0.9.3139 (debug), ansible-playbook [core 2.21.6]

## Why it diverged

`mode: 600` is an unquoted YAML int, so real's `basic.py` keeps 600 as an
INT and chmods **600 decimal** = `0o1130` (sticky bit set, owner `--x`).
The role's cold run leaves exactly that, its warm rerun (root, on the
bench host) reports ok, and the `--check` rerun must too: real compares
`stat.S_IMODE(os.lstat(dest).st_mode)` - the full permission word,
setuid/setgid/sticky included - against the requested mode, so
`0o1130 == 600` is a match.

krikri's check-mode comparison read the current side through Crystal's
`File::Info#permissions.value`, which carries only the `0o777` bits: it
saw `0o130` against a target of `0o1130` and called the same converged
profile `changed` on every check run. Same for the diff's `before` mode
and for the mode preserved onto a template's staging temp. The
plugins/file.cr comparison had already grown a raw-`lstat` helper for
this exact reason ("`permissions.value` strips the setuid/setgid/sticky
bits"); the shared copy/template attribute path had not.

## Corpus fit

`expected.out` is real ansible's transcript for one run, captured with
`bin/krikri-capture-case` (2.21.6). The playbook is the role's task
verbatim, preceded by one `check_mode: false` run of the same task so the
case starts from the converged state the round's check phase saw.

The failing task's own `mode: 600` reaches `0o1130`, which has **no read
bit at all**; as root on the bench host that is invisible (root reads it
anyway), but a non-root replay cannot read the converged file in either
engine, and both then report `changed` for the unreadable content instead
of ever reaching the mode comparison. `mode: "4755"` is the readable
spelling of the same defect - a numeric mode whose setuid bit the
comparison dropped - so this case pins the comparison itself.
