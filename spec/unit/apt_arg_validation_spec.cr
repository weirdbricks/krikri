require "../spec_helper"

# Pins plugins/apt.cr's AnsibleModule argument-validation surface
# against real ansible.builtin.apt (bookworm ansible-core 2.14 apt.py;
# live-diffed via the podman-diff apt_edge_cases harness). The
# previously hand-rolled wording diverged from real 2.14 in three ways:
# the mutually-exclusive check did not exist at all (A6 - real fails
# name:+upgrade: at module setup, before any apt-get runs), state
# choices only recognized a third of real's list (A7 - 2.14 also
# accepts build-dep and fixed), and the unsupported-parameters message
# was built from a hardcoded param list instead of the argspec (A8).
describe "apt plugin argument validation" do
  it "fails name+upgrade at setup with real's mutually-exclusive wording (A6)" do
    result = PluginSpecHelper.run("apt", {"name" => "curl", "upgrade" => "yes"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: deb|package|upgrade")
  end

  it "counts upgrade as given even when falsy, like AnsibleModule's is-not-None check" do
    result = PluginSpecHelper.run("apt", {"name" => "curl", "upgrade" => "false"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: deb|package|upgrade")
  end

  it "rejects a state outside real 2.14's choice list with the choices wording (A7)" do
    result = PluginSpecHelper.run("apt", {"name" => "curl", "state" => "installed-nowhere"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: absent, build-dep, fixed, latest, present, got: installed-nowhere")
  end

  it "accepts every choice real 2.14's argspec lists, including build-dep and fixed" do
    # Accepted at module setup (the failure these pins guard against is
    # the old "Invalid state:" fall-through) - each then fails later on
    # this machine for its own reasons, which the apt_edge_cases real
    # side does too and which these specs don't need to re-pin.
    ["absent", "build-dep", "fixed", "latest", "present"].each do |state|
      result = PluginSpecHelper.run("apt", {"name" => "krikri-arg-validation-probe", "state" => state})
      result["msg"].as_s.should_not contain("value of state must be one of")
    end
  end

  it "rejects unsupported parameters with the argspec-driven message including the alias parenthetical (A8)" do
    result = PluginSpecHelper.run("apt", {"name" => "curl", "krikri_not_an_apt_param" => "yes"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported parameters for (ansible.builtin.apt) module: krikri_not_an_apt_param. " \
                                 "Supported parameters include: allow_change_held_packages, allow_downgrade, " \
                                 "allow_unauthenticated, autoclean, autoremove, cache_valid_time, clean, deb, " \
                                 "default_release, dpkg_options, fail_on_autoremove, force, force_apt_get, " \
                                 "install_recommends, lock_timeout, only_upgrade, package, policy_rc_d, purge, " \
                                 "state, update_cache, update_cache_retries, update_cache_retry_max_delay, upgrade " \
                                 "(allow-downgrade, allow-downgrades, allow-unauthenticated, allow_downgrades, " \
                                 "default-release, install-recommends, name, pkg, update-cache).")
  end

  it "fails a non-boolean bool-typed param with parameters.py wording (A9)" do
    result = PluginSpecHelper.run("apt", {"name" => "curl", "install_recommends" => "sometimes"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("argument 'install_recommends' is of type <class 'str'> and we were unable to convert to bool: " \
                                      "The value 'sometimes' is not a valid boolean.  Valid booleans include: ")
  end

  it "still accepts the alias names real's argspec lists" do
    result = PluginSpecHelper.run("apt", {"pkg" => "curl", "krikri_not_an_apt_param" => "yes"})

    result["msg"].as_s.should contain("Unsupported parameters for (ansible.builtin.apt) module: krikri_not_an_apt_param")
  end
end
