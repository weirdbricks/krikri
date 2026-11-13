require "../minitest_helper"

# Message texts live-verified against ansible-core's
# dpkg_selections.py argument_spec:
#   "value of selection must be one of: install, hold, deinstall, purge,
#    got: bogus" (choices in the argument_spec's declaration order)
#   "missing required arguments: selection" (plural, even for one param)
describe "dpkg_selections plugin" do
  # The missing-package probe and the set-selection step shell out to the
  # host's real dpkg, so a concurrently running spec's PATH shim would make
  # both answer for the wrong binary. The shim specs serialize among
  # themselves, so this one has to opt in too.
  serial!

  it "fails with real-Ansible wording for an invalid selection" do
    result = PluginSpecHelper.run("dpkg_selections", {"name" => "bash", "selection" => "bogus"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of selection must be one of: install, hold, deinstall, purge, got: bogus")
  end

  it "fails with plural 'missing required arguments' when name is missing" do
    result = PluginSpecHelper.run("dpkg_selections", {"selection" => "hold"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: name")
  end

  it "fails with plural 'missing required arguments' when selection is missing" do
    result = PluginSpecHelper.run("dpkg_selections", {"name" => "bash"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: selection")
  end

  # #951: the kpg podman round ran this module in a Rocky container.
  # Ansible resolves dpkg via get_bin_path(required=True) at the top of
  # main(), before it reads any selection, so there it fails on the
  # missing executable. Probing the package first reported the
  # missing-package message instead.
  it "fails the dpkg executable lookup before the package probe" do
    scratch = PluginSpecHelper.tmp_path("dpkg-selections-nodpkg")
    Dir.mkdir_p(scratch)
    %w[/sbin /usr/sbin /usr/local/sbin].each do |dir|
      skip "#{dir}/dpkg exists on this host, dpkg cannot be hidden" if File::Info.executable?(File.join(dir, "dpkg"))
    end

    result = PluginSpecHelper.run("dpkg_selections",
      {"name" => "coreutils", "selection" => "hold"},
      env: {"PATH" => "#{scratch}:/nonexistent-krikri-dpkg-path"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_match(/\AFailed to find required executable "dpkg" in paths: /)
  end

  it "still reports the missing-package failure when dpkg is installed" do
    skip "no dpkg on this host" unless Process.find_executable("dpkg")

    result = PluginSpecHelper.run("dpkg_selections",
      {"name" => "krikri-no-such-package-951", "selection" => "hold"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Failed to find package 'krikri-no-such-package-951' to perform selection 'hold'.")
  end
end
