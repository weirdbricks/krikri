# fNxONE.baseline: a failed `file: state=touch` leaves its created file behind

- issue: #1870
- role: fNxONE.baseline (ubuntu)
- round dir: `/home/labros/git_work/krikri-role-tester/logs___1795714389/fNxONE_baseline`
- phase: check
- task: `fNxONE.baseline : Criando o arquivo drift para o serviço NTP`
  (`tasks/main.yml:45-51`: `file: path=/etc/drift state=touch owner=ntp
  group=ntp mode=0640`)
- divergence: `ansible=changed krikri=fatal`; the play aborted at that task
  (recap `failed=0` vs `failed=1`, `ok=11` vs `ok=5`)
- round versions: krikri 0.9.3157 (debug), ansible-playbook [core 2.21.6]

## Why it diverged

The role's `ntp` user is only created by a later step, so the touch's
`owner:`/`group:` lookup fails on a fresh host. Real ansible still creates the
file first and only then fails, but `execute_touch` unwinds that failure by
removing the file it created (`if prev_state == 'absent': os.remove(b_path)`),
leaving nothing behind.

krikri created the file and left it in place. On the round's shared bench host
the following `--check` run therefore saw `/etc/drift` as an existing file, and
a check-mode touch of an EXISTING path does perform the owner lookup (real
2.21.6 does too, `check_file_absent_if_check_mode` only skips paths that do not
exist), so krikri failed the check run where real ansible - seeing the path
absent again - returned changed:true before ever resolving `ntp`.

## Corpus fit

`expected.out` is real ansible's transcript for the case's own `--check` run,
captured with `bin/krikri-capture-case` (2.21.6). The playbook is the role's
task verbatim (only the path is adapted to the scratch tree), preceded by one
`check_mode: false` run of the same task so the case starts from exactly the
state the round's check phase saw: whatever a failed real touch leaves behind.
`ignore_errors` keeps the play going after that expected failure.
