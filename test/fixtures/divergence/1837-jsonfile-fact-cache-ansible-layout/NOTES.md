# `jsonfile` fact cache is not shared with ansible-core 2.21

- issue: https://github.com/weirdbricks/krikri/issues/1837
- reported against: krikri 0.9.3130 vs ansible-core 2.21.5, `ansible_connection=local`
- playbook: the issue's own repro, unchanged (`playbook.yml`)

## What diverged

With `ANSIBLE_GATHERING=smart ANSIBLE_CACHE_PLUGIN=jsonfile` and a warm cache
directory, real ansible skips the implicit gather (`ok=1`) while krikri gathered
again (`ok=2`), and each engine wrote its own file next to the other's.

ansible-core 2.21 persists cache entries through
`_cache.PluginInterposer` (`ansible/_internal/_plugins/_cache.py`), which stores
every entry under a `s<schema_id>_`-prefixed key (schema_id 1 in 2.21.6, so
`s1_<host>`) and wraps the value as `{"__payload__": "<compact JSON of the
facts>"}`. Its smart-gathering check then reads the `_ansible_facts_gathered`
key back out of that entry (`VariableManager._facts_gathered_for_host`). krikri
wrote a bare `<host>` file holding the plain facts object, so neither engine
ever saw the other's entry.

## Why the case ships a cache entry

The issue's repro is two processes (a first ansible run that warms the cache,
then a krikri run that should read it), and a corpus case is one invocation of
the engine under test. `cache/s1_h` therefore stands in for the entry the
first real ansible run leaves behind: a minimal payload carrying just the
`_ansible_facts_gathered` stamp its smart gathering keys on, wrapped in
ansible-core 2.21.6's own envelope shape (`s1_` name, `__payload__` JSON
string - captured live from a real ansible run's cache file), and `env.txt`
points the cache plugin at it. Real ansible replays the recording against
that same entry and prints `ok=1` (that is what the capture below ran
against), which is what makes the recording a valid expectation for the
read path; a krikri that only understands the pre-2.21 layout gathers and
prints `ok=2`.

`expected.out` was captured from real ansible-core 2.21.6 with
`bin/krikri-capture-case`.
