require "../minitest_helper"
require "file_utils"

# Issue #1413 (allenluce.python3): `apt: name=python3.6` reported changed
# on jammy where ansible-playbook failed "No package matching 'python3.6'
# is available". apt-cache falls back to an unanchored POSIX regex over
# every package name when no package carries the argument exactly, so
# `apt-cache policy python3.6` prints libcasa-python3-6's stanza - a real
# candidate, 3.4.0-2build1 - before the two dead python3.6 remnants.
# Reading the first Candidate: line as the requested name's made the
# name look installable to the candidate pre-flight, and apt-get's own
# regex fallback then really installed libcasa-python3-6 (cold run
# changed, warm run ok because it was by then already installed).
# python-apt's cache lookup, which ansible's apt.py resolves names with,
# is exact - live-verified against ansible-playbook 2.21.6 in check mode:
# it fails the task before any apt-get run.
#
# The plugin binary is exercised against a shimmed apt-cache (same
# pattern as apt_latest_unknown_name_test.cr) that reproduces jammy's
# regex-fallback output for the miss and the exact stanza for a name
# that does exist.

private def with_regex_fallback_shims(&)
  dir = PluginSpecHelper.tmp_path("fake-apt-regex-fallback")
  log = PluginSpecHelper.tmp_path("apt-get-regex-fallback-invocations")
  FileUtils.rm_r(dir) if File.exists?(dir)
  File.delete(log) if File.exists?(log)
  Dir.mkdir_p(dir)

  File.write(File.join(dir, "apt-cache"), <<-'SH')
    #!/bin/sh
    if [ "$1" = policy ]; then
      case "$2" in
        python3.6)
          printf 'libcasa-python3-6:\n  Installed: (none)\n  Candidate: 3.4.0-2build1\n  Version table:\n     3.4.0-2build1 500\n        500 http://archive.ubuntu.com/ubuntu jammy/universe amd64 Packages\nlibpython3.6-stdlib:\n  Installed: (none)\n  Candidate: (none)\n  Version table:\npython3.6-2to3:\n  Installed: (none)\n  Candidate: (none)\n  Version table:\n'
          ;;
        htop)
          printf 'htop:\n  Installed: (none)\n  Candidate: 3.4.1-5\n  Version table:\n     3.4.1-5 500\n'
          ;;
        *)
          echo "N: Unable to locate package $2" >&2
          ;;
      esac
    elif [ "$1" = showpkg ]; then
      case "$2" in
        python3.6)
          printf 'Package: libcasa-python3-6\nVersions: \n3.4.0-2build1 (/var/lib/apt/lists/jammy_universe)\n\nReverse Depends: \nDependencies: \nProvides: \nReverse Provides: \n'
          ;;
        *)
          printf 'Package: %s\nVersions: \n\nReverse Depends: \nDependencies: \nProvides: \nReverse Provides: \n' "$2"
          ;;
      esac
    fi
    exit 0
    SH
  File.write(File.join(dir, "dpkg-query"), "#!/bin/sh\nexit 1\n")
  File.write(File.join(dir, "apt-get"), "#!/bin/sh\necho \"$@\" >> \"#{log}\"\nexit 0\n")
  File.write(File.join(dir, "apt-mark"), "#!/bin/sh\nexit 0\n")
  ["apt-cache", "dpkg-query", "apt-get", "apt-mark"].each do |name|
    File.chmod(File.join(dir, name), 0o755)
  end

  env = {"PATH" => "#{dir}:/usr/bin:/bin"}.to_json
  begin
    yield env, log
  ensure
    FileUtils.rm_r(dir) if File.exists?(dir)
  end
end

private def apt_get_install_calls(log : String) : Array(String)
  return [] of String unless File.exists?(log)
  File.read_lines(log).select(&.includes?(" install "))
end

describe "apt name resolution ignores apt-cache's regex fallback (issue 1413)" do
  it "fails a missing name whose regex matches another package, before apt-get" do
    with_regex_fallback_shims do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "python3.6",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("No package matching 'python3.6' is available")
      result.as_h.has_key?("cache_updated").must_equal(false)
      apt_get_install_calls(log).empty?.must_equal(true)
    end
  end

  it "fails the same name in check mode instead of reporting a change" do
    with_regex_fallback_shims do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"                => "python3.6",
        "state"               => "present",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("No package matching 'python3.6' is available")
      apt_get_install_calls(log).empty?.must_equal(true)
    end
  end

  it "fails state=latest the same way" do
    with_regex_fallback_shims do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "python3.6",
        "state"        => "latest",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("No package matching 'python3.6' is available")
      apt_get_install_calls(log).empty?.must_equal(true)
    end
  end

  # install() resolves cache[name] before the version, so a pin on a
  # missing name fails with the name miss, not the pin's own wording.
  it "fails a pinned version of the missing name with the name miss" do
    with_regex_fallback_shims do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "python3.6=3.4.0-2build1",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("No package matching 'python3.6' is available")
      apt_get_install_calls(log).empty?.must_equal(true)
    end
  end

  # The exact-name path is untouched: its own stanza still resolves, so
  # the install goes ahead (check mode pins the resolved candidate onto
  # the simulate command like ansible's install() does).
  it "still resolves the exact name's own stanza" do
    with_regex_fallback_shims do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"                => "htop",
        "state"               => "present",
        "_ansible_check_mode" => "true",
        "_environment"        => env,
      })

      (result["failed"]?.try(&.as_bool?) || false).must_equal(false)
      result["changed"].as_bool.must_equal(true)
      apt_get_install_calls(log).any?(&.includes?("htop=3.4.1-5")).must_equal(true)
    end
  end

  # A pin on a name that does exist but lacks the version keeps ansible's
  # own version_installable wording (live-verified: the exact-name
  # cache lookup succeeds first).
  it "keeps the version_installable wording for a known name's bad pin" do
    with_regex_fallback_shims do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "htop=9.9",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("no available installation candidate for htop=9.9")
      apt_get_install_calls(log).empty?.must_equal(true)
    end
  end
end
