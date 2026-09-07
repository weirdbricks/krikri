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
end
