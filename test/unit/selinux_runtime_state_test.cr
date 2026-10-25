require "../minitest_helper"

# Pins plugins/selinux.cr's runtime-state branch against
# ansible.posix.selinux: with the runtime DISABLED, a state of
# enforcing/permissive can reach the kernel only on the next boot, so
# real warns "Reboot is required to set SELinux state to '<state>'" -
# which the controller prints as "[WARNING]: ..." after the PLAY RECAP -
# and exits with reboot_required=true (issue #340: os_hardening-style
# state: permissive tasks on SELinux-runtime-disabled hosts are silent
# in krikri while real prints the warning). Every success exit also
# carries `reboot_required`, false when no reboot is pending.
#
# Both probe paths ride the plugin's env overrides, so each scenario
# points the plugin at its own scratch config/flag files (sandboxes
# without /etc/selinux/config or /sys/fs/selinux can otherwise never
# reach the branch). The libselinux import gate still sits ahead of it,
# which is why the tests skip on a host where importing the bindings
# fails - the kpg34 sweep pins that gate itself.
describe "selinux plugin runtime-state warning" do
  def gate_passes? : Bool
    # Same first-hit order as the plugin's own interpreter discovery
    # (python_lib_gate's INTERPRETER_FALLBACK), trimmed to the entries
    # that differ on common dev machines.
    ["python3.13", "python3", "/usr/bin/python3"].each do |name|
      next unless resolved = Process.find_executable(name)
      status = Process.run(resolved, {"-c", "import selinux"},
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      return status.success?
    end
    false
  end

  private def run_selinux(scratch : String, config_content : String,
                          params : Hash(String, String), enforce_content : String? = nil) : JSON::Any
    config_file = File.join(scratch, "config")
    File.write(config_file, config_content)
    enforce_file = File.join(scratch, "enforce")
    File.write(enforce_file, enforce_content) if enforce_content

    PluginSpecHelper.run("selinux", params,
      env: {"KRIKRI_SELINUX_CONFIG_PATH"  => config_file,
            "KRIKRI_SELINUX_ENFORCE_PATH" => enforce_file})
  end

  it "warns and asks for a reboot when the runtime is disabled and the state differs" do
    skip "host cannot import the selinux bindings, so the gate fails first" unless gate_passes?
    scratch = PluginSpecHelper.tmp_path("selinux-runtime-warn")
    Dir.mkdir_p(scratch)

    result = run_selinux(scratch, "SELINUX=permissive\nSELINUXTYPE=targeted\n",
      {"state" => "permissive", "policy" => "targeted"})

    warnings = result["warnings"]?.try(&.as_a?) || [] of JSON::Any
    warnings.map(&.as_s).must_equal(["Reboot is required to set SELinux state to 'permissive'"])
    result["reboot_required"].as_bool.must_equal(true)
    # The config already says permissive, so the runtime-side branch is
    # the only one that applies - and unlike its setenforce paths it
    # must not flip `changed` (selinux.py only warns there).
    result["changed"].as_bool.must_equal(false)
  end

  it "still warns and writes the config when the config state differs" do
    skip "host cannot import the selinux bindings, so the gate fails first" unless gate_passes?
    scratch = PluginSpecHelper.tmp_path("selinux-runtime-write")
    Dir.mkdir_p(scratch)

    result = run_selinux(scratch, "SELINUX=enforcing\nSELINUXTYPE=targeted\n",
      {"state" => "permissive", "policy" => "targeted"})

    result["changed"].as_bool.must_equal(true)
    warnings = result["warnings"]?.try(&.as_a?) || [] of JSON::Any
    warnings.map(&.as_s).must_equal(["Reboot is required to set SELinux state to 'permissive'"])
    result["reboot_required"].as_bool.must_equal(true)
    File.read(File.join(scratch, "config")).strip
      .must_equal("SELINUX=permissive\nSELINUXTYPE=targeted")
  end

  it "warns in check mode too, with the config write only predicted" do
    skip "host cannot import the selinux bindings, so the gate fails first" unless gate_passes?
    scratch = PluginSpecHelper.tmp_path("selinux-runtime-check")
    Dir.mkdir_p(scratch)

    result = run_selinux(scratch, "SELINUX=enforcing\nSELINUXTYPE=targeted\n",
      {"state" => "permissive", "policy" => "targeted", "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    warnings = result["warnings"]?.try(&.as_a?) || [] of JSON::Any
    warnings.map(&.as_s).must_equal(["Reboot is required to set SELinux state to 'permissive'"])
    result["reboot_required"].as_bool.must_equal(true)
    File.read(File.join(scratch, "config")).strip
      .must_equal("SELINUX=enforcing\nSELINUXTYPE=targeted")
  end

  it "runtime enforcing (flag file '1'): no warning and no reboot" do
    skip "host cannot import the selinux bindings, so the gate fails first" unless gate_passes?
    scratch = PluginSpecHelper.tmp_path("selinux-runtime-enforcing")
    Dir.mkdir_p(scratch)

    result = run_selinux(scratch, "SELINUX=enforcing\nSELINUXTYPE=targeted\n",
      {"state" => "enforcing", "policy" => "targeted"}, enforce_content: "1\n")

    result["warnings"]?.must_be_nil
    result["reboot_required"].as_bool.must_equal(false)
    result["changed"].as_bool.must_equal(false)
  end

  it "runtime permissive (flag file '0'): a matching state stays silent" do
    skip "host cannot import the selinux bindings, so the gate fails first" unless gate_passes?
    scratch = PluginSpecHelper.tmp_path("selinux-runtime-permissive")
    Dir.mkdir_p(scratch)

    result = run_selinux(scratch, "SELINUX=permissive\nSELINUXTYPE=targeted\n",
      {"state" => "permissive", "policy" => "targeted"}, enforce_content: "0\n")

    result["warnings"]?.must_be_nil
    result["reboot_required"].as_bool.must_equal(false)
    result["changed"].as_bool.must_equal(false)
  end

  it "state=disabled against a disabled runtime needs no reboot and no warning" do
    skip "host cannot import the selinux bindings, so the gate fails first" unless gate_passes?
    scratch = PluginSpecHelper.tmp_path("selinux-runtime-disabled")
    Dir.mkdir_p(scratch)

    result = run_selinux(scratch, "SELINUX=disabled\nSELINUXTYPE=targeted\n",
      {"state" => "disabled"})

    result["warnings"]?.must_be_nil
    result["reboot_required"].as_bool.must_equal(false)
    result["changed"].as_bool.must_equal(false)
  end
end
