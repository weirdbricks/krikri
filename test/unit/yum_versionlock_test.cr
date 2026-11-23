require "../minitest_helper"

# community.general.yum_versionlock argument-validation order: real
# AnsibleModule validates required/choices at construction, BEFORE the
# module resolves the yum binary or runs `yum versionlock list` - so an
# invalid invocation fails with the argument-spec message even on a host
# without yum (same order the dnf_versionlock sibling implements, see
# alternatives_validation_spec.cr's own block).
describe "yum_versionlock validation order" do
  it "fails with the required-arguments message when name is missing" do
    result = PluginSpecHelper.run("yum_versionlock", {"state" => "present"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: name")
  end

  it "fails with the choices message for an invalid state, before the yum binary check" do
    result = PluginSpecHelper.run("yum_versionlock", {
      "name"  => "bash",
      "state" => "krikri_state",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: present, absent, got: krikri_state")
  end

  it "still fails on the missing yum binary for a valid invocation" do
    empty = PluginSpecHelper.tmp_path("yum-versionlock-empty-path")
    Dir.mkdir(empty)
    searched = [empty, "/usr/bin", "/bin"] +
               %w[/sbin /usr/sbin /usr/local/sbin].select { |dir| Dir.exists?(dir) }
    result = PluginSpecHelper.run("yum_versionlock", {"name" => "bash"},
      env: {"PATH" => "#{empty}:/usr/bin:/bin"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(%(Failed to find required executable "yum" in paths: #{searched.join(":")}))
  end
end

# community.general.yum_versionlock never writes the locklist itself - it
# shells out to yum's versionlock plugin, and on DNF hosts that plugin
# stamps its own wall-clock "# Added lock on <ctime>" comment ahead of the
# NEVRA line. Those bytes are the moment yum ran, so two runs of the same
# play (let alone two engines in two containers, seconds apart) can never
# produce the same file: issue #1712 is that timestamp, not a krikri gap
# (two real ansible runs disagree identically; see KNOWN_MISSING.md). What
# the module DOES own is delegating rather than hand-writing, and skipping
# the add on a second run so no second timestamped block appears.
describe "yum_versionlock delegating the locklist to yum's plugin" do
  it "runs a yum found on PATH and leaves the timestamped locklist to yum" do
    shim_dir = PluginSpecHelper.tmp_path("yum-versionlock-shim")
    Dir.mkdir(shim_dir)
    fake_yum = File.join(shim_dir, "yum")
    File.write(fake_yum, <<-'SH')
      #!/bin/sh
      lock="${KRIKRI_VERSIONLOCK_FILE}"
      [ "$1" = "-q" ] && shift
      [ "$1" = "versionlock" ] || exit 1
      shift
      case "$1" in
        list)
          [ -f "$lock" ] && grep -v '^#' "$lock"
          exit 0 ;;
        add)
          shift
          for pkg in "$@"; do
            printf '\n# Added lock on %s\n%s-0:5.2.26-6.el10.*\n' "$(date '+%a %b %d %H:%M:%S %Y')" "$pkg" >> "$lock"
          done
          exit 0 ;;
      esac
      exit 1
      SH
    File.chmod(fake_yum, 0o755)
    locklist = PluginSpecHelper.tmp_path("versionlock.list")
    env = {
      "PATH"                    => "#{shim_dir}:#{ENV["PATH"]}",
      "KRIKRI_VERSIONLOCK_FILE" => locklist,
    }

    result = PluginSpecHelper.run("yum_versionlock", {"name" => "bash"}, env: env)

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    result["meta"]["packages"].as_a.map(&.as_s).must_equal(["bash"])
    result["meta"]["state"].as_s.must_equal("present")
    File.read(locklist).must_match(/\A\n# Added lock on \w{3} \w{3} [ \d]\d \d\d:\d\d:\d\d \d{4}\nbash-0:5\.2\.26-6\.el10\.\*\n\z/)

    again = PluginSpecHelper.run("yum_versionlock", {"name" => "bash"}, env: env)

    again["failed"]?.must_be_nil
    again["changed"].as_bool.must_equal(false)
    File.read(locklist).must_match(/\A\n# Added lock on .*\nbash-0:5\.2\.26-6\.el10\.\*\n\z/)
  end
end
