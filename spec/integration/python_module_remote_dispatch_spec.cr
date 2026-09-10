require "../spec_helper"
require "file_utils"

# Regression spec for the actual root cause behind newrelic.newrelic-
# infra's merge_yaml "OS error Permission denied (13)" (confirmed live
# on a real Atlantic.net host across several investigation rounds):
# execute_python_module's final PluginManager.execute_plugin call
# passed `wire_vars` - a copy of vars_context with `ansible_connection`
# forcibly overridden to "local", built ONLY for the CONFIG payload so
# a module already running remotely sees itself as local relative to
# its new host - instead of the real `vars_context` every OTHER plugin
# dispatch in the same method already uses for this exact call.
# PluginManager.local_connection? falls back to reading
# `vars["ansible_connection"]` for a plain non-delegated remote host,
# so handing it the forced-local wire_vars made EVERY remote role-
# private python module dispatch decision see itself as local and run
# UNPRIVILEGED ON THE CONTROLLER instead of uploading to and running on
# the actual target - explaining the "Permission denied" writing to a
# controller path the controller's own account can't write, on a
# target that had real, working root access the whole time.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "role-private python module dispatch runs on the REMOTE target, not the controller" do
  it "attempts a remote (SSH) connection for a non-local host instead of running locally" do
    root = File.tempname("py-module-remote-dispatch")
    Dir.mkdir_p(File.join(root, "roles", "reprorole", "library"))
    Dir.mkdir_p(File.join(root, "roles", "reprorole", "tasks"))

    # A minimal old-style role-private module - if this ever runs
    # LOCALLY (the pre-fix bug), it prints its result immediately with
    # no network involved at all; the fix must make it attempt a REMOTE
    # connection to the (deliberately unreachable) inventory host
    # instead, which fails with an SSH-shaped error, never a local
    # filesystem/permission one.
    File.write(File.join(root, "roles", "reprorole", "library", "reprofilter.py"), <<-PYTHON)
      #!/usr/bin/python
      print('{"changed": true, "msg": "ran locally - THIS WOULD BE THE BUG"}')
      PYTHON

    File.write(File.join(root, "roles", "reprorole", "tasks", "main.yml"), <<-YAML)
      - name: dispatch a role-private python module to a remote host
        reprofilter:
          name: x
      YAML

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: target
        gather_facts: false
        roles:
          - reprorole
      YAML

    # 203.0.113.x is TEST-NET-3 (RFC 5737) - guaranteed unroutable, so
    # any real SSH attempt fails fast and deterministically instead of
    # hanging on a live-but-wrong address.
    File.write(File.join(root, "inventory.ini"), <<-INI)
      target ansible_host=203.0.113.99 ansible_user=root ansible_ssh_private_key_file=/dev/null ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 -o BatchMode=yes'
      INI

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", "inventory.ini", "pb.yml"], output: output, error: output, chdir: root)

    status.success?.should be_false, output.to_s
    output.to_s.should_not contain("ran locally - THIS WOULD BE THE BUG"), output.to_s
    # A real SSH/upload attempt against the unroutable target fails with
    # a connection-level error (refused/timed out/unreachable) - never
    # the local module's own "Permission denied" or a clean local run.
    (output.to_s.includes?("UNREACHABLE") ||
      output.to_s.downcase.includes?("connect") ||
      output.to_s.downcase.includes?("ssh")).should be_true, output.to_s
  ensure
    FileUtils.rm_rf(root) if root
  end
end
