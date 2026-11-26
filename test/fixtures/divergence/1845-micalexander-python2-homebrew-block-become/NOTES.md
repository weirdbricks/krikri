# micalexander.python2: missing INJECT_FACTS_AS_VARS block from a skipped block's become:

Pulled from the round the issue cites, so the role YAML that diverged replays
as a test instead of living in the issue body.

- issue: #1845
- role: micalexander.python2 (its `geerlingguy.homebrew` dependency)
- round dir: `/home/labros/git_work/krikri-role-tester/logs___1795686235/micalexander_python2`
- phase: cold and warm (both `block 40 PLAY RECAP`)
- task: `geerlingguy.homebrew : Force update brew after installation.`, skipped
  by the dependency's `when: ansible_distribution == 'MacOSX'`
- divergence: krikri printed 2222 B where real printed 2773 B; the missing
  piece was the deprecation block real raises while templating the block's
  `become: "{{ (homebrew_user != ansible_user_id) | bool }}"`:

  ```
  -[DEPRECATION WARNING]: INJECT_FACTS_AS_VARS default to `True` is deprecated, ...
  -Origin: <WORK>/roles/geerlingguy.homebrew/tasks/main.yml:153:11
  -...
  ```

- round versions: krikri 0.9.3139 (debug), ansible-playbook [core 2.21.6]

## Why it diverged

real post-validates the task's play context, `become:` included, BEFORE it
evaluates the task's `when:` (`executor/task_executor.py`'s `_execute`), and a
conditional that then skips the task keeps the deprecation that render printed
while dropping only the keyword's own error. krikri only rendered the become
keyword for tasks whose conditional passed, never inherited a block's templated
`become:` into its children at all, and had no Origin for a fact read inside a
keyword template - so the block real printed was missing entirely.

## Corpus fit

`expected.out` is real ansible's transcript for one run, captured with
`bin/krikri-capture-case` (2.21.6). The two blocks it pins are the block-level
`become:` render (Origin at the become value token) followed by the enclosing
block's `when:` read, both emitted after the skipped task's banner - the order
real uses and the order krikri now reproduces. The playbook is the homebrew
role's block from `tasks/main.yml` lines 89-154 verbatim, wrapped in the
dependency `when:` from `micalexander.python2`'s `meta/main.yml:61` so its tasks
skip on this non-macOS host exactly as they did in the round.
