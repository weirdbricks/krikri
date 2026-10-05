require "../minitest_helper"
require "file_utils"

# Regression spec for `package:`'s apt install/remove commands missing
# Ansible's default dpkg options (`-o Dpkg::Options::=--force-confdef
# -o Dpkg::Options::=--force-confold`, apt.py's DPKG_OPTIONS).
# Ansible's apt module threads those options into every apt-get call it
# builds; package.cr's own separate apt dispatch didn't, so an install
# whose package ships a conffile that already exists on disk unowned made
# dpkg stop and prompt for the conflict on stdin - and with this engine's
# /dev/null stdin the prompt died with "end of file on stdin at conffile
# prompt", failing the whole install where ansible-playbook resolved
# the same conflict silently to "keep current". Found via
# weareinteractive.docker (round 979177): the role templates
# /etc/default/docker BEFORE `package: docker-ce` runs, so the fresh-host
# install hit the prompt on both cold and warm and the "Installing
# packages" task failed while Ansible reported changed.
# apt.cr's own apt-get call sites already carried the options; this pins
# the OS-agnostic package plugin's separate ones.

# Same stub-PATH shape as package_cache_valid_time_spec: a stub dir whose
# `apt-get` records its argv (one shell-quoted arg per line) and exits 0,
# and whose `dpkg-query` prints a controllable status line so the
# plugin's installed-state pre-check sees installed or not-installed.
private def with_stub_path(dpkg_query_output : String, &) : Nil
  dir = File.join(Dir.tempdir, "krikri-package-dpkg-opts-#{Random.rand(1_000_000)}")
  marker = File.join(dir, "apt-get-argv")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "apt-get"), "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$KRIKRI_FAKE_MARKER\"\nexit 0\n")
  File.write(File.join(dir, "dpkg-query"), "#!/bin/sh\nprintf '%s\\n' \"$KRIKRI_FAKE_DPKG_QUERY_OUTPUT\"\nexit 0\n")
  File.chmod(File.join(dir, "apt-get"), 0o755)
  File.chmod(File.join(dir, "dpkg-query"), 0o755)
  yield "#{dir}:/usr/bin:/bin", marker
ensure
  FileUtils.rm_rf(dir) if dir
end

private def env_param(path : String, marker : String, dpkg_query_output : String) : String
  {"PATH" => path, "KRIKRI_FAKE_MARKER" => marker, "KRIKRI_FAKE_DPKG_QUERY_OUTPUT" => dpkg_query_output}.to_json
end

describe "package plugin apt dpkg options" do
  it "installs with Ansible's default force-confdef/force-confold dpkg options" do
    with_stub_path(dpkg_query_output: "") do |path, marker|
      result = PluginSpecHelper.run("package", {
        "use"          => "apt",
        "name"         => "docker-ce",
        "state"        => "present",
        "_environment" => env_param(path, marker, ""),
      })

      result["changed"].as_bool.must_equal(true)
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      argv = File.read(marker).gsub("\n", " ")
      argv.must_include("-o Dpkg::Options::=--force-confdef")
      argv.must_include("-o Dpkg::Options::=--force-confold")
    end
  end

  it "honors an explicit dpkg_options param the way Ansible's package action plugin forwards it" do
    with_stub_path(dpkg_query_output: "") do |path, marker|
      result = PluginSpecHelper.run("package", {
        "use"          => "apt",
        "name"         => "docker-ce",
        "state"        => "present",
        "dpkg_options" => "force-confold",
        "_environment" => env_param(path, marker, ""),
      })

      result["changed"].as_bool.must_equal(true)
      argv = File.read(marker).gsub("\n", " ")
      argv.must_include("-o Dpkg::Options::=--force-confold")
      argv.wont_include("force-confdef")
    end
  end

  it "removes with the same default dpkg options (apt.py's remove path carries them too)" do
    # dpkg-query reports the package as installed ("ii ...") so the
    # remove branch actually runs its apt-get call.
    with_stub_path(dpkg_query_output: "ii  1.0  docker-ce") do |path, marker|
      result = PluginSpecHelper.run("package", {
        "use"          => "apt",
        "name"         => "docker-ce",
        "state"        => "absent",
        "_environment" => env_param(path, marker, "ii  1.0  docker-ce"),
      })

      result["changed"].as_bool.must_equal(true)
      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      argv = File.read(marker).gsub("\n", " ")
      argv.must_include("remove")
      argv.must_include("-o Dpkg::Options::=--force-confdef")
      argv.must_include("-o Dpkg::Options::=--force-confold")
    end
  end
end
