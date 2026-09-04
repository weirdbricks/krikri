require "../spec_helper"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

# Stub control/a2mod binaries with the same CLI surface as the real
# Debian scripts, so the plugin's whole decision flow (apache2ctl -M
# substring check, already-state short-circuits, check mode, configcheck
# fallback, failure messages) is exercised hermetically. The real
# a2enmod/a2dismod/apache2ctl behavior was verified live against a real
# Ubuntu 22.04 host with the actual apache2 package - see
# KNOWN_MISSING.md's apache2_module entry.
private FAKE_BIN_DIR = File.join(TMP_DIR, "apache2-fake-bin")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
  Dir.mkdir_p(FAKE_BIN_DIR) unless Dir.exists?(FAKE_BIN_DIR)

  apache2ctl = File.join(FAKE_BIN_DIR, "apache2ctl")
  File.write(apache2ctl, <<-'SCRIPT')
    #!/bin/sh
    if [ "$1" = "-M" ]; then
      if [ -n "$FAKE_CONFIG_BROKEN" ]; then
        echo "AH00534: no MPM loaded" >&2
        exit 1
      fi
      cat "$FAKE_MODULES_FILE"
      exit 0
    fi
    if [ "$1" = "-V" ]; then
      echo "Server version: Apache/2.4.52 (Ubuntu)"
      if [ -n "$FAKE_THREADED" ]; then
        echo "  threaded:     yes"
      else
        echo "  threaded:     no"
      fi
      exit 0
    fi
    exit 64
    SCRIPT
  File.chmod(apache2ctl, 0o755)

  a2enmod = File.join(FAKE_BIN_DIR, "a2enmod")
  File.write(a2enmod, <<-'SCRIPT')
    #!/bin/sh
    name="$1"
    if [ "$name" = "does_not_exist" ]; then
      echo "ERROR: Module ${name} does not exist!" >&2
      exit 1
    fi
    if grep -q " ${name}_module " "$FAKE_MODULES_FILE"; then
      echo "Module ${name} already enabled"
    else
      echo "Enabling module ${name}."
      sed -i "1a\\ ${name}_module (shared)" "$FAKE_MODULES_FILE"
    fi
    SCRIPT
  File.chmod(a2enmod, 0o755)

  a2dismod = File.join(FAKE_BIN_DIR, "a2dismod")
  File.write(a2dismod, <<-'SCRIPT')
    #!/bin/sh
    if [ "$1" = "-f" ]; then
      shift
    fi
    name="$1"
    if ! grep -q " ${name}_module " "$FAKE_MODULES_FILE"; then
      echo "Module ${name} is already disabled"
    else
      echo "Disabling module ${name}."
      sed -i "/ ${name}_module /d" "$FAKE_MODULES_FILE"
    fi
    SCRIPT
  File.chmod(a2dismod, 0o755)
end

private def modules_path(name : String) : String
  File.join(TMP_DIR, name)
end

# A loaded-modules file shaped like `apache2ctl -M` output: the plugin's
# enable test is a plain " <identifier>" substring check on it.
private def write_modules_file(path : String, lines : Array(String))
  File.write(path, ["Loaded Modules:", ""].concat(lines).join("\n") + "\n")
end

private def env_for(modules_file : String, extra : Hash(String, String) = {} of String => String) : String
  env = {
    "PATH"              => "#{FAKE_BIN_DIR}:#{ENV["PATH"]}",
    "FAKE_MODULES_FILE" => modules_file,
  }.merge(extra)
  env.to_json
end

