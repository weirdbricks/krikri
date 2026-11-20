# 1657: strategy plugin retry fallback

Issue: https://github.com/weirdbricks/krikri/issues/1657 (follow-up to #1456
and #1542).

`strategy_plugins/retry_demo.py` is a strategy plugin that subclasses
`linear` and retries every failed task twice with no delay. Real
`ansible-playbook` loads and runs it: the `flaky` task fails on its first two
attempts and passes on the third, so the run ends `ok=1` after two
`FAILED - RETRYING` lines.

krikri-playbook has no seam for that Python control-plane code, so a play
naming such a plugin runs as linear: one attempt, `failed=1`. That pass/fail
difference is what this case pins. The krikri-side attempt count and gap come
from the documented retry fallback (`env.txt`, issue #1542), and the play only
matches real when that fallback is opted into - without it the play is
refused at startup instead.

The counter file lives at `<WORK>/count` (`playbook_dir`), so it never
escapes the scratch tree. The two deprecation lines real prints for a
non-`ansible.builtin` strategy are part of the recorded transcript.
