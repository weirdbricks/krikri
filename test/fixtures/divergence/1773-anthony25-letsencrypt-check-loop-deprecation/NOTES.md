# #1773 - Anthony25.letsencrypt: check-mode loop items lose their deprecation blocks

- Issue: https://github.com/weirdbricks/krikri/issues/1773
- Role: Anthony25.letsencrypt (master, galaxy) from round
  `logs___1795546590` / round29925788 (podman, ubuntu, krikri 0.9.3079)
- Class: check-mode output (real's PLAY RECAP block carries two
  INJECT_FACTS_AS_VARS blocks - the `letsencrypt_email` default's
  `ansible_domain` read and the loop item label's read - krikri printed
  neither)

**What diverged.** Both of the role's `command:` tasks are looped, and
`command` has no check mode, so under `--check` every item skips. Real
finalizes (and labels) an item BEFORE the module's own check-mode gate
answers `skipped`, so the blocks those renders raise print ahead of the
item's `skipping:` line. Krikri's loop display printed the skipped item's
line without flushing the per-item deprecation capture window that the
executed-item display path (`display_result`) flushes, so only the loop
source's own block survived: 1 block where real printed 3.

**Fix.** `finish_looped_task`'s plugin-side skip branch now flushes the
capture window before printing the `skipping:` line, the same replay
`perform_skip` already does for a solo skip.

**Fixture.** `roles/Anthony25.letsencrypt/` carries the role's two
`command:` tasks verbatim (the preceding `Ensure webroot exists` task is
dropped: it reads no fact and its outcome depends on /var/www existing on
the replay host) plus its `defaults/main.yml` with ONE adaptation:
`letsencrypt_cert_domains` reads `ansible_system` instead of `ansible_fqdn`
- the fqdn is rendered into the `(item=...)` label, so the real transcript
would otherwise differ per machine, while `ansible_system` is the same
deterministic "Linux" everywhere the suite runs and is injected the same
way. `letsencrypt_email`'s `ansible_domain` read - the block the issue
actually lost - stays verbatim. `flags.txt` adds the round's `--check`.
The transcript was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6.
