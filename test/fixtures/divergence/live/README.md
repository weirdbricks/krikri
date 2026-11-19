# Live-only divergence repros

Repros that cannot run in the fast in-process suite, because proving the
divergence requires real package/service/crontab/pip mutation (or a real root
filesystem). They are replayed in a **real-host round** (a
`krikri-role-tester` host pair, or `scripts/output_parity.sh` against a
throwaway container), never from `scripts/minitest.sh`.

Not automated, on purpose: every one of these would either mutate the
developer's machine (`apt`/`dpkg`, `/etc/profile`, `/etc/apt`, the RPM
database, systemd units, crontab) or needs a live service (MySQL, sshd,
glusterd) the suite has no way to provide. The corpus under
`test/fixtures/divergence/` covers every case that can be expressed with
read-only modules; a fix that only has a live repro should say so in its
commit message (AGENTS.md's fix phase).

Format: `<issue>\t<role or playbook>\t<why it cannot run in-process>`.
Keep the one-line reason specific enough that the next round knows what host
state it must provision.

Replay procedure for a round:

1. Provision the host the reason implies (packages present/absent, service
   running, `~/.my.cnf` present, ...).
2. Run the role with real `ansible-playbook` 2.21.6 and with
   `bin/krikri-playbook --release`, saving each transcript.
3. Compare byte for byte (modulo `Compare::MASKS`: PIDs, timestamps, Python
   set order - see KNOWN_MISSING.md's unmatchable list).
4. Once the shape is reproducible with read-only modules, replace the entry
   with a `test/fixtures/divergence/<issue>-<slug>/` case instead.
