# Contributing

## Source-reading policy

krikri-playbook is MIT-licensed. ansible-core, ansible-lint and yamllint are
GPLv3+. To keep krikri MIT we follow the approach uutils uses against GNU
coreutils: reproduce observable behavior, including exact output, without
reading or copying the GPL source.

**Do not** read, copy, paraphrase or cite the source of Ansible, its
collections, ansible-lint or yamllint, and do not name their source files in
code comments, commit messages or docs.

**Do** work from:
- public documentation
- observed behavior of the real tools
- real `ansible-playbook` / `ansible-lint` output used as an oracle
  (comparison rounds, parity scripts)

Short messages and small constant lists that are part of the compatibility
surface (error text playbooks match on, keyword sets, color codes) may match
upstream byte-for-byte. Longer prose, schemas and code structure must not be
copied.

### AI assistants

Contributions made with AI tools (Claude, Crush, others) follow the same rule:
never reproduce GPL source, and do not instruct an agent to read it. Describe
behavior, not upstream files.

See `../LICENSE_REVIEW.md` for the full plan.
