# 1791 - marsante.ansible_role_medshakeehr: composer tasks skipped instead of run

- Issue: https://github.com/weirdbricks/krikri/issues/1791
- Role: `marsante.ansible_role_medshakeehr` (ubuntu host, round `logs___1795578916`)
- Class: behavioural bug (task results and exit code differ)

**What diverged.** The role's `tasks/install-msehr.yml` tasks
`Composer update on /var/www/ehr` and
`Composer upgrade on /var/www/ehr/public_html` run
`community.general.composer`. Real ansible runs the module and reports
`changed` (the cold run) / `ok` (the warm one); krikri skipped both with
`Task '...' uses unimplemented plugin: community.general.composer` and
exited 4. The damage was not limited to those two tasks: composer is what
fetches the PHP dependencies `public_html/install.php` needs, so the
role's later `Execute MedShakeEHR cli installation script` task then
failed (rc 255) where real's kept running - krikri aborted the play six
tasks early (40 blocks instead of 46).

**Why.** krikri had no composer plugin, so the task took the graceful
unavailable-module path (skip plus the exit-4 accounting).

**Fixture.** The role's two composer tasks verbatim (names, `command:`,
`arguments:`, `working_dir:` and tags included), with `become: true` /
`become_user: www-data` dropped so they run as the local user and
`executable:`/`composer_executable:` pointed at the case's own php stub
(composer.py always execs `"<php> <composer-phar>"`, and this host has no
php at all). The stub answers the module's `help <command> --format=json`
probe the way composer 2.x does and reports "Installing dependencies from
lock file" for the update itself, i.e. `changed` like the round's cold
run. `msehr_dir` points into the case's scratch tree.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6 + community.general 13.2.0. `inventory.ini` pins the
interpreter on the `[local]` host.

**Fix.** `plugins/composer.cr` is a native port of the module: php and
composer resolved through `get_bin_path` (opt dir `/usr/local/bin`), the
installed composer asked which flags it supports, `changed` decided from
its "Nothing to install or update" no-op markers, plus the module's
argument checks (`required_if` on `working_dir`, the command/arguments
split) and its check-mode `--dry-run` handling. The same role's
check-mode round (#1797) landed that port, together with the
`chown_recursive` pass its `copy: remote_src:` task needs; this issue
keeps the record of the round that first hit the skip - the transcript
above plus `test/integration/composer_test.cr`, which pins the argv and
result shapes below the granularity the round's output shows.
