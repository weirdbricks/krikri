# #1864 - apt_key: a YAML folded `url:` keeps its trailing newline

- Issue: https://github.com/weirdbricks/krikri/issues/1864
- Role: `iancleary.nodejs` (ubuntu, round round29928609), task
  "Nodejs - Add Nodesource apt key."
- Class: behavioural - the task ran on the ansible side and failed on the
  krikri side, skipping the rest of the play

**What diverged.** The role writes its key URL as a YAML folded block:

```yaml
- name: Nodejs - Add Nodesource apt key.
  ansible.builtin.apt_key:
    url: >
      https://keyserver.ubuntu.com/pks/lookup?op=get&fingerprint=on&search=0x1655A0AB68576280
    id: "68576280"
    state: present
```

so the module receives the URL with a trailing newline. Real ansible fetched
it and reported `changed`; krikri failed the task with

```
Failed to fetch key from https://keyserver.ubuntu.com/pks/lookup?op=get&fingerprint=on&search=0x1655A0AB68576280
: curl: (3) URL rejected: Malformed input to a URL function
```

and the play stopped there (`ok=2 changed=1` vs ansible's `ok=5 changed=2`,
with the elementary-OS `set_fact` tasks and the apt_repository task never
running).

**Why krikri had it wrong.** ansible's `fetch_url` builds a `urllib.request
.Request`, whose `unwrap()` starts with `str.strip()` - so the trailing
newline never reaches the request. krikri hands the raw module parameter to
curl, and curl 8 rejects any URL containing a control character outright
(`URL rejected: Malformed input to a URL function`).

**Fix.** `plugins/apt_key.cr`'s `download_key_url` now requests
`urllib_request_url(current)`, which mirrors `unwrap()` (strip, plus its
`<URL:...>`/`URL:` prefix trimming). Failure messages keep quoting the raw
`url:` parameter, exactly like ansible's `mask_url(url)`.

**Fixture.** The failing task is copied verbatim; only the URL's host is
adapted (loopback port 1 instead of keyserver.ubuntu.com) because the suite
has no network - the connection is refused instantly on both engines, so the
same trim-vs-raw divergence shows up in the failure message (which echoes the
raw URL, newline included). `bin/apt-key` is a no-op double: the module needs
an apt-key for `find_needed_binaries()` and the pre-add keyring listing on
this apt-key-less box, and nothing is ever added because the fetch fails
first. `expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6.
