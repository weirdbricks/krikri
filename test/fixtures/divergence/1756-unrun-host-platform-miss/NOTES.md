# #1756 - a host that never runs the plugin must not get a pre-PLAY failure

- Issue: https://github.com/weirdbricks/krikri/issues/1756
- Repro: the issue's own `repro-skipped.yml` (a task targeting the remote
  host guarded by `when: false`), with `probe-only-ssh` standing in for the
  ssh endpoint.

**What diverged.** `PluginManager.batch_upload_plugins_for_playbook`
collected the module names of the WHOLE playbook and eagerly staged them on
every remote host in any play. A plugin it could not stage for that host (an
external plugin with no build for the target platform, or - as here, so the
case needs no `--plugin-path` root - a built-in one when the target reports a
platform with no `plugins-<arch>/`) was reported as a task-style
`fatal: [host]: FAILED!` line printed BEFORE the first `PLAY` banner, even
though the host never ran that task: the task was skipped (`when: false`), or
belonged to a different play. The run itself was correct (`failed=0`, exit 0),
so the line looked like a real failure that never happened. ansible-core has
no eager pass and prints nothing for that host.

**Fix.** Two halves of the same eager pass:

1. Its module sets are now per play (unioned per connection spec), so a host
   only gets the plugins of the plays that include it.
2. A `PluginUnavailableError` from it is no longer printed at all: the host
   stays in the play and the dispatch that really needs the binary fails its
   own task with the same message (the typed rescues on every dispatch path),
   which is the only case ansible reports. The external-plugin form of both
   shapes (another play / skipped task / task really running) is pinned by
   `test/integration/runtime_plugin_test.cr`; the checked-in playbook here
   uses a built-in module because the corpus copy cannot materialize a
   mode-0755 `--plugin-path` root.
