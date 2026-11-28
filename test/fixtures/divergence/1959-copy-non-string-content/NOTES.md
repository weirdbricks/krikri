# 1959 - copy: non-string content is not JSON-encoded like ansible

- Issue: https://github.com/weirdbricks/krikri/issues/1959
- Role: none - found while building the repro for #1874 (ansible-lint's
  `avoid-implicit` flags exactly this `copy: content: {mapping}` shape)
- Evidence: issue body's `pb4.yml` transcript (that round's directory is gone;
  this case is the issue's own playbook with relative dest paths)

## What diverged

ansible-core's copy ACTION plugin JSON-encodes a dict/list `content` before
anything writes it (`lib/ansible/plugins/action/copy.py`: `if
isinstance(content, dict) or isinstance(content, list): content_tempfile =
self._create_content_tempfile(json.dumps(content))`, json's default `", "` /
`": "` separators and no trailing newline). krikri's strings-only param wire
had already flattened the value (`stringify_value` in
`src/krikri/playbook_parser.cr`: compact `to_json` for a mapping, a
comma-join for a list of scalars), and the plugin wrote that text:

- mapping written `{"a":"b","n":1}`, real `{"a": "b", "n": 1}`
- list written `a,b`, real `["a", "b"]`

Scalars (`123`, `3.5`, `true`) already matched. The parser now marks the
container (NON_STRING_PARAM_PREFIX) so `plugins/copy.cr` can re-serialize it
with `Krikri::PyDump.json`, the same json.dumps implementation uri's body
uses; templated leaves are rendered per-leaf first, since ansible templates
each mapping value before serializing.

## Case

The issue's playbook verbatim, with dest paths made relative so the case only
writes inside its scratch directory. `expected.out` is
`bin/krikri-capture-case`'s capture from ansible-core 2.21.6.
