require "../spec_helper"

# The package_facts plugin enumerates the real installed packages (read-only).
# On any Unix-like host there is at least one package manager present.
describe "package_facts plugin" do
  it "returns ansible_facts.packages keyed by package name" do
    result = PluginSpecHelper.run("package_facts", {"manager" => "auto"})

    result["failed"].as_bool.should be_false
    packages = result["ansible_facts"]["packages"].as_h
    packages.size.should be > 0

    # Every entry is a list of dicts with name/version.
    first_key = packages.keys.first
    entry = packages[first_key].as_a.first.as_h
    entry["name"].as_s.should_not be_empty
    entry["version"].as_s.should_not be_empty
  end

  it "fails on an unsupported manager" do
    result = PluginSpecHelper.run("package_facts", {"manager" => "bogus"})
    result["failed"].as_bool.should be_true
  end

  it "accepts manager: apt (real Ansible's own distinct, python-apt-backed value), not just auto/dpkg" do
    # Found via a live 100-role confirm round: nvidia.enroot's own
    # `package_facts: manager: apt` (verified live against ansible-core
    # 2.19.12: a real, accepted manager value, not an alias this engine
    # invented) failed outright with "Unsupported package manager: apt"
    # - the case dispatch only ever recognized auto/dpkg/rpm.
    result = PluginSpecHelper.run("package_facts", {"manager" => "apt"})

    result["failed"].as_bool.should be_false
    packages = result["ansible_facts"]["packages"].as_h
    packages.size.should be > 0
  end
end
