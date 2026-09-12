---
name: launch-roles
description: Launch a krikri-role-tester batch round against real Ansible Galaxy roles. Use whenever the user asks to "launch roles", "run a round", "start a batch", "test some roles", or names specific roles/a role count to test against krikri-playbook vs real ansible-playbook. Handles picking roles, choosing a fresh round-start, fetching Atlantic.net credentials, respecting kata/atlantic concurrency limits, writing the queue file, and invoking `krikri-role-tester run`. This only covers the batch phase (kicking off the run) — triage/fix/confirm phases are separate.
---

# Launch roles (krikri-role-tester batch phase)

Kicks off a `krikri-role-tester run` batch. This is step 2 ("Batch phase") of
the real-host benchmark-round workflow in `/home/labros/git_work/krikri/CLAUDE.md`
— read that section if anything here is ambiguous. Do **not** make engine
code changes during this phase.

## 1. Determine the role list

- If the user named specific roles (as arguments or in their message), use those.
- For a small/exploratory round, pull a shortlist from `ROLES_TESTED.md` —
  prefer roles not yet tested (avoid re-discovering Galaxy-404s like
  `geerlingguy.mongodb`/`.consul`/`.golang`, and avoid re-verifying
  already-clean roles as new unless the user is deliberately re-checking a
  role after something made a host suspect).
