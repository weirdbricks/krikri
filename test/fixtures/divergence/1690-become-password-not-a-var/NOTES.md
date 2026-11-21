# 1690 - become password exposed to templates as ansible_become_password

https://github.com/weirdbricks/krikri/issues/1690

The issue's repro (from the 0.9.3021-vs-2.21.6 CLI comparison, `/tmp/krikri-triage-1684/gap2/pb.yml`,
now gone) ran this exact playbook with `-K` on a pty; the same divergence shows through the
non-interactive `--become-password-file` form, which is what this case uses so it can replay
in-process (no pty).

krikri published the CLI-supplied become password as the host var `ansible_become_password`, so
`debug: var=ansible_become_password` printed the secret. ansible-core keeps the CLI password in
its passwords dict (cli/__init__.py ask_passwords -> PlayContext) below any
ansible_become_password variable: the template sees an undefined variable and the debug renders
the template-error line.
