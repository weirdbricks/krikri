# igami.zigbee2mqtt: Install zigbee2mqtt via npm

- issue: #1970
- role: igami.zigbee2mqtt
- round dir: /home/labros/git_work/krikri-role-tester/logs___1795853943/igami_zigbee2mqtt
- phase: cold and warm (block 8)
- task: Install zigbee2mqtt via npm.
- divergence: the failed result differs only in npm's debug-log file name
- first differing line:

  ```
  ansible: npm ERR!     /home/zigbee/.npm/_logs/2026-11-28T08_30_32_869Z-debug-0.log
  krikri:  npm ERR!     /home/zigbee/.npm/_logs/2026-11-28T08_30_33_506Z-debug-0.log
  ```

- round versions: krikri 0.9.3216, ansible-playbook [core 2.21.6]

## Why the only difference is the run's own clock

npm writes its debug log to
`$HOME/.npm/_logs/<YYYY-MM-DD>T<hh>_<mm>_<ss>_<ms>Z-debug-0.log` and repeats that path in the
failure's `msg`, `stderr` and `stderr_lines`. The stamp is the wall clock at the moment npm
started, so any two runs disagree on it: two runs of real ansible-playbook on this box (2.19.11)
printed `...T09_25_08_611Z` and `...T09_29_21_959Z`, exactly like the round's two engines
disagreed (`..._32_869Z` vs `..._33_506Z`). Every other byte of the result matches - `cmd`, the
npm error text, `rc`, the recap - and with the interpreter pinned krikri's whole transcript is
byte-identical to ansible's once that stamp is normalized.

## Corpus fit

`expected.out` is a fresh capture of `playbook.yml` from real ansible-core 2.21.6 over this
directory. `Krikri::DivergenceTranscript` normalizes the stamp inside an `.npm/_logs/` file
name, as it already does for command/shell's own timing fields: without it a recording could
only pin the one wall-clock moment it was captured at, and every replay would fail on a value
no engine can control. The log directory, the `-debug-<n>.log` suffix and the whole message
around it are still compared, so a wrong log path remains a divergence.

Three adaptations keep the transcript about THIS failure:

- `gather_facts: false`: the task needs no facts, and ansible-core 2.21.6 gathers them without
  printing a task (krikri still prints its Gathering Facts block, a separate divergence).
- `path: "{{ playbook_dir }}/node"` replaces the role's `zigbee_dir`, and `become`/
  `become_user: "{{ zigbee_user }}"` are dropped because localhost has no `zigbee` user.
  `node/package.json` declares a `file:` dependency on a directory that does not exist, which
  is what makes the install fail: the round's npm 9.2.0 crashed with "Cannot read properties of
  null (reading 'edgesOut')" on the zigbee2mqtt checkout instead. The text is npm's either way;
  the divergence this case pins is only the log path it quotes.
- `inventory.ini` pins the interpreter on the `[local]` host, the only spelling both engines
  read alike.

`roles/igami.zigbee2mqtt/` is the role tree the round ran, so the real YAML is in the case even
though `playbook.yml` only runs the one divergent task.

Capture it with:

    bin/krikri-capture-case test/fixtures/divergence/1970-npm-debug-log-stamp
