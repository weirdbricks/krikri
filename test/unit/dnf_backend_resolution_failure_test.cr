require "../minitest_helper"
require "file_utils"
require "json"

# Real's dnf ACTION plugin (which every `dnf:` task and every `yum:` task -
# a deprecated redirect to the dnf module since ansible-core 2.19.11's
# ansible_builtin_runtime.yml dropped modules/yum.py entirely - runs through)
# resolves its backend dispatch from use_backend or, for auto/yum, the host's
# pkg_mgr fact. Round 5310001 (kyleabenson.mssql's "Install the EPEL repo rpm"
# yum: task on Ubuntu 22.04, pkg_mgr apt) showed krikri shelling `yum` and
# failing with a module-level "Failed to install packages" while real failed
# at the ACTION level with its literal two-element tuple:
#
#   Could not detect which major revision of dnf is in use, ...
#   You should manually specify use_backend ... dnf5 backend})
#
# (the stray `})` inside the second element is upstream source's own typo,
# byte-copied from the live 2.19.11 capture). These specs pin the plugin wire
# shape; the console rendering is pinned end to end in
# test/integration/dnf_action_backend_resolution_test.cr.
TUPLE_MSGS = [
  "Could not detect which major revision of dnf is in use, which is required to determine module backend.",
  "You should manually specify use_backend to tell the module whether to use the dnf4 or dnf5 backend})",
]

TUPLE_DETAIL = "Action failed: ('#{TUPLE_MSGS[0]}', '#{TUPLE_MSGS[1]}')"

private def with_fake_pkg_shim(name : String, &)
  shim_dir = PluginSpecHelper.tmp_path("fake-#{name}-backend")
  Dir.mkdir_p(shim_dir)
  File.write("#{shim_dir}/#{name}", "#!/bin/sh\ncat <<'KRIKRI_FAKE_EOF'\nDependencies resolved.\n================================================================================\n Transaction Summary\n================================================================================\n\nComplete!\nKRIKRI_FAKE_EOF\n")
  File.chmod("#{shim_dir}/#{name}", 0o755)
  PluginSpecHelper::ENV_MUTEX.synchronize do
    old_path = ENV["PATH"]?
    ENV["PATH"] = "#{shim_dir}:#{old_path}"
    begin
      yield
    ensure
      old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
    end
  end
ensure
  FileUtils.rm_r(shim_dir) if shim_dir
end

describe "dnf/yum backend resolution failure (round 5310001)" do
  it "fails a yum task at the action level with the real tuple on a non-dnf pkg_mgr fact" do
    result = PluginSpecHelper.run("yum",
      {"name" => "epel-release", "state" => "present"},
      vars: {"ansible_pkg_mgr" => "apt"})

    result["failed"]?.try(&.as_bool?).must_equal(true)
    result["msg"].as_a.map(&.as_s).must_equal(TUPLE_MSGS)
    result["ansible_facts"].as_h["pkg_mgr"].as_s.must_equal("apt")
    result["_ansible_action_level"].as_bool.must_equal(true)
    result["_ansible_error_detail"].as_s.must_equal(TUPLE_DETAIL)
    # The module never dispatches - no rc/failures module-crash keys.
    result["rc"]?.must_be_nil
  end

  it "fails a dnf task the same way" do
    result = PluginSpecHelper.run("dnf",
      {"name" => "epel-release", "state" => "present"},
      vars: {"ansible_pkg_mgr" => "apt"})

    result["failed"]?.try(&.as_bool?).must_equal(true)
    result["msg"].as_a.map(&.as_s).must_equal(TUPLE_MSGS)
    result["ansible_facts"].as_h["pkg_mgr"].as_s.must_equal("apt")
    result["_ansible_action_level"].as_bool.must_equal(true)
    result["_ansible_error_detail"].as_s.must_equal(TUPLE_DETAIL)
  end

  it "detects dnf as a valid fact-backed backend (transaction still runs)" do
    with_fake_pkg_shim("dnf") do
      result = PluginSpecHelper.run("dnf",
        {"name" => "fake-pkg", "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      # A successful module's wire result carries no `failed` key at all.
      result["failed"]?.must_be_nil
      result["_ansible_error_detail"]?.must_be_nil
      result["msg"].as_s?.must_equal("")
    end
  end

  it "does not consult the fact when an explicit use_backend is given" do
    with_fake_pkg_shim("dnf") do
      result = PluginSpecHelper.run("dnf",
        {"name" => "fake-pkg", "state" => "present", "use_backend" => "dnf"},
        vars: {"ansible_pkg_mgr" => "apt"})

      result["failed"]?.must_be_nil
      result["_ansible_error_detail"]?.must_be_nil
    end
  end

  # Real falls back to an on-demand setup fact fetch for a fact-less host,
  # which a remote module binary cannot perform - the probe-based previous
  # behavior is a deliberate gap (see RpmPackage's comment).
  it "keeps the previous no-fact probe behavior" do
    with_fake_pkg_shim("dnf") do
      result = PluginSpecHelper.run("dnf",
        {"name" => "fake-pkg", "state" => "present"})

      result["failed"]?.must_be_nil
      result["_ansible_error_detail"]?.must_be_nil
    end
  end
end
