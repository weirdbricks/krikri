require "../minitest_helper"

# Pins plugins/seboolean.cr's failure wording for a boolean the target's
# policy does not define (kpg issue #1301). Real ansible.posix.seboolean 2.1.0
# reads the persistent branch through semanage_bool_exists() and the
# non-persistent branch through security_get_boolean_active(), so only the
# persistent branch fails with semanage's "not defined in persistent policy"
# text. The shims put the plugin on a SELinux host where `getenforce` reports
# Enforcing and `getsebool` cannot resolve the name, which no ordinary dev
# host can offer.
describe "seboolean plugin persistent unknown boolean (issue 1301)" do
  private def write_shim(dir : String, name : String, body : String) : Nil
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(path, 0o755)
  end

  private def selinux_shims(dir : String, getsebool_body : String) : Nil
    # The plugin's library gate asks the target's python3 whether real
    # seboolean.py's two imports would succeed.
    write_shim(dir, "python3", %(printf 'exe=/usr/bin/python3\\nselinux=yes\\nsemanage=yes\\n'))
    write_shim(dir, "getenforce", %(echo Enforcing))
    write_shim(dir, "getsebool", getsebool_body)
  end

  private def run_with_shims(name : String, getsebool_body : String) : JSON::Any
    scratch = PluginSpecHelper.tmp_path("sebool-1301-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(scratch)
    selinux_shims(scratch, getsebool_body)

    PluginSpecHelper.run("seboolean",
      {"name" => name, "state" => "false", "persistent" => "true"},
      env: {"PATH" => "#{scratch}:/nonexistent-issue1301-path"})
  end

  it "fails with semanage's unknown-boolean wording and no extras" do
    result = run_with_shims("girroy", "exit 1")

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("SELinux boolean girroy is not defined in persistent policy")
    result["name"]?.must_be_nil
    result["persistent"]?.must_be_nil
    result["state"]?.must_be_nil
  end

  it "still reports name/persistent/state on a successful change" do
    scratch = PluginSpecHelper.tmp_path("sebool-1301-change-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(scratch)
    selinux_shims(scratch, %(echo 'girroy --> on'))
    write_shim(scratch, "setsebool", "exit 0")

    result = PluginSpecHelper.run("seboolean",
      {"name" => "girroy", "state" => "false", "persistent" => "true"},
      env: {"PATH" => "#{scratch}:/nonexistent-issue1301-path"})

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    result["name"].as_s.must_equal("girroy")
    result["persistent"].as_bool.must_equal(true)
    result["state"].as_bool.must_equal(false)
  end
end
