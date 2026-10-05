require "../minitest_helper"

# Pins plugins/seboolean.cr's library gate against
# ansible.posix.seboolean 2.19.11: the Ansible module binds libselinux and
# libsemanage at import time and fails through missing_required_lib()
# when either is absent - before the SELinux-enabled check and before
# any parameter's runtime use, so on a host without those Python bindings
# EVERY seboolean task fails, whatever ignore_selinux_state says. Found
# via the kpg32 generator sweep, where all 15 seboolean playbooks reported
# this failure while this plugin reported an unchanged success.
#
# The gate probes the TARGET's own python3 for the same two modules, so
# the expectation below depends on what the test host actually has.
describe "seboolean plugin python library gate" do
  def python_probe : Tuple(String, Bool, Bool)?
    ["python3", "python"].each do |interpreter|
      next unless Process.find_executable(interpreter)
      script = <<-PYTHON
        import os, sys
        print("exe=" + os.path.realpath(sys.executable))
        for name in ("selinux", "semanage"):
            try:
                __import__(name)
                print(name + "=yes")
            except Exception:
                print(name + "=no")
        PYTHON
      output = IO::Memory.new
      status = Process.run(interpreter, {"-c", script}, output: output, error: Process::Redirect::Close)
      next unless status.success?

      found = {} of String => String
      output.to_s.each_line do |line|
        key, _, value = line.strip.partition("=")
        found[key] = value unless key.empty?
      end
      return {found["exe"]? || interpreter, found["selinux"]? == "yes", found["semanage"]? == "yes"}
    end
    nil
  end

  def missing_library_message(library : String, python : String) : String
    "Failed to import the required Python library (#{library}) on #{System.hostname}'s Python #{python}. " \
    "Please read the module documentation and install it in the appropriate location. " \
    "If the required library is installed, but Ansible is using the wrong Python interpreter, " \
    "please consult the documentation on ansible_python_interpreter"
  end

  it "fails with Ansible's missing_required_lib wording when a binding is absent" do
    probe = python_probe
    skip "host has no python to probe with" unless probe
    python, has_selinux, has_semanage = probe

    result = PluginSpecHelper.run("seboolean", {
      "name"                 => "krikri_no_such_boolean",
      "state"                => "false",
      "ignore_selinux_state" => "true",
    })

    if !has_selinux
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal(missing_library_message("libselinux-python", python))
    elsif !has_semanage
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal(missing_library_message("libsemanage-python or python3-libsemanage", python))
    else
      # Both bindings are importable, so the gate is transparent and the
      # task proceeds to the SELinux-state handling instead.
      skip "host has both SELinux python bindings installed"
    end
  end

  it "validates arguments before probing for the SELinux bindings" do
    result = PluginSpecHelper.run("seboolean", {"name" => "krikri_no_such_boolean"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: state")
  end

  it "rejects a state that is not boolean-ish" do
    result = PluginSpecHelper.run("seboolean", {"name" => "krikri_no_such_boolean", "state" => "krikri_maybe"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("argument 'state' of type bool could not be converted to a bool")
  end
end
