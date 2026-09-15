require "../spec_helper"

# Regression spec for apt's module-arg validation, added in 0.9.1086.
# Found via the podman-diff harness
# (testing/podman-diff/cases/package_edge_cases.yml, case P2): real
# Ansible's apt module rejects any parameter outside its argument_spec
# at module-arg validation - notably `use:`, which the `package` ACTION
# PLUGIN consumes to pick a backend and never forwards to the apt
# module - while this engine silently ignored unknown keys and ran the
# task anyway (failed=False where real ansible-playbook failed the
# task). Driven through the real plugin binary via PluginSpecHelper;
# the validation fires before any apt-get access, so it is provable on
# a non-Debian host.
describe "apt: unsupported parameter rejection" do
  it "rejects use: (a package action-plugin param, not an apt module param)" do
    result = PluginSpecHelper.run("apt", {
      "name"  => "bash",
      "state" => "present",
      "use"   => "no-such-backend-zzz",
    })

    result["failed"].as_bool.should be_true
    result["changed"].as_bool.should be_false
    result["msg"].as_s.should contain("Unsupported parameters for (ansible.builtin.apt) module: use.")
  end

  it "names every unsupported key, sorted, for multiple offenders" do
    result = PluginSpecHelper.run("apt", {
      "name"  => "bash",
      "state" => "present",
      "use"   => "apt",
      "zebra" => "1",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("module: use, zebra.")
  end

  it "still accepts every documented apt parameter, including hyphenated aliases" do
    # The validation must not reject the params real Ansible's own
    # argspec allows (canonical + alias spellings). We can't cheaply
    # prove a full install, so drive a task whose param set is otherwise
    # inert: a package that doesn't exist fails the INSTALL, not the
    # arg validation - the msg must NOT be "Unsupported parameters".
    result = PluginSpecHelper.run("apt", {
      "name"                         => "krikri-no-such-package-zzz",
      "state"                        => "present",
      "update-cache"                 => "false",
      "default-release"              => "stable",
      "install-recommends"           => "true",
      "allow-downgrade"              => "false",
      "allow_unauthenticated"        => "false",
      "dpkg_options"                 => "force-confdef,force-confold",
      "force_apt_get"                => "true",
      "lock_timeout"                 => "60",
      "update_cache_retries"         => "5",
      "update_cache_retry_max_delay" => "12",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should_not contain("Unsupported parameters")
  end
end
