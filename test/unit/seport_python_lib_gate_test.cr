require "../minitest_helper"

# community.general.seport imports libselinux and seobject at module level
# and fails with Ansible's missing_required_lib wording before it ever
# looks at SELinux's runtime state. This plugin shells out to `semanage`
# instead, so on a target whose python lacks those bindings it used to
# carry on and answer with its own downstream state ("SELinux is disabled
# on this host.") where Ansible failed the task outright (issue #1416,
# dtoch56.ssh on rocky: Ansible=2/krikri=0 on the same task).
#
# The gate probes whatever interpreter discovery finds on PATH, so a
# scratch python shim stands in for such a target deterministically,
# whatever the host running the suite has installed.
describe "seport python library gates" do
  it "fails with Ansible's libselinux-python wording before the runtime-state check" do
    scratch = PluginSpecHelper.tmp_path("seport-gate-no-selinux")
    Dir.mkdir_p(scratch)
    shim = File.join(scratch, "python3.13")
    File.write(shim, "#!/bin/sh\nexit 7\n")
    File.chmod(shim, 0o755)

    result = PluginSpecHelper.run("seport",
      {"ports" => "22", "proto" => "tcp", "setype" => "ssh_port_t", "state" => "present"},
      env: {"PATH" => "#{scratch}:/nonexistent-seport-gate-path"})

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_match(
      /\AFailed to import the required Python library \(libselinux-python\) on /)
    result["msg"].as_s.must_include("please consult the documentation on ansible_python_interpreter")
  end

  it "fails with Ansible's policycoreutils-python wording when only seobject is missing" do
    scratch = PluginSpecHelper.tmp_path("seport-gate-no-seobject")
    Dir.mkdir_p(scratch)
    shim = File.join(scratch, "python3.13")
    File.write(shim, <<-SH)
      #!/bin/sh
      case "$*" in
        *"sys.executable"*) echo /usr/bin/python3.13 ;;
        *"import selinux"*) exit 0 ;;
        *) exit 7 ;;
      esac
      SH
    File.chmod(shim, 0o755)

    result = PluginSpecHelper.run("seport",
      {"ports" => "22", "proto" => "tcp", "setype" => "ssh_port_t", "state" => "present"},
      env: {"PATH" => "#{scratch}:/nonexistent-seport-gate-path"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_match(
      /\AFailed to import the required Python library \(policycoreutils-python\) on /)
  end

  it "still validates proto before the import gates (Ansible's argspec runs first)" do
    scratch = PluginSpecHelper.tmp_path("seport-gate-argspec-first")
    Dir.mkdir_p(scratch)
    shim = File.join(scratch, "python3.13")
    File.write(shim, "#!/bin/sh\nexit 7\n")
    File.chmod(shim, 0o755)

    result = PluginSpecHelper.run("seport",
      {"ports" => "22", "proto" => "krikri_gate_proto", "setype" => "ssh_port_t"},
      env: {"PATH" => "#{scratch}:/nonexistent-seport-gate-path"})

    result["msg"].as_s.must_equal(
      "value of proto must be one of: tcp, udp, dccp, sctp, got: krikri_gate_proto")
  end
end
