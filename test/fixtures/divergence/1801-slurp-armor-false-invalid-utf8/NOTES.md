# #1801 - slurp with armor=false: the invalid-UTF8 refusal text differs

- Issue: https://github.com/weirdbricks/krikri/issues/1801
- Playbook: krikri-playbook-generator `000029-multi-subversion-happy.yml`
  ("Slurp #29.1"), kpg class `slurp: check mode, happy path`
- Class: output text - the failed item's msg and [ERROR] block carried a
  different CPython codec message and a different wrapper

**What diverged.** The task slurps `/opt/kpg-fixtures/binary.bin` with
`armor: false`, so the module hands the raw file bytes back to the
controller as a string. Ansible's controller refuses any result string that
cannot be encoded as UTF-8:

```
Refusing to deserialize an invalid UTF8 string value: 'utf-8' codec can't encode character '\udcff' in position 12: surrogates not allowed
```

krikri answered with a two-character range ("characters in position 12-13"),
a "Module failed:" middle segment, no `MODULE_STRICT_UTF8_RESPONSE`
help paragraph, and a fatal msg without the `Task failed: ` brief.

**Why krikri had it wrong.** The plugin derived a BYTE offset plus a
fixed two-byte run, while CPython's codec error counts positions in
CHARACTERS of the surrogateescape-decoded string and prints the lone
surrogate's own escape when the undecodable run is a single byte. The
display path also treated the refusal as an ordinary module `fail_json`
(hence the "Module failed." segment) instead of the controller-side
`AnsibleRuntimeError` ansible raises while deserializing the result, whose
help text is what splits the block into the `<<< caused by >>>` form.

**Fix.** `plugins/slurp.cr` now decodes with surrogateescape semantics
(strict UTF-8 validation including overlong forms and the encoded-surrogate
range), reports the first run of undecodable bytes in characters, and hands
the refusal over the same `Task failed:` / `_ansible_error_detail` pair the
other controller-side crashes use; `task_error_chain` renders that pair as
ansible's two-segment block with the setting's help text inline.

**Fixture.** The failing task is copied verbatim except that the loop keeps
only the entry that diverges (the other seven `/opt/kpg-fixtures` files are
valid UTF-8 and report `ok`), and `delegate_to: target2`/`when:` are dropped
so it runs on localhost. `binary.bin` carries an invalid `0xff` at character
12, which is exactly the position ansible's transcript names.
`expected.out` was captured with `bin/krikri-capture-case` from real
ansible-core 2.21.6.
