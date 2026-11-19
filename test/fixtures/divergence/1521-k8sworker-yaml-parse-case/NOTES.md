# #1521 - akshayavb99.k8sworker_setup_sample_role: YAML parse error text

- Issue: https://github.com/weirdbricks/krikri/issues/1521
- Role: `akshayavb99.k8sworker_setup_sample_role` (round `logs___1795001446`)
- Class: output gap (error text case)

**What diverged.** The role's `tasks/main.yml` starts with `---i`, so both
engines fail while loading the role. Real prints `YAML parsing failed: Did not
find expected <document start>.`; krikri printed the same sentence with
libyaml's lowercase `did not find ...`, so the whole [ERROR] block differed.

**Fixture.** The role's `tasks/main.yml` is copied verbatim. Nothing in it can
ever execute: the document start is malformed on line 3, before any task is
parsed, so no `shell:` task in the file can run even if the error text is
wrong (the failure is what the case pins).
