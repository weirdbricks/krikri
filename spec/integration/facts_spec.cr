require "../spec_helper"

describe "facts plugin" do
  describe "ansible_python fact" do
    # Round 133 (robertdebock.mitogen): ansible_facts['python'] was a
    # flat string (the interpreter path) under two invented keys
    # (ansible_python/ansible_python_version) that don't exist under
    # those names in real Ansible at all - real Ansible's own
    # PythonFactCollector exposes a single nested dict with
    # version.major/minor/micro, version_info, executable,
    # has_sslcontext, and type. The role's own `python{{
    # ansible_facts['python'].version.major }}` command construction
    # resolved to the literal string "pythonundefined" instead of
    # "python3" against the old flat-string shape.
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
end
