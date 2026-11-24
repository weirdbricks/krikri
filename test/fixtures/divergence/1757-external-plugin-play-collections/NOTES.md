# A short module name must resolve through the play's `collections:`

- issue: #1757 (https://github.com/weirdbricks/krikri/issues/1757)
- task: `hello` on a play with `collections: [acme.tools]` (the issue's repro)

## What diverged

Real ansible resolves `hello` inside the play's collection scope and runs
`acme.tools.hello`; the case ships that collection locally and points
`ANSIBLE_COLLECTIONS_PATH` at it. krikri's external module plugins
(`KRIKRI_PLUGIN_PATH`) resolved by exact filename only, so the same task was
skipped with "Task 'hello' uses unimplemented plugin: hello" and rc 4. The
case's `plugins/acme.tools.hello` is that same module as a krikri external
plugin, and both engines must reach it and print the identical `ok` line.
