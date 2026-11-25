# 1797 - marsante.ansible_role_medshakeehr: the composer tasks are skipped in check mode where real runs them

- Issue: https://github.com/weirdbricks/krikri/issues/1797
- Role: `marsante.ansible_role_medshakeehr` (ubuntu host, round
  `logs___1795578916`, round29926321)
- Class: check-mode behavioural bug (task result, recap and exit code differ)

**What diverged.** The role's `tasks/install-msehr.yml` composer tasks -
`Composer update on {{ msehr_dir }}` and `Composer upgrade on {{
msehr_dir }}/public_html` - run `community.general.composer` under
`--check`. Real ansible runs the module (answering `ok` on the round
host's converged project) and exits 0; krikri skipped both
(`Task 'Composer update on {{ msehr_dir }}' uses unimplemented plugin:
community.general.composer`) and exited 4. The skip also meant the
krikri host never got the role's `vendor/` tree in the cold run, so the
role's own `Execute MedShakeEHR cli installation script` task failed
(`require(/var/www/ehr/vendor/autoload.php)`) and every task after it -
timezone, unattended-upgrades, UFW - reported `changed` where real
reported `ok`.

**Why.** composer.py declares `supports_check_mode=True` (it appends
composer's own `--dry-run` when the command advertises one), so real's
`--check` run executes the module: `get_bin_path("php", required=True,
opt_dirs=["/usr/local/bin"])` runs inside `get_available_options` before
any command's work. krikri had no composer plugin, so the task took the
graceful unavailable-module path (skip plus the exit-4 accounting).

**Fixture.** The role's two composer tasks verbatim (names, params and
tags included), with `become: true`/`become_user: www-data` dropped so
they run as the local user. This box has no php CLI, so real's
transcript here is the probe's `Failed to find required executable
"php"` fatal - the same ran-versus-skipped divergence the round hit,
with the same root cause (the module executes under `--check`).

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6 + community.general 12.5.0. `inventory.ini` pins the
interpreter on the `[local]` host.

**Fix.** `plugins/composer.cr` is the native port registered as
`community.general.composer`, so the module runs under `--check` and
reports the same ok/changed/failure as real instead of skipping the
task.

The port alone still failed the role's composer step on a real host:
`copy:` never gave the copied tree's directories the task's owner, so
everything the tree copy created under `/var/www/ehr` stayed root-owned
and composer, running as www-data, died with
`file_put_contents(./composer.lock): Failed to open stream: Permission
denied` first in `msehr_dir` and then in its `public_html`
subdirectory. `plugins/copy.cr` now runs the module's exit-time
`set_fs_attributes_if_different` over the task's `dest` for a remote_src
tree copy (with `directory_mode` replacing `mode:`) and applies
owner/group to every directory in the tree, created or pre-existing,
which is what the role's later tasks need to converge.