describe "apache2_module plugin" do
  it "enables a module" do
    file = modules_path("apache2-enable.txt")
    write_modules_file(file, [" status_module (shared)"])

    result = PluginSpecHelper.run("apache2_module", {
      "name"         => "rewrite",
      "_environment" => env_for(file),
    })

    result["changed"].as_bool.should be_true
    result["result"].as_s.should eq("Module rewrite enabled")
    File.read(file).should contain(" rewrite_module (shared)")
  end

  it "is idempotent when the module is already enabled" do
    file = modules_path("apache2-idempotent.txt")
    write_modules_file(file, [" rewrite_module (shared)"])

    result = PluginSpecHelper.run("apache2_module", {
      "name"         => "rewrite",
      "_environment" => env_for(file),
    })

    result["changed"].as_bool.should be_false
    result["result"].as_s.should eq("Module rewrite enabled")
  end

  it "disables a module and is idempotent on a second disable" do
    file = modules_path("apache2-disable.txt")
    write_modules_file(file, [" rewrite_module (shared)"])

    result = PluginSpecHelper.run("apache2_module", {
      "name" => "rewrite", "state" => "absent", "_environment" => env_for(file),
    })
    result["changed"].as_bool.should be_true
    result["result"].as_s.should eq("Module rewrite disabled")
    File.read(file).should_not contain("rewrite_module")

    second = PluginSpecHelper.run("apache2_module", {
      "name" => "rewrite", "state" => "absent", "_environment" => env_for(file),
    })
    second["changed"].as_bool.should be_false
    second["result"].as_s.should eq("Module rewrite disabled")
  end

  it "passes -f to a2dismod when force is set" do
    file = modules_path("apache2-force.txt")
    write_modules_file(file, [" rewrite_module (shared)"])

    result = PluginSpecHelper.run("apache2_module", {
      "name" => "rewrite", "state" => "absent", "force" => "true", "_environment" => env_for(file),
    })

    result["changed"].as_bool.should be_true
    File.read(file).should_not contain("rewrite_module")
  end

  it "reports the would-be change in check mode without touching anything" do
    file = modules_path("apache2-check-mode.txt")
    write_modules_file(file, [" status_module (shared)"])

    result = PluginSpecHelper.run("apache2_module", {
      "name" => "rewrite", "check_mode" => "true", "_environment" => env_for(file),
    })

    result["changed"].as_bool.should be_true
    result["result"].as_s.should eq("Module rewrite enabled")
    File.read(file).should_not contain("rewrite_module")
  end

  it "fails when a2enmod rejects the module" do
    file = modules_path("apache2-bad-module.txt")
    write_modules_file(file, [] of String)

    result = PluginSpecHelper.run("apache2_module", {
      "name" => "does_not_exist", "_environment" => env_for(file),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Failed to run a2enmod for module does_not_exist")
    result["rc"].as_i.should eq(1)
  end

  it "respects an explicit identifier when checking the enabled state" do
    file = modules_path("apache2-identifier.txt")
    write_modules_file(file, [" some_custom_identifier (shared)"])

    result = PluginSpecHelper.run("apache2_module", {
      "name"         => "custom_name",
      "identifier"   => "some_custom_identifier",
      "_environment" => env_for(file),
    })

    result["changed"].as_bool.should be_false
    result["result"].as_s.should eq("Module custom_name enabled")
  end

  it "applies the php identifier workaround automatically" do
    file = modules_path("apache2-php-identifier.txt")
    write_modules_file(file, [" php_module (shared)"])

    result = PluginSpecHelper.run("apache2_module", {
      "name" => "php8.2", "_environment" => env_for(file),
    })

    result["changed"].as_bool.should be_false
    result["result"].as_s.should eq("Module php8.2 enabled")
  end

  it "refuses to enable cgi under a threaded MPM" do
    file = modules_path("apache2-cgi-threaded.txt")
    write_modules_file(file, [" mpm_event_module (shared)"])

    result = PluginSpecHelper.run("apache2_module", {
      "name" => "cgi", "_environment" => env_for(file, {"FAKE_THREADED" => "1"}),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Your MPM seems to be threaded, therefore enabling cgi module is not allowed.")
    File.read(file).should_not contain(" cgi_module")
  end

  it "fails when neither apache2ctl nor apachectl exists" do
    result = PluginSpecHelper.run("apache2_module", {
      "name"         => "rewrite",
      "_environment" => %({"PATH": "/usr/bin:/bin"}),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Neither of apache2ctl nor apachectl found. At least one apache control binary is necessary.")
  end

  it "fails on a broken config without ignore_configcheck" do
    file = modules_path("apache2-broken-config.txt")
    write_modules_file(file, [" status_module (shared)"])

    result = PluginSpecHelper.run("apache2_module", {
      "name" => "rewrite", "_environment" => env_for(file, {"FAKE_CONFIG_BROKEN" => "1"}),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Error executing")
  end

  it "absorbs a broken config with ignore_configcheck and falls back to a2enmod's own wording" do
    file = modules_path("apache2-ignore-configcheck.txt")
    write_modules_file(file, [" status_module (shared)"])

    result = PluginSpecHelper.run("apache2_module", {
      "name"               => "mpm_foo",
      "ignore_configcheck" => "true",
      "_environment"       => env_for(file, {"FAKE_CONFIG_BROKEN" => "1"}),
    })

    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_true
    warnings = result["warnings"].as_a.map(&.as_s)
    warnings.should contain("No MPM module loaded! apache2 reload AND other module actions will fail if no MPM module is loaded immediately.")
  end
end
