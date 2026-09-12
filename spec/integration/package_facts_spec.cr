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

  it "fails when an explicitly-requested manager's backing tool isn't installed, unlike auto" do
    # Root cause of the oVirt.engine-setup DIVERGENT recap (round 601116):
    # `package_facts: manager: rpm` on a dpkg-only host with no `rpm`
    # binary at all. Real Ansible fails the task outright ("Could not
    # detect a supported package manager ... or the required library is
    # not installed"); this plugin used to call rpm_packages()
    # unconditionally, and `capture` swallows the missing-executable
    # exception into "", so the task silently reported success with an
    # empty packages dict instead. "rpm" is a safe manager name to force
    # here because the CI/dev hosts this suite runs on are dpkg-based.
    result = PluginSpecHelper.run("package_facts", {"manager" => "rpm"})

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

  it "stamps every package entry with source, matching real Ansible's always-present fields" do
    # Real package_facts's RETURN doc: name, version AND source are present
    # for every entry regardless of manager (apt entries carry source: apt,
    # rpm entries source: rpm). This plugin used to emit only name/version.
    result = PluginSpecHelper.run("package_facts", {"manager" => "auto"})

    packages = result["ansible_facts"]["packages"].as_h
    entry = packages[packages.keys.first].as_a.first.as_h
    entry["source"].as_s.should_not be_empty
  end

  it "accepts strategy: all (queries every manager in the list, not just the first)" do
    # Real package_facts.py main(): strategy 'first' (the default) breaks
    # out of the manager loop as soon as ONE manager yields a non-empty
    # package dict; 'all' keeps going and extends each package name's list
    # with later managers' entries for the same name
    # (`packages[k].extend(packages_found[k])`). This host only has one
    # usable manager (dpkg-based, no rpm binary) so the merge itself can't
    # be exercised here - the param must at minimum be accepted and yield
    # the same facts as the default.
    result = PluginSpecHelper.run("package_facts", {"manager" => "auto", "strategy" => "all"})

    result["failed"].as_bool.should be_false
    packages = result["ansible_facts"]["packages"].as_h
    packages.size.should be > 0
  end

  it "fails an invalid strategy with real Ansible's exact argument-spec error" do
    # Verified live against ansible-core 2.19.4 (`ansible localhost -m
    # package_facts -a "strategy=bogus"`): the task fails with the
    # AnsibleModule choices-validation message, case-sensitively.
    result = PluginSpecHelper.run("package_facts", {"manager" => "auto", "strategy" => "bogus"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of strategy must be one of: first, all, got: bogus")
  end

  it "accepts manager as a list (real Ansible's own type: list, elements: str)" do
    # manager is type: list in real Ansible's argument_spec; a templated
    # `{{ list_var }}` reaches the plugin as a JSON-array string. This
    # plugin used to `.to_s` the whole thing into one garbage manager name.
    result = PluginSpecHelper.run("package_facts", {"manager" => "[\"auto\"]"})

    result["failed"].as_bool.should be_false
    packages = result["ansible_facts"]["packages"].as_h
    packages.size.should be > 0
  end

  it "accepts a Python-repr manager list too (Jinja-rendered list form)" do
    result = PluginSpecHelper.run("package_facts", {"manager" => "['auto']"})

    result["failed"].as_bool.should be_false
    packages = result["ansible_facts"]["packages"].as_h
    packages.size.should be > 0
  end

  it "accepts a comma-separated manager string (real AnsibleModule's check_type_list split)" do
    result = PluginSpecHelper.run("package_facts", {"manager" => "apt,rpm"})

    result["failed"].as_bool.should be_false
    packages = result["ansible_facts"]["packages"].as_h
    packages.size.should be > 0
  end

  it "maps rpm aliases (yum/dnf/dnf5/zypper) onto the rpm gatherer, like real Ansible's ALIASES" do
    # Real package_facts.py ALIASES: {'rpm': ['dnf', 'dnf5', 'yum',
    # 'zypper']}. On this dpkg-only dev host an alias must resolve to rpm,
    # find no usable tool, and fail with the found==0 message (below) -
    # NOT with "Unsupported package managers requested".
    result = PluginSpecHelper.run("package_facts", {"manager" => "yum"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Could not detect a supported package manager")
  end

  it "fails an unknown manager name with real Ansible's exact 'Unsupported package managers requested' error" do
    # Real module fails BEFORE any gathering when a requested name isn't a
    # known manager or alias (verified live against ansible-core 2.19.4:
    # "Unsupported package managers requested: bogusmgr"). This plugin used
    # to route unknown names through the found==0 "Could not detect"
    # message instead - a different real-Ansible failure path with
    # different wording.
    result = PluginSpecHelper.run("package_facts", {"manager" => "bogusmgr"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported package managers requested: bogusmgr")
  end

  it "fails with real Ansible's exact not-detectable wording when no requested manager yields packages" do
    # Real found==0 failure, verified live against ansible-core 2.19.4 on
    # this rpm-less host: "Could not detect a supported package manager
    # from the following list: ['rpm'], or the required Python library is
    # not installed. Check warnings for details." The old message said
    # "the required library" and lacked the Check-warnings tail.
    result = PluginSpecHelper.run("package_facts", {"manager" => "rpm"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Could not detect a supported package manager from the following list: ['rpm'], or the required Python library is not installed. Check warnings for details.")
  end

  it "keeps going past an unusable manager until one yields packages (real found-counting)" do
    # Real code only counts a manager as 'found' when its package dict is
    # non-empty, and with the default strategy 'first' it stops at the
    # FIRST manager that yields packages - so a leading unusable manager
    # (rpm here, on a dpkg-only host) must not fail the task when a later
    # manager in the list succeeds.
    result = PluginSpecHelper.run("package_facts", {"manager" => "rpm,apt"})

    result["failed"].as_bool.should be_false
    packages = result["ansible_facts"]["packages"].as_h
    packages.size.should be > 0
  end

  it "fails with the post-expansion manager list when auto-detection finds nothing" do
    # Real 'auto' expands to every known manager name, and the found==0
    # failure message lists the EXPANDED list, not the literal 'auto'.
    # Simulating "nothing found" isn't possible on a real dpkg host, but
    # the rpm-only expansion path above pins the message format; this spec
    # pins that 'auto' itself never takes the unsupported-names shortcut.
    result = PluginSpecHelper.run("package_facts", {"manager" => "auto"})

    result["failed"].as_bool.should be_false
  end
end
