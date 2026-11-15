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

  # getenforce/getsebool/setsebool shims plus a python3 that reports both
  # SELinux bindings importable: the boolean failure branches only run on
  # a host where the library gate and the SELinux-enabled check both pass,
  # which no CI host guarantees, so the CLI tools are faked instead.
  private def with_seboolean_shims(getsebool_exit : Int32, getsebool_output : String,
                                   setsebool_exit : Int32, &)
    bin_dir = PluginSpecHelper.tmp_path("seboolean-shims")
    Dir.mkdir_p(bin_dir)
    scripts = {
      "getenforce" => "#!/bin/sh\necho Enforcing\n",
      "getsebool"  => "#!/bin/sh\necho '#{getsebool_output}'\nexit #{getsebool_exit}\n",
      "setsebool"  => "#!/bin/sh\nexit #{setsebool_exit}\n",
      "python3"    => "#!/bin/sh\nprintf 'exe=/usr/bin/python3\\nselinux=yes\\nsemanage=yes\\n'\n",
    }
    scripts.each do |name, body|
      path = File.join(bin_dir, name)
      File.write(path, body)
      File.chmod(path, 0o755)
    end
    yield bin_dir
  end

  # Ansible's get_boolean_value failure calls fail_json(msg=...) without
  # the name/persistent/state result dict, so a failed task registers only
  # failed/msg/changed/exception (run against ansible.posix 2.1.0 on
  # ansible-core 2.21.6). krikri used to leak those three extras through the
  # failed result.
  it "fails with Ansible's bare fail_json shape when getsebool cannot resolve the boolean" do
    with_seboolean_shims(1, "enqrie: boolean not found", 0) do |bin_dir|
      result = PluginSpecHelper.run("seboolean", {
        "name"       => "enqrie",
        "state"      => "false",
        "persistent" => "false",
      }, env: {"PATH" => "#{bin_dir}:/usr/bin:/bin"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Failed to determine current state for boolean enqrie")
      keys = result.as_h.keys
      ["name", "persistent", "state"].each { |key| keys.includes?(key).must_equal(false) }
    end
  end

  it "reports a setsebool failure with Ansible's bool wording and no extras" do
    with_seboolean_shims(0, "enqrie --> off", 1) do |bin_dir|
      result = PluginSpecHelper.run("seboolean", {
        "name"       => "enqrie",
        "state"      => "true",
        "persistent" => "false",
      }, env: {"PATH" => "#{bin_dir}:/usr/bin:/bin"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Failed to set boolean enqrie to True")
      keys = result.as_h.keys
      ["name", "persistent", "state"].each { |key| keys.includes?(key).must_equal(false) }
    end
  end
end
