# #1786 - known_hosts with a bare relative `path:` crashes real's atomic_move

- Issue: https://github.com/weirdbricks/krikri/issues/1786
- Class: kpg:known_hosts chaos: WrongType on `t0:path`
- Playbook: `000012-multi-known_hosts-chaos` (`krikri-playbook-generator`, seed 1795578294)

**What diverged.** The generator's chaos pass typed the task's `path:` as an
int (`path: 37`). Ansible's `known_hosts` module declares `path` as
`type: path`, so `37` reaches the module as the relative string `"37"`; the
file does not exist, so `enforce_state` writes the key to a
`NamedTemporaryFile(dir=os.path.dirname("37"))` (dir `""`, i.e. the module's
cwd) and hands it to `AnsibleModule#atomic_move`. The rename succeeds, and
`atomic_move`'s creating branch then ends with
`os.stat(os.path.dirname(b_dest))` - `os.stat(b'')` - which raises an
uncaught `FileNotFoundError`. Real ansible therefore fails the task:

```
[ERROR]: Task failed: Module failed: [Errno 2] No such file or directory: b''
```

and leaves the newly renamed file behind. krikri's plugin wrote the file and
reported `changed`, so it never failed and the following tasks were not
`ignored`.

**Fix.** `plugins/known_hosts.cr`'s `rewrite` now reproduces `atomic_move`'s
trailing dirname stat: when the file was newly created from a path with no
directory component it returns the same crash result (and, like real, after
the rename has already placed the file).

**Why the play is this task plus a debug.** The role part of the generator
playbook is irrelevant to the divergence, and the following
`ansible.builtin.package` task only proves the run continued because
`ignore_errors` swallowed the failure. The debug pins the registered crash
shape (`changed`/`failed`/`exception`/`msg`) too.
