# #1728 - ddilts.change_password: the raw apt task's output differs

- Issue: https://github.com/weirdbricks/krikri/issues/1728
- Role: `ddilts.change_password` (ubuntu host, round `logs___1795423891`)
- Class: output gap (the failing task's captured stdout/stderr)

**What diverged.** The role's first task is `raw: test -e /usr/bin/python ||
(apt -y update && apt install -y python-minimal)`. On the round's hosts both
engines failed it with rc 100 and `non-zero return code`, but the block's bytes
differed: 16573 B of stdout on krikri against 12151 B on real ansible. The
extra bytes are apt's live progress meter - `\r`-repainted status chunks
(`0% [Working]`, `0% [Waiting for headers]`, `Reading package lists... N%`)
plus the `Fetched ... in Ns` tail - which apt paints only because raw runs
under the ssh transport's pty, at whatever rate the target's own network makes
it repaint. Two real ansible runs, and two krikri runs, disagree there
identically: with both engines on one seeded package index and the same
duration, every deterministic line, the rc, stderr and the recap match. The
meter is recorded as host-timing noise in KNOWN_MISSING.md.

**The deterministic half this fixture pins.** The task itself runs in-process
against localhost, and that exposed a second divergence: this engine
manufactured a controlling terminal for a LOCAL connection, which real ansible
never does - its local module children carry exactly the terminal
ansible-playbook itself inherited. `apt`'s non-root path on this box goes
through Mint's wrapper, which calls `sudo`; on the manufactured tty sudo's
password prompt blocked forever, where real ansible answered "sudo: a terminal
is required" and failed at once (the replay hung until the playbook deadline).

**Fix.** `ControllingTty.ensure` now runs only for a remote dispatch, which
the executor marks with `__krikri_remote_tty`: real's ssh transport asks for a
pty whenever the command has nothing on its stdin (every raw task, and - with
ansible-core's default pipelining off - module dispatch too), and a local
connection gets none either way. `test/unit/controlling_tty_test.cr` pins both
sides of that split.

**Fixture.** The role's task verbatim, run against localhost, with `env.txt`
pinning the standard system PATH so the recorded failure is apt's own lock
error rather than a local `/usr/local/bin` wrapper's sudo text. `expected.out`
was captured with `bin/krikri-capture-case` from real ansible-core 2.21.6.
