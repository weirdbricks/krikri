# #1528 - stuvusIT.reverse_proxy: the mandatory filter's failure text

- Issue: https://github.com/weirdbricks/krikri/issues/1528
- Role: `stuvusIT.reverse_proxy` (round `logs___1795001446`, check phase)
- Class: output gap (error text and error block shape)

**What diverged.** The role's `include_tasks: certificates.yml` loops over
`with_items: "{{ proxy_domains | mandatory }}"`. Real fails the task with
`[ERROR]: The filter plugin 'ansible.builtin.mandatory' failed: Mandatory
variable 'proxy_domains' not defined.` and no `<<< caused by >>>` chain;
krikri reported a generic `'proxy_domains' is undefined` and appended a full
caused-by chain, so both the block and the fatal dump differed.

**Fixture.** The role's `tasks/main.yml` failing task verbatim. The
`import_tasks: install.yml` above it adds an apt repository and installs nginx,
so it is dropped (the loop source fails before anything else could run).
`certificates.yml` is never reached - its placeholder task exists only so the
include could resolve.
