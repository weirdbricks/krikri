require "../spec_helper"

# The package plugin (ansible.builtin.package) dispatches to the host's
# real package manager. check_mode keeps these side-effect-free.
describe "package plugin" do
  it "accepts state: installed as a synonym for present (real Ansible's own alias)" do
    # Real Ansible's package/dnf/yum modules document state choices as
    # absent, installed, latest, present, removed - "installed"/"removed"
    # are synonyms for "present"/"absent". This engine used to reject
    # "installed" outright with "Invalid state" instead of installing -
    # found via bertvv.rh-base's own `package: state: installed` task
    # (round 60086), which failed here where real Ansible succeeded.
    result = PluginSpecHelper.run("package",
      {"name" => "definitely-not-a-real-package-xyz", "state" => "installed", "check_mode" => "true"})

    result["msg"].as_s.should_not contain("Invalid state")
  end

  it "accepts state: removed as a synonym for absent" do
    result = PluginSpecHelper.run("package",
      {"name" => "definitely-not-a-real-package-xyz", "state" => "removed", "check_mode" => "true"})

    result["msg"].as_s.should_not contain("Invalid state")
  end

  it "fails a use: naming a backend this engine doesn't ship, with real Ansible's message" do
    # Real Ansible's package action plugin checks its controller-side
    # module library and fails before anything runs: live-verified
    # (`ansible localhost -m package -a "name=x state=present
    # use=nonexistentmgr"` => 'Could not find a matching action for the
    # "nonexistentmgr" package manager.'). The validation also precedes
    # module execution, so it fires even without a `name:`.
    result = PluginSpecHelper.run("package",
      {"use" => "homebrew"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Could not find a matching action for the \"homebrew\" package manager.")
  end

  it "use: overrides auto-detection unconditionally (dnf backend honored on an apt host)" do
    # Real Ansible dispatches straight to the `use:`-named module - NOT
    # a fallback: live-verified `use: dnf` on this apt host still ran
    # the dnf module (which then failed on-target for lack of dnf).
    # Here the override picks the dnf backend, whose rpm-based
    # installed-check can't see the dpkg-installed package, so
    # check-mode reports "would install" - where the apt backend (the
    # auto-detected one on this host) reports "already installed".
    result = PluginSpecHelper.run("package",
      {"name" => "bash", "state" => "present", "check_mode" => "true", "use" => "dnf"})

    result["changed"].as_bool.should be_true
    result["msg"].as_s.should contain("Would install")
  end

  it "use: apt selects the apt backend explicitly" do
    result = PluginSpecHelper.run("package",
      {"name" => "bash", "state" => "present", "check_mode" => "true", "use" => "apt"})

    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_false
    result["msg"].as_s.should contain("already installed")
  end

  it "the ansible_package_use variable overrides auto-detection but loses to use:" do
    # Real Ansible 2.17+: the ansible_package_use variable overrides
    # auto-detection, while an explicit `use:` option still takes
    # precedence over the variable.
    with_var = PluginSpecHelper.run("package",
      {"name" => "bash", "state" => "present", "check_mode" => "true"},
      {"ansible_package_use" => "dnf"})
    with_var["changed"].as_bool.should be_true

    with_both = PluginSpecHelper.run("package",
      {"name" => "bash", "state" => "present", "check_mode" => "true", "use" => "apt"},
      {"ansible_package_use" => "dnf"})
    with_both["changed"].as_bool.should be_false
    with_both["msg"].as_s.should contain("already installed")
  end

  it "treats a missing name as a no-op, not a hard error (round 83221)" do
    # adfinis-sygroup.apache's `package: {state: present}` task has no
    # `name:` key at all. Real Ansible's apt backend never hard-fails a
    # missing name (its required_one_of gate is defeated by the
    # upgrade/autoremove defaults) - it exits changed=false. Verified
    # live: `ansible localhost -m package -a "state=present"` => SUCCESS,
    # changed: false.
    result = PluginSpecHelper.run("package",
      {"state" => "present"})

    result["changed"].as_bool.should be_false
    result["failed"].as_bool.should be_false
    result["msg"].as_s.should_not contain("Missing required parameter")
  end

  it "treats an empty-string name as a no-op (round 83246)" do
    # `name: '{{ var }}'` with the var an empty list templates to "[]" or
    # an empty string; real Ansible's apt backend exits changed=false on
    # an empty package list for both present and absent. This engine
    # used to run `apt-get remove` on the empty token and report
    # "Package  removed" (double space) as changed on every run.
    ["", "[]"].each do |empty_name|
      result = PluginSpecHelper.run("package",
        {"name" => empty_name, "state" => "absent"})

      result["changed"].as_bool.should be_false
      result["msg"].as_s.should_not contain("removed")
    end
  end
end
