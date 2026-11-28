# 1972 - naftulikay.vagrant-rust-dev: become to a user the target does not have

https://github.com/weirdbricks/krikri/issues/1972

- issue: #1972
- role: naftulikay.vagrant-rust-dev (its `naftulikay.rust-dev` dependency)
- round dir: `/home/labros/git_work/krikri-role-tester/logs___1795853943/naftulikay_vagrant-rust-dev`
- phase: cold and warm (both block 9)
- task: `naftulikay.rust-dev : get rust user home directory`
  (`roles/naftulikay.rust-dev/tasks/include/00-facts.yml:2`)
- divergence: krikri printed 519 B where real printed 706 B

  ```
  ansible: [ERROR]: Task failed: Failed to change ownership of the temporary files Ansible (via chmod nor setfacl) needs to create despite connecting as a privileged user. Unprivileged become user would be unable to read the file.
  krikri:  [ERROR]: Task failed: Module failed: Plugin execution failed on remote
  ```

  and krikri's fatal line carried `{"_connection_failure": true, ..., "stderr":
  "sudo: unknown user: vagrant\n..."}` where ansible's is a plain
  `{"changed": false, "msg": ...}`.

- round versions: krikri 0.9.3216 (debug), ansible-playbook [core 2.21.6]

## Why it diverged

The role's `rust_user` is `vagrant` (naftulikay.vagrant-rust-dev's
vars/main.yml:2) and the Rocky target has no such account, so every one of the
role's `become_user: "{{ rust_user }}"` tasks is a become to an unprivileged
user that does not exist. ansible-core never gets as far as `sudo`: its action
plugin's `_fixup_perms2` chowns the module payload to the become_user as the
(admin, in the round root) connection user, the chown fails - a nonexistent user
is refused exactly like a refused ownership change - and
`ansible/plugins/action/__init__.py` raises "Failed to change ownership of the
temporary files ..." before any module runs.

krikri never chowns, so it asks that question with a probe and then runs the
module under `sudo -u`. The probe deliberately left a NONEXISTENT become_user
out (it checked `getent passwd` and treated the refusal as sudo's problem), so
the escalation went ahead, sudo failed with "sudo: unknown user: vagrant", and
the fallback that was supposed to word that as the chown failure only matched
sudo's other spelling, "sudo: unknown user vagrant" - the 1.9.16 wording on the
Ubuntu controller. The Rocky target's sudo 1.9.5 prints the colon, so the
failure fell through to `interpret_remote_result`'s generic "Plugin execution
failed on remote".

The controller-local leg had the same hole from the other side: becoming a
nonexistent user on a `connection: local` task spawned `sudo -u <user>` and
booked sudo's refusal as "Premature end of stream waiting for become success.",
where ansible's `_fixup_perms2` fails the same task with the same chown wording
(it runs on the local connection too, as the invoking user).

## Corpus fit

`expected.out` is real ansible's transcript for this playbook, captured with
`bin/krikri-capture-case` (2.21.6). The play runs the role's failing task
verbatim; `rust_user: vagrant` is the value the role handed it.

The round reached its target over ssh as root, which an in-process case cannot
be, so the case reproduces the same `_fixup_perms2` decision on a local
connection: its `inventory.ini` names the invoking user in
`ansible_admin_users`, the list ansible consults to decide whether a refused
chown is the privileged-user failure. With it, real ansible fails the task
before sudo for exactly the round's reason, and both engines' transcripts are
the same on any host.

`test/unit/become_chown_failure_test.cr` pins the rest of the shape in-process:
sudo's three spellings, the admin_users gate, and the local leg's decision.
