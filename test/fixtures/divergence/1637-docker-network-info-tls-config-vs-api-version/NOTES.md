# #1637 - kpg docker_network_info (chaos): unusable TLS cert paths hid the api_version error

- Issue: https://github.com/weirdbricks/krikri/issues/1637
- Playbook: `000008-multi-docker_network_info-chaos` (krikri-playbook-generator)
- Class: output gap (module error message, wrong one reported)

**What diverged.** The task carries a bogus `api_version: wwudbt` together
with `tls: true` and a `client_cert`/`client_key` pair whose files do not
exist. Real reports `TLS config error: Path to a certificate and key files
must be provided through the client_cert param. ...`; krikri reported
`Error connecting: invalid version number 'wwudbt'`.

**Why.** community.docker's `AnsibleDockerClientBase.__init__` first calls
`get_connect_params()`, which builds the vendored `_api/tls.py` TLSConfig:
with TLS in use and both client paths set, it raises `TLSParameterError`
unless `os.path.isfile()` accepts BOTH files (and, on the verify path
only, the CA file), which `_common_api.py`'s fail_function reports as
`TLS config error: <text>`. Only after that does it construct the client,
whose StrictVersion parse is what reports a bad `api_version`. krikri
skipped the TLS parameter validation entirely, so the api_version parse
was the first failure and the task reported the wrong one.

**Fixture.** The issue's `Docker_network_info #8.0` task verbatim, with
the generator's `/tmp/kpg-work` paths moved under `playbook_dir` (nothing
is read there: the failure is before any daemon I/O) and `delegate_to`
dropped so it runs on the local host.

`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6 + community.docker 5.2.1.