- For a large batch (e.g. "launch 400 roles", no specific roles named): source
  fresh candidates from the Galaxy top-download list, diffed against every
  role already in `ROLES_TESTED.md`:

  ```bash
  # Extract every already-tested role name (case matters for the dedup below)
  grep -oP '^\| `\K[^`]+(?=` \|)' ROLES_TESTED.md | sort -u > /tmp/tested.txt

  # Page through Galaxy's top-download list. Use summary_fields.namespace.name,
  # NOT github_user/username — a role's install-time namespace can differ from
  # its GitHub owner after a Galaxy-side rename/migration, and github_user
  # produced a ~36% GALAXY_MISSING rate (plain 404s) in an earlier batch.
  for page in $(seq 1 <enough-pages-for-3x-the-batch-size>); do
    curl -s "https://galaxy.ansible.com/api/v1/roles/?order_by=-download_count&page_size=100&page=$page" \
      | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d['results']:
    ns = r.get('summary_fields',{}).get('namespace',{}).get('name') or r.get('github_user')
    print(f\"{ns}.{r['name']}\")
"
    sleep 0.3
  done >> /tmp/galaxy_all.txt

  # Case-insensitive dedup against already-tested roles — Galaxy's namespace
  # field is lowercase-canonical, but ROLES_TESTED.md rows preserve whatever
  # casing the original queue file used (e.g. `Appsilon.mount_efs`), so a
  # case-sensitive diff re-tests the same role under a different spelling.
  awk 'NR==FNR{tested[tolower($0)]=1; next} !(tolower($0) in tested) && !seen[tolower($0)]++' \
    /tmp/tested.txt /tmp/galaxy_all.txt > /tmp/galaxy_new_ranked.txt
  ```

  Take the top N from `/tmp/galaxy_new_ranked.txt` (already ranked by download
  count, highest first). For a split-OS batch (e.g. 400 roles = 200
  ubuntu + 200 rocky), just take the first half/second half — no need to
  re-rank per OS.
- Ask the user for a rough count if neither specific roles nor a large-batch
  signal is given (e.g. "how many roles for this round?").

## 2. Pick a fresh round-start

Round numbers must never be reused, especially not from a killed/interrupted
batch — relaunching at a dead batch's `--round-start` hits 100% instant
`SSH_TIMEOUT` against now-torn-down hosts (see memory:
`dont-reuse-round-numbers-after-kill`).

Find the highest round number already used and start comfortably above it:

```bash
ls ~/scratch/krt-results 2>/dev/null | sed -E 's/^([0-9]+)_.*/\1/' | sort -n | tail -1
```

Round up to a clean multiple (e.g. last was `700443` → use `701000`) so the
new round's own numbers stay easy to read back out of `ROLES_TESTED.md` later.

## 3. Fetch Atlantic.net credentials (only if the round can use atlantic)

Per `CLAUDE.local.md`:

```bash
ATLANTICNET_ACCESS_KEY=$(/usr/local/bin/keypass-tool.sh 2>/dev/null | keepassxc-cli show -s "$DB" atlanticnet --attributes AccessKey 2>/dev/null)
```

- **`-s`/`--show-protected` is required** — without it `keepassxc-cli show`
  silently returns the literal string `PROTECTED` instead of the real value,
  which breaks `terraform apply` with an invalid-API-key error that looks
  unrelated to credentials.
- Always redirect stderr to `/dev/null`, **never `2>&1`** — the "Enter
  password to unlock" prompt text otherwise gets captured into the credential.
- Maps to `ATLANTICNET_ACCESS_KEY`/`ATLANTICNET_PRIVATE_KEY` (not
  `_USERNAME`/`_PASSWORD`).
- See `CLAUDE.local.md` for the exact KeePass DB path and entry name — read it
  rather than hardcoding here, since it's gitignored and may change.

Skip this step for a kata-only round.

## 4. Respect concurrency limits (from memory)

- **Kata:** max 2 pairs (4 VMs) for `--kata-hosts` — never 4 pairs/8 VMs
  (memory: `kata-concurrency-limit`).
- **Atlantic.net:** account cap is 25 servers, 2 reserved for DevViews — keep
  total concurrency (this batch + anything already running) ≤ 22
  (memory: `atlanticnet-server-limit`). Check for already-running batches
  first (`ps aux | grep krikri-role-tester`, or ask the user) before assuming
  the full 22 is free.
- Before trusting a run's results if it touched kata hosts, remember the
  `/dev/shm` teardown leak was fixed 2026-09-07 but sanity-check
  `df -h /dev/shm` if anything looks DIVERGENT unexpectedly
  (memory: `kata-teardown-devshm-leak`).
- **Kata is exclusive to one running `krikri-role-tester` invocation at a
  time** — a second concurrent invocation with `--kata-hosts` set will error
  out ("N Kata VM(s) already running on this host") if the first invocation
  already claimed kata slots. For a split-OS batch (e.g. ubuntu + rocky run
  concurrently), give kata to ONE invocation and force the other to
  `--backend atlantic` (drop `--kata-hosts` and any `--kata-hosts` default).
- **Sweep before launching, every time**, even if nothing looks obviously
  wrong: `bin/krikri-role-tester sweep ~/scratch/krt-results` — a prior
  session's crash or interrupted run can leave orphaned Atlantic.net servers
  that silently eat into the 22-server budget above. Also check
  `ps aux | grep krikri-role-tester` for anything already running before
  computing how much of the kata/atlantic budget is actually free.

Default host caps unless the user says otherwise: `--kata-hosts 4
--atlantic-hosts 4` (2 pairs each) for a small/exploratory round; scale up
within the limits above only if the user explicitly asks for a bigger batch.

## 5. Write the queue file

One role per line in the scratchpad directory, optional backend hint
(`kata`/`atlantic`) per line if the user specified one:

```
geerlingguy.docker
geerlingguy.nginx kata
geerlingguy.apache atlantic
```

Unhinted roles prefer kata and overflow to atlantic once kata is saturated —
leave roles unhinted unless the user has a reason to pin one.

## 6. Run it

```bash
cd /home/labros/git_work/krikri-role-tester
ATLANTICNET_ACCESS_KEY=... ATLANTICNET_PRIVATE_KEY=... \
  bin/krikri-role-tester run <queue-file> \
    --kata-hosts <N> --atlantic-hosts <N> \
    --results-dir ~/scratch/krt-results --round-start <fresh-round>
```

Launch as a background command (this is a long-running batch — provisioning,
cold+warm runs, teardown per role). Tell the user the round range and where
results will land, and that the next steps are triage (`bin/krikri-role-tester
report ...`) and fix, which are separate from this skill.

If the run needs to be interrupted, use plain `kill <pid>` (SIGTERM) for a
graceful shutdown — never `kill -9` — and mention
`bin/krikri-role-tester sweep ~/scratch/krt-results` as the recovery path if
it ever does get SIGKILLed or the machine crashes.
