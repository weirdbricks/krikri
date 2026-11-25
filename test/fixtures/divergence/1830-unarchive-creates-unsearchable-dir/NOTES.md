# #1830 - unarchive: `creates:` probe crashes on a directory without its search bit

- Issue: https://github.com/weirdbricks/krikri/issues/1830
- Role: `bbaassssiiee.wso2db` (ubuntu host, round `logs___1795626220`)
- Class: check-mode behavioural bug (the task ran on one side, failed on the other)

## What diverged

The role's "Unzip WSO2 API Manager Package" extracts the WSO2 API Manager
pack with `mode: u=rw,g=r,o=r`, applied to every archive member - so the
extracted directories end up as `drw-r--r--`, without a search bit. A
later run's `creates: files/packs/wso2am-3.2.0/LICENSE.txt` therefore
names a path under a directory its own user cannot search.

Real ansible's action plugin asks the target a shell `test -e`
(`ActionBase._remote_file_exists`), whose answer is "no" for any error,
EACCES included: the task proceeds and, under `--check`, reports

```
changed: [testhost -> localhost]
```

krikri asked the same question with `Dir.exists?`, which routes through
`File.info?` - that maps only ENOENT to false and raises `File::Error`
for EACCES. The exception escaped the plugin's own crash wrapper, so the
task failed where real's simply changed:

```
[ERROR]: Task failed: Plugin execution failed: Unable to get file info:
'files/packs/wso2am-3.2.0/LICENSE.txt': Permission denied
```

## What this case pins

The role's "Unzip WSO2 API Manager Package" task and the "Ensure
directory files/packs" task before it, adapted as described in the
playbook's own header (`delegate_to:`/`connection:`/`run_once:`/
`become:` dropped, the 600MB get_url download replaced by a base64 seed
of the archive checked in here, `--check` from `flags.txt`). Three setup
tasks carry `check_mode: false` so the scratch copy reaches the state the
round's own earlier, non-check run left behind: the pack extracted, and
`mode: u=rw,g=r,o=r` applied to every member with a post-order `find`,
which is what removes the directories' search bit.

The case needs a non-root run: root ignores the search bit, so the probe
answers "exists" and both engines skip the task (the recording pins
`changed`). The replay skips when it finds itself running as root.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6. `archive.b64` is a fixture archive (the same shape
as 1818's: a top directory plus nested `repository/` directories), not a
recording.
