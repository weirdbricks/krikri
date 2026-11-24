Issue: https://github.com/weirdbricks/krikri/issues/1726

Role: alesauce.provision_new_stock_linux_server (round 29923741),
ubuntu. The divergence was the implicit `Gathering Facts` task: real
ansible's pure-Python setup returned `ok`, while krikri's facts plugin
never started on the round's target image:

    Error gathering facts: Plugin execution failed on remote
    stderr: .../plugins/facts: error while loading shared libraries:
    libxml2.so.2: cannot open shared object file

Cause: `krikri-aws-ssm`'s STS client parses AWS's Query-protocol XML
with Crystal's stdlib `XML`, which links libxml2.so.2 - and
`base_plugin` -> `ssh_manager` -> `ssm_transport` -> `krikri-aws-ssm`
put that dependency into every plugin binary, including the `facts`
binary uploaded to the target. A stock Ubuntu image ships no
libxml2.so.2, so the loader killed the process before `main()` ran.
`build.sh` now statically links libxml2 (with the zlib/liblzma/libm
archives it pulls in) for dynamic Linux builds; the linkage itself is
pinned by `test/unit/plugin_shared_libraries_test.cr`, and the
playbook here pins the transcript of the task that diverged.

Capture notes: the round's `site.yml` reduced to the failing task - the
role's own user/authorized_key tasks never ran, and the first of them
would create a user on the suite's own host. `become: true` dropped
(the capture runs unprivileged) and the host mapped to the corpus
`[local]` shape with the interpreter pinned.
