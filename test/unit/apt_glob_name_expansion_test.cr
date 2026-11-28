require "../minitest_helper"
require "file_utils"

# Issue #1971 (kevinmagni.zabbix_agent2): apt.py runs every install/remove
# spec through expand_pkgspec_from_fnmatches, which fnmatches a NAME
# carrying any of `*?[]!` against the apt cache's own package names and
# acts on each match - a role's `name: zabbix-agent2-plugin-*` installs
# every plugin package the configured repos carry. This engine looked the
# raw pattern up as a literal package name instead, so the task failed
# with apt.py's plural no-match message where Ansible installed the
# matches (see apt_glob_name_no_match_test.cr for that failure shape).

private def with_apt_glob_expansion_shims(dpkg_installed : String = "", &)
  dir = PluginSpecHelper.tmp_path("fake-apt-glob-expand")
  log = PluginSpecHelper.tmp_path("apt-glob-expand-calls")
  FileUtils.rm_r(dir) if File.exists?(dir)
  File.delete(log) if File.exists?(log)
  Dir.mkdir_p(dir)

  # `apt-cache pkgnames --all-names` is the expansion probe; `policy` then
  # answers both the cache-membership filter (a purely virtual name has no
  # Version table rows) and the per-name candidate resolution the install
  # path runs for every match. The arch-qualified name stands for the
  # multiarch entries real filters out of its fnmatch cache unless the
  # pattern carries one; `krikri-glob-virtual` stands for a name the cache
  # only references (trixie's vim-gnome) that real's fnmatch never yields.
  File.write(File.join(dir, "apt-cache"), <<-SHIM)
    #!/bin/sh
    if [ "$1" = pkgnames ]; then
      echo "krikri-glob-one"
      echo "krikri-glob-two"
      echo "krikri-glob-two:i386"
      echo "krikri-glob-virtual"
      echo "krikri-unrelated"
    elif [ "$1" = policy ]; then
      shift
      for name in "$@"; do
        case "$name" in
          krikri-glob-one|krikri-glob-two)
            echo "$name:"
            echo "  Installed: (none)"
            echo "  Candidate: 1.0"
            echo "  Version table:"
            echo "     1.0 500"
            ;;
          krikri-glob-virtual)
            echo "$name:"
            echo "  Installed: (none)"
            echo "  Candidate: (none)"
            echo "  Version table:"
            ;;
        esac
      done
    fi
    exit 0
    SHIM
  dq = "#!/bin/sh\n"
  dq += "for name in \"$@\"; do\n"
  dq += "  if [ \"$name\" = \"#{dpkg_installed}\" ]; then\n"
  dq += "    echo \"ii 1.0 $name\"\n"
  dq += "  fi\n"
  dq += "done\n"
  dq += "exit 0\n"
  File.write(File.join(dir, "dpkg-query"), dq)
  File.write(File.join(dir, "apt-get"), "#!/bin/sh\necho \"$@\" >> \"#{log}\"\necho \"Reading package lists...\"\necho \"0 upgraded, 2 newly installed, 0 to remove and 0 not upgraded.\"\nexit 0\n")
  File.write(File.join(dir, "apt-mark"), "#!/bin/sh\nexit 0\n")
  ["apt-cache", "dpkg-query", "apt-get", "apt-mark"].each do |name|
    File.chmod(File.join(dir, name), 0o755)
  end

  env = {"PATH" => "#{dir}:/usr/bin:/bin"}.to_json
  begin
    yield env, log
  ensure
    FileUtils.rm_r(dir) if File.exists?(dir)
    File.delete(log) if File.exists?(log)
  end
end

describe "apt wildcard name expansion (issue 1971)" do
  it "installs every package the wildcard matches, with the candidate pinned" do
    with_apt_glob_expansion_shims do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "krikri-glob-*",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"]?.nil?.must_equal(true)
      result["changed"].as_bool.must_equal(true)
      calls = File.read(log)
      calls.must_include(" install ")
      calls.must_include("krikri-glob-one=1.0")
      calls.must_include("krikri-glob-two=1.0")
      calls.includes?("krikri-glob-two:i386").must_equal(false)
    end
  end

  it "matches a bracket class the way fnmatch does" do
    with_apt_glob_expansion_shims do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "[k]rikri-glob-two",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"]?.nil?.must_equal(true)
      calls = File.read(log)
      calls.must_include("krikri-glob-two=1.0")
      calls.includes?("krikri-glob-one").must_equal(false)
    end
  end

  it "removes every installed package the wildcard matches" do
    with_apt_glob_expansion_shims(dpkg_installed: "krikri-glob-two") do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "krikri-glob-*",
        "state"        => "absent",
        "_environment" => env,
      })

      result["failed"]?.nil?.must_equal(true)
      result["changed"].as_bool.must_equal(true)
      calls = File.read(log)
      calls.must_include(" remove ")
      calls.must_include("krikri-glob-two")
      calls.includes?("krikri-glob-one").must_equal(false)
    end
  end

  # Issue #1974: `apt-cache pkgnames --all-names` lists names the cache only
  # REFERENCES (trixie's vim-gnome lives only in gtimelog's Depends:), and
  # real's fnmatch over python-apt's cache never yields those. Expanding to
  # one made a check-mode role task fail "No package matching 'vim-gnome' is
  # available" where ansible installed the pattern's real matches.
  it "leaves out a wildcard match the cache only references" do
    with_apt_glob_expansion_shims do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "krikri-glob-*",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"]?.nil?.must_equal(true)
      calls = File.read(log)
      calls.includes?("krikri-glob-virtual").must_equal(false)
    end
  end

  it "fails a wildcard whose only cache matches are names the cache only references" do
    with_apt_glob_expansion_shims do |env, log|
      result = PluginSpecHelper.run("apt", {
        "name"         => "krikri-glob-v*",
        "state"        => "present",
        "_environment" => env,
      })

      result["failed"]?.try(&.as_bool).must_equal(true)
      result["msg"].as_s.must_equal("No package(s) matching 'krikri-glob-v*' available")
      File.exists?(log).must_equal(false)
    end
  end

  it "treats a bare star name as the no-package no-op real apt.py makes it" do
    with_apt_glob_expansion_shims do |env, log|
      present = PluginSpecHelper.run("apt", {"name" => "*", "state" => "present", "_environment" => env})
      present["failed"]?.nil?.must_equal(true)
      present["changed"].as_bool.must_equal(false)
      absent = PluginSpecHelper.run("apt", {"name" => "*", "state" => "absent", "_environment" => env})
      absent["failed"]?.nil?.must_equal(true)
      absent["changed"].as_bool.must_equal(false)
      File.exists?(log).must_equal(false)
    end
  end
end
