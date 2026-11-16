require "../minitest_helper"
require "file_utils"

# Regression spec for plugins/gem.cr's check-mode handling (issue #1346).
#
# Real community.general gem.py declares supports_check_mode=True and its
# install()/uninstall() open with `if module.check_mode: return`, so a
# --check task still runs exists() (`gem list`, which can fail hard) and
# then reports the usual changed/ok answer without running the mutating
# `gem` command at all. kpg's 000006-multi-gem-chaos leaned on exactly
# that: a gem whose install would fail (unresolvable source, no registry
# entry) reports changed under --check in Ansible, while krikri ran the
# install for real and failed the task.
describe "gem plugin check mode" do
  # The shim below is found through the process-wide PATH.
  serial!

  # `--version` feeds the RubyGems probe (>= 2.5.2 enables --norc), `list`
  # reports whatever the test seeded into the state file, and every
  # install/uninstall invocation is recorded so the test can prove check
  # mode never touched the host.
  GEM_SHIM = <<-SH
    #!/bin/sh
    DB="${KRIKRI_FAKE_GEM_DB:?}"
    case "$1" in
      --version) echo "3.5.0"; exit 0;;
      list) grep '^gemtest (' "$DB" 2>/dev/null; exit 0;;
      install|uninstall) echo "$*" >> "$DB.mutations"; exit 0;;
    esac
    exit 0
    SH

  private def with_gem_shim(&)
    bin_dir = File.tempname("krikri-gem-check-mode")
    Dir.mkdir_p(bin_dir)
    gem = File.join(bin_dir, "gem")
    File.write(gem, GEM_SHIM)
    File.chmod(gem, 0o755)

    db = PluginSpecHelper.tmp_path("gem-check-mode-db")
    File.delete(db) if File.exists?(db)
    previous_path = ENV["PATH"]?
    previous_db = ENV["KRIKRI_FAKE_GEM_DB"]?
    ENV["PATH"] = "#{bin_dir}:#{ENV["PATH"]?}"
    ENV["KRIKRI_FAKE_GEM_DB"] = db
    begin
      yield db
    ensure
      previous_path ? (ENV["PATH"] = previous_path) : ENV.delete("PATH")
      previous_db ? (ENV["KRIKRI_FAKE_GEM_DB"] = previous_db) : ENV.delete("KRIKRI_FAKE_GEM_DB")
      FileUtils.rm_r(bin_dir)
      File.delete(db) if File.exists?(db)
      File.delete("#{db}.mutations") if File.exists?("#{db}.mutations")
    end
  end

  # The issue's own parameter set: gem_source is a local .gem path that
  # need not exist, because gem.py never reaches the install command in
  # check mode.
  private GEM_PARAMS = {
    "name"         => "gemtest",
    "gem_source"   => "/tmp/kpg-work/sub",
    "include_doc"  => "True",
    "norc"         => "True",
    "user_install" => "True",
    "build_flags"  => "eifxzc",
  }

  private def mutations(db : String) : Array(String)
    path = "#{db}.mutations"
    File.exists?(path) ? File.read(path).lines.map(&.strip).reject(&.empty?) : [] of String
  end

  it "reports a missing gem changed under --check without running gem install" do
    with_gem_shim do |db|
      result = PluginSpecHelper.run("gem", GEM_PARAMS.merge({"_ansible_check_mode" => "True"}))

      result.as_h.has_key?("failed").must_equal(false)
      result["changed"].as_bool.must_equal(true)
      result["name"].as_s.must_equal("gemtest")
      mutations(db).must_equal([] of String)
    end
  end

  it "reports an already-installed gem unchanged under --check" do
    with_gem_shim do |db|
      File.write(db, "gemtest (1.0)\n")
      result = PluginSpecHelper.run("gem", GEM_PARAMS.merge({"_ansible_check_mode" => "True"}))

      result.as_h.has_key?("failed").must_equal(false)
      result["changed"].as_bool.must_equal(false)
      mutations(db).must_equal([] of String)
    end
  end

  it "still runs gem install when check mode is off" do
    with_gem_shim do |db|
      result = PluginSpecHelper.run("gem", GEM_PARAMS)

      result.as_h.has_key?("failed").must_equal(false)
      result["changed"].as_bool.must_equal(true)
      mutations(db).size.must_equal(1)
      mutations(db).first.must_include("install")
    end
  end

  it "reports state=absent under --check without running gem uninstall" do
    with_gem_shim do |db|
      params = GEM_PARAMS.merge({"state" => "absent", "_ansible_check_mode" => "True"})

      File.write(db, "gemtest (1.0)\n")
      removed = PluginSpecHelper.run("gem", params)
      removed["changed"].as_bool.must_equal(true)

      File.delete(db)
      kept = PluginSpecHelper.run("gem", params)
      kept["changed"].as_bool.must_equal(false)

      mutations(db).must_equal([] of String)
    end
  end
end
