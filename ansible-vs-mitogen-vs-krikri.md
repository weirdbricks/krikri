# ansible vs. Mitogen vs. krikri-playbook

A 3-way timing comparison: real `ansible-playbook`, `ansible-playbook` with
the [Mitogen](https://mitogen.networkgenomics.com/) strategy plugin
(`strategy = mitogen_linear`), and `krikri-playbook`, run against the same
playbooks on matched hosts.

## Methodology

- 140 roles randomly sampled (fixed seed `20260901`, with `20260901424` /
  `2026090142489` for replacement draws when a sampled role turned out to be
  a dead Galaxy listing) from `ROLES_TESTED.md`'s "✅ Clean" list, so the
  sample isn't hand-picked.
- Each role ran on a fresh 3-host triplet (Atlantic.net `G3.2GB`, Ubuntu
  24.04): one host for real `ansible-playbook`, one for
  `ansible-playbook` + Mitogen, one for `krikri-playbook`, each isolated so
  no engine's run could affect another's timing.
- Each engine ran the role playbook twice per triplet: a **cold** run
  (fresh host) and a **warm** re-run (idempotent second pass), timed with
  `/usr/bin/time -v`.
- 126 roles ended up completing successfully on all three engines across
  the sampling rounds (a handful of others hit provisioning failures -
  host never came up after 2 retries - infrastructure flakiness, not an
  engine result, and were excluded). To keep the headline number a clean,
  round, pre-registered figure, results are reported on the **first 100
  of those roles, taken in original random-sample order** (not
  cherry-picked by outcome or speed).
- Of those 100, **61 roles had identical, fully-successful outcomes
  (`rc=0`) on all three engines both cold and warm** - the cleanest
  apples-to-apples set, and the one the headline numbers below are drawn
  from. A broader 78-role set (same outcome across all three engines,
  including roles where all three failed identically) is also reported for
  context.
- The remaining roles diverged in result across engines (different `rc` on
  at least one engine) and are tracked separately as bugs/gaps, not folded
  into the timing numbers - see `KNOWN_MISSING.md` for that list.

## Results

### 61-role clean set (identical successful outcome on all 3 engines)

| Phase | real Ansible | Ansible + Mitogen | krikri-playbook | krikri vs Ansible | krikri vs Mitogen |
|---|---|---|---|---|---|
| Cold (total) | 2176.6s | 1246.2s | 920.6s | **2.36x faster** | **1.35x faster** |
| Cold (median/role) | 22.04s | 11.54s | 5.32s | 3.43x faster | 1.82x faster |
| Warm (total) | 1328.0s | 598.2s | 185.3s | **7.17x faster** | **3.23x faster** |
| Warm (median/role) | 14.49s | 6.97s | 2.00s | 7.99x faster | 4.00x faster |

krikri-playbook was the fastest of the three engines in **57 of 61 roles
(93%)**.

### 78-role broader set (identical outcome, any `rc`)

| Phase | real Ansible (total) | Ansible + Mitogen (total) | krikri-playbook (total) | krikri vs Ansible | krikri vs Mitogen |
|---|---|---|---|---|---|
| Cold | 2726.2s | 1642.7s | 1191.1s | 2.29x faster | 1.38x faster |
| Warm | 1570.3s | 760.0s | 423.3s | 3.71x faster | 1.80x faster |

## Why warm re-runs show the biggest gap

Cold runs still involve package installs, downloads, and other work whose
cost is dominated by the task itself rather than the engine. Warm re-runs
are where the engine's own overhead is most visible: real Ansible pays a
fresh Python-interpreter-and-module cost per task on every run regardless
of whether anything changes; Mitogen amortizes some of that with a
persistent interpreter but still runs Python bytecode per task; krikri's
compiled-binary tasks and single persistent SSH connection per host mean
an idempotent no-op re-run does almost no per-task work at all.

