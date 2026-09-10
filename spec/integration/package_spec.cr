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
