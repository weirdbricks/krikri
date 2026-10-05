require "../minitest_helper"
require "file_utils"
require "json"

# round994003 kop_rocky: ansible-core 2.19.11's `dnf:` registers
# [msg, changed, results, rc, failed] on Rocky Linux 9 (the dnf4
# backend's `response` dict order - selinux_helper_packages) while the
# same plugin previously emitted the dnf5 kwargs order
# [results, changed, msg, rc, failed] everywhere. Real actually
# dispatches per backend (its `dnf:` action plugin resolves the host's
# pkg_mgr fact, or an explicit use_backend), so this engine now does too:
# dnf4/yum get the response-dict order, dnf5 keeps the kwargs order that
# key_order_sweep11 pinned on fedora:41.
#
# The transaction shapes are driven against a fake `dnf` on PATH
# replaying a real rockylinux:9 no-op group install capture (see
# rpm_package_group_noop_test for the method).

private def with_fake_dnf(&)
  shim_dir = PluginSpecHelper.tmp_path("fake-dnf-order")
  Dir.mkdir_p(shim_dir)
  File.write("#{shim_dir}/dnf", "#!/bin/sh\ncat <<'KRIKRI_FAKE_DNF_EOF'\nDependencies resolved.\n================================================================================\n Transaction Summary\n================================================================================\n\nComplete!\nKRIKRI_FAKE_DNF_EOF\n")
  File.chmod("#{shim_dir}/dnf", 0o755)
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

describe "dnf plugin - per-backend registered key order (round994003)" do
  serial!

  it "uses the dnf4 response-dict order (msg first) when the pkg_mgr fact says dnf" do
    with_fake_dnf do
      result = PluginSpecHelper.run("dnf",
        {"name" => "@Development tools", "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      # Plugin-level keys: the controller appends `failed: false` last,
      # so the registered shape is [msg, changed, results, rc, failed].
      result.as_h.keys.must_equal(["msg", "changed", "results", "rc"])
      result["msg"].as_s.must_equal("Nothing to do")
      result["changed"].as_bool.must_equal(false)
      result["results"].as_a.must_equal([] of JSON::Any)
      result["rc"].as_i.must_equal(0)
    end
  end

  it "keeps the dnf5 kwargs order (results first) when the backend resolves to dnf5" do
    with_fake_dnf do
      result = PluginSpecHelper.run("dnf",
        {"name" => "@Development tools", "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf5"})

      result.as_h.keys.must_equal(["results", "changed", "msg", "rc"])
    end
  end

  it "resolves the backend via an explicit use_backend: dnf5" do
    with_fake_dnf do
      result = PluginSpecHelper.run("dnf",
        {"name" => "@Development tools", "state" => "present", "use_backend" => "dnf5"})

      result.as_h.keys.must_equal(["results", "changed", "msg", "rc"])
    end
  end

  # The no-fact fallback probes what /usr/bin/dnf symlinks to (real
  # pkg_mgr.py's _check_rh_versions); only meaningful on a host without
  # a dnf5-style symlink.
  it "falls back to the dnf4 order when no pkg_mgr fact exists and the host has no dnf" do
    skip "host has /usr/bin/dnf or /usr/bin/microdnf - the probe would resolve them" if File.exists?("/usr/bin/dnf") || File.exists?("/usr/bin/microdnf")
    with_fake_dnf do
      result = PluginSpecHelper.run("dnf", {"name" => "@Development tools", "state" => "present"})

      result.as_h.keys.must_equal(["msg", "changed", "results", "rc"])
    end
  end

  it "emits the real transaction shape (empty msg kept) on a real install" do
    with_fake_dnf do
      # A group with Install/Upgrade count lines resolves as a real
      # transaction: msg "" (kept - Ansible's exit_json(**response) carries
      # the key), results naming the spec.
      shim_dir = PluginSpecHelper.tmp_path("fake-dnf-order-real")
      Dir.mkdir_p(shim_dir)
      File.write("#{shim_dir}/dnf", "#!/bin/sh\ncat <<'KRIKRI_FAKE_DNF_EOF'\nDependencies resolved.\n================================================================================\n Transaction Summary\n================================================================================\nInstall  418 Packages\n\nComplete!\nKRIKRI_FAKE_DNF_EOF\n")
      File.chmod("#{shim_dir}/dnf", 0o755)
      PluginSpecHelper::ENV_MUTEX.synchronize do
        old_path = ENV["PATH"]?
        ENV["PATH"] = "#{shim_dir}:#{old_path}"
        begin
          result = PluginSpecHelper.run("dnf",
            {"name" => "@Development tools", "state" => "present"},
            vars: {"ansible_pkg_mgr" => "dnf"})
          result.as_h.keys.must_equal(["msg", "changed", "results", "rc"])
          result["changed"].as_bool.must_equal(true)
          result["msg"].as_s.must_equal("")
          result["results"].as_a.first.as_s.must_equal("Installed: @Development tools")
        ensure
          old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
        end
      end
    end
  end
end
