# #1635 - kpg docker_image (chaos): an unusable docker_host hid the api_version error

- Issue: https://github.com/weirdbricks/krikri/issues/1635
- Playbook: `000011-multi-docker_image-chaos` (krikri-playbook-generator)
- Class: output gap (module error message, wrong one reported)

**What diverged.** The task carries both a bogus `api_version: tkmfuf`
and a portless `docker_host: tkvwva`. Real reports the api_version, krikri
reported `Invalid bind address format: port is required: tkvwva`.

**Why.** community.docker 4.7.0/5.2.1 do not drive the installed Docker
SDK; every `docker_*` module uses the collection's own vendored API
client (`plugins/module_utils/_api/`), whose `parse_host()` still
defaults a missing tcp port (2376 plain, 2375 with TLS - the lower one
for TLS, the reverse of the Docker CLI convention). So `tkvwva` becomes
`http://tkvwva:2376`, host parsing succeeds, and the pinned api_version's
StrictVersion parse is what fails client construction. krikri had
modelled the standalone docker SDK 7.x instead, which raises "port is
required" and therefore failed on the host first.

**Fixture.** The issue's `Docker_image #11.0` task verbatim, with the
generator's `/tmp/kpg-work` paths moved under `playbook_dir` (nothing is
read there: the failure is before any daemon I/O) and `delegate_to`
dropped so it runs on the local host.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6 + community.docker 5.2.1; the vendored client is
shipped BY the collection, so 4.7.0 (the generator's reference image)
produces the same text.
