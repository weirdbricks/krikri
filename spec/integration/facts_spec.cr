require "../spec_helper"

describe "facts plugin" do
  describe "ansible_python fact" do
    # Round 133 (robertdebock.mitogen): ansible_facts['python'] was a
    # flat string (the interpreter path) under an invented key
    # (ansible_python) that didn't match real Ansible's shape at all -
    # real Ansible's own PythonFactCollector exposes a single nested
    # dict under `ansible_python` with version.major/minor/micro,
    # version_info, executable, has_sslcontext, and type. The role's
    # own `python{{ ansible_facts['python'].version.major }}` command
    # construction resolved to the literal string "pythonundefined"
    # instead of "python3" against the old flat-string shape.
    it "is a nested dict matching real Ansible's PythonFactCollector shape" do
      result = PluginSpecHelper.run("facts", {} of String => String)

      python = result["ansible_facts"]["ansible_python"]
      python["version"]["major"].as_i.should be >= 3
      python["version"]["minor"].as_i.should be >= 0
      python["version_info"].as_a.size.should eq(5)
      python["executable"].as_s.should contain("python")
      python["has_sslcontext"].as_bool.should be_true
    end
  end

  describe "ansible_virtualization_role fact" do
    # Real bug found benchmarking Ansible-Security-Compliance's
    # rhel7-role-hipaa (round823): its own audit-rule tasks gate on
    # `ansible_virtualization_role != "guest" or ansible_virtualization_
    # type != "docker"`. This fact was entirely missing before -
    # `ansible_virtualization_role` resolved as undefined, and the
    # `when:` raised "Error while evaluating conditional" and crashed
    # the whole run outright instead of just skipping/running that one
    # task.
    it "is set alongside ansible_virtualization_type, not left undefined" do
      result = PluginSpecHelper.run("facts", {} of String => String)

      result["ansible_facts"]["ansible_virtualization_type"].as_s.should_not be_empty
      result["ansible_facts"]["ansible_virtualization_role"].as_s.should_not be_empty
    end
  end

  describe "ansible_python_version fact" do
    # Round 134 (prometheus.prometheus.alertmanager): real Ansible ALSO
    # exposes a separate flat `ansible_python_version` ("major.minor.micro",
    # e.g. "3.10.12") alongside the nested `ansible_python` dict above -
    # both co-exist in real `setup` output. This was missing entirely
    # (round 133 removed it along with the bogus flat ansible_python
    # invention, but ansible_python_version itself is real and legitimate).
    # prometheus.prometheus's own `_common_dependencies` var does
    # `ansible_facts['python_version'] is version('3', '<')` to pick
    # python-apt vs python3-apt - with the fact missing/undefined, the
    # version test silently evaluated true, always picking the wrong
    # (nonexistent on modern Ubuntu) `python-apt` package name.
    it "is a flat major.minor.micro string" do
      result = PluginSpecHelper.run("facts", {} of String => String)

      version = result["ansible_facts"]["ansible_python_version"].as_s
      version.should match(/^\d+\.\d+\.\d+$/)
    end
  end

  describe "ansible_python_interpreter fact" do
    # Found via a real-host round on azavea.pip (a dependency of several
    # azavea.* roles: celery, curator, aws-cli, beaver): this flat magic
    # var - real Ansible's own auto-discovered interpreter path
    # (INTERPRETER_PYTHON=auto, the default since 2.8) - was never set at
    # all, even though gather_python_facts already resolves the exact
    # same executable path into the nested `ansible_python.executable`
    # fact just above. The role's own "Install pip" task uses the common
    # idiom `{{ ansible_python_interpreter if ansible_python_interpreter
    # is defined else 'python' }}` - with the fact missing, `is defined`
    # took the false branch and fell back to the bare literal "python",
    # which doesn't exist as a command on any modern Debian/Ubuntu target
    # (python3-only), failing with "python: No such file or directory"
    # where real Ansible succeeds via its own discovered /usr/bin/python3.
    it "is set to the same executable path as ansible_python.executable" do
      result = PluginSpecHelper.run("facts", {} of String => String)

      interpreter = result["ansible_facts"]["ansible_python_interpreter"].as_s
      executable = result["ansible_facts"]["ansible_python"]["executable"].as_s
      interpreter.should eq(executable)
      interpreter.should contain("python")
    end
  end

  describe "ansible_default_ipv4 fact" do
    # Real bug found benchmarking buluma.checkmk_agent's own `when:
    # ansible_facts['default_ipv4'].gateway is defined`: gather_network_
    # facts parsed `ip -4 route get 1`'s "1.0.0.0 via 192.168.1.1 dev
    # eth0 src 192.168.1.50 uid 0" output for `address` and `interface`
    # (added for an earlier bug, see that fix's own comment) but never
    # for `gateway` at all - the key genuinely didn't exist, so real
    # Ansible's `is defined` check (true - every routable host has a
    # default gateway) evaluated false here, and a `when:`-gated task
    # relying on it was silently skipped instead of run. This spec runs
    # against THIS machine's real network state (skipped if it has no
    # default route at all, e.g. a fully offline sandbox).
    it "includes gateway alongside address/interface, parsed from the real default route" do
      result = PluginSpecHelper.run("facts", {} of String => String)

      default_ipv4 = result["ansible_facts"]["ansible_default_ipv4"]?
      pending! "no default route on this host" unless default_ipv4 && default_ipv4["address"]?

      default_ipv4["gateway"]?.should_not be_nil
      default_ipv4["gateway"].as_s.should match(/^\d+\.\d+\.\d+\.\d+$/)
    end
  end
end
