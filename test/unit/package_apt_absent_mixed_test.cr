require "../minitest_helper"
require "file_utils"
require "json"

# `package:` (apt backend) state=absent with a MIXED name list - one
# installed, one not - reported ok and removed nothing, because the
# absent branch gated on `is_installed` (all names installed, the
# present branch's question) instead of apt.py's own remove() rule:
# build the removal list from ONLY the packages whose dpkg status shows
# installed, run `apt-get remove` on just that list, and exit
# changed=False when the list is empty. Live-verified against
# ansible-playbook: `package: {name: [iptables, libiptc0], state:
# absent}` with only iptables installed reports changed=1 and removes
# iptables. The plugin binary is exercised for real against shimmed
# dpkg-query/apt-get on PATH (same pattern as
# package_apt_locate_miss_test.cr's fake apt-get), because the
# installed-subset selection lives inside the plugin file whose
# bottom-of-file entry point defeats a plain require.

INSTALLED_ABSENT_NAME = "krikri-absent-installed-612"
MISSING_ABSENT_NAME   = "krikri-absent-missing-612"

# Shims dpkg-query to report only INSTALLED_ABSENT_NAME as installed
# ("ii ..."), nothing for any other name, and apt-get to append its
# arguments to <shim_dir>/apt-get-args so the spec can assert which
# package names the plugin actually passed to remove.
private def with_absent_status_shims(shim_dir : String, &)
  Dir.mkdir_p(shim_dir)
  record = "#{shim_dir}/apt-get-args"
  dq_script = <<-SH
    #!/bin/sh
    for a in "$@"; do
      if [ "$a" = "#{INSTALLED_ABSENT_NAME}" ]; then
        printf 'ii  1.0-1 %s\\n' "$a"
      fi
    done
    SH
  File.write("#{shim_dir}/dpkg-query", dq_script)
  File.chmod("#{shim_dir}/dpkg-query", 0o755)
  File.write("#{shim_dir}/apt-get", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '#{record}'\nexit 0\n")
  File.chmod("#{shim_dir}/apt-get", 0o755)
  PluginSpecHelper::ENV_MUTEX.synchronize do
    old_path = ENV["PATH"]?
    ENV["PATH"] = "#{shim_dir}:#{old_path}"
    begin
      yield record
    ensure
      old_path ? (ENV["PATH"] = old_path) : (ENV.delete("PATH"))
    end
  end
ensure
  FileUtils.rm_r(shim_dir) if shim_dir
end

describe "package:/apt absent mixed-list removal (installed subset only)" do
  serial!

  it "removes only the installed names and reports changed for a mixed list" do
    with_absent_status_shims(PluginSpecHelper.tmp_path("absent-shims")) do |record|
      result = PluginSpecHelper.run("package",
        {"name" => "#{INSTALLED_ABSENT_NAME},#{MISSING_ABSENT_NAME}", "state" => "absent", "use" => "apt"})

      result["changed"].as_bool.must_equal(true)
      result.as_h.has_key?("failed").must_equal(false)
      result["msg"].as_s.must_equal("Package #{INSTALLED_ABSENT_NAME} #{MISSING_ABSENT_NAME} removed")

      command_line = File.read(record)
      command_line.includes?(INSTALLED_ABSENT_NAME).must_equal(true)
      command_line.includes?(MISSING_ABSENT_NAME).must_equal(false)
    end
  end

  it "reports changed=false without calling apt-get when nothing is installed" do
    with_absent_status_shims(PluginSpecHelper.tmp_path("absent-none-shims")) do |record|
      result = PluginSpecHelper.run("package",
        {"name" => "#{MISSING_ABSENT_NAME},#{MISSING_ABSENT_NAME}-2", "state" => "absent", "use" => "apt"})

      result["changed"].as_bool.must_equal(false)
      result.as_h.has_key?("failed").must_equal(false)
      File.exists?(record).must_equal(false)
    end
  end
end
