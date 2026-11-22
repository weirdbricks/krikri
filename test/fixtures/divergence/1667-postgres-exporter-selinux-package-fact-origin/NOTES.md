# #1667 - antmelekhin.postgres_exporter: multi-line module `name:` arg pins the fact read on the task's own name line

- Issue: https://github.com/weirdbricks/krikri/issues/1667
- Role: `antmelekhin.postgres_exporter` (rocky, round round29920634)
- Class: behavioural bug (INJECT_FACTS_AS_VARS warning origin; PLAY RECAP bytes)

**What diverged.** The role's `tasks/Linux/configure.yml` SELinux block prints
the INJECT_FACTS_AS_VARS deprecation twice: once for the block's
`when: ansible_selinux.status == 'enabled'` and once for the
`ansible.builtin.package` task's `name:` argument, which reads
`ansible_python_version` inside a multi-line `{{ ... if ... else ... }}`. Real
ansible pinned the second block at the argument's own value token
(`configure.yml:60:15`, the `{{` of the `name:` value); krikri pinned it at the
task's `- name:` line instead (`configure.yml:58:13`), so the warning excerpt,
the Origin line and the transcript's byte count all differed - which is what the
round's `PLAY RECAP bytes differ (1312 B ansible, 1258 B krikri)` line in all
three phases (cold, warm, check) reports.

**Why.** `ResultDisplay.param_key_line_index` disambiguates the several `key:`
lines that can qualify for one task - the task's own `- name:` opens the
mapping, the module's `name:` param sits deeper in it - by comparing each
candidate line's inline value to the text actually being rendered. A scalar that
CONTINUES on the following lines never matches: YAML folds the continuation into
the parsed value, so the candidate's first line is only a prefix of it. With no
exact match the scan fell back to the first qualifying `name:` line, which is
the task's own.

The fix keeps the exact match as the primary answer and, when nothing matches
exactly, prefers the deepest key line whose inline text is a prefix of the value
being rendered - the line that opens a folded scalar. Real tags the read on that
line's value token, so the origin now matches.

**Round cold phase, separately.** The same round also reported the sibling
`get_url`/`unarchive` tasks as `changed` where real said `ok`/`skipping`. That
half is not a krikri gap: the role delegates both tasks to `localhost` with an
absolute `/tmp` destination, and krikri-role-tester runs both engines' cold
phases IN PARALLEL against the same controller, so whichever engine downloads
and extracts first leaves the artifacts the other then finds (real ansible on
the same pre-populated `/tmp` prints `ok`/`skipping` too - live-verified).
Nothing in krikri can match a race, and no case pins it.

**Corpus fit.** `playbook.yml` is the role's SELinux block with the two
adaptations a localhost capture needs: the gate is `ansible_python_version`
instead of `ansible_selinux.status == 'enabled'` (no capturing box has SELinux
enabled, and the block would otherwise be skipped and print nothing), and the
block's `become: true` is dropped. `flags.txt` pins `--check` so the package
task never installs anything. `inventory.ini` pins the interpreter on the
`[local]` host.

    bin/krikri-capture-case test/fixtures/divergence/1667-postgres-exporter-selinux-package-fact-origin

`expected.out` is real ansible-core 2.21.6's transcript (`Origin:
<WORK>/playbook.yml:18:19`, the `name:` value token). Before the fix krikri
printed `playbook.yml:16:17`, the task's `- name:` value.
