require "../minitest_helper"
require "file_utils"

# community.general.cronvar parity, all live-verified against
# ansible-playbook 2.19.11 on this host (2026-10-01, krikri-playbook
# generator round 33 re-sweep):
#
#   - an unsupported parameter is rejected by real's argument spec
#     ("Unsupported parameters for (community.general.cronvar) module:
#     <name>. Supported parameters include: ...") - the module name is
#     the spelling AS WRITTEN in the task, and the option list is sorted
#     (this needs the engine's argspec table, so it runs a playbook);
#   - CronVar.__init__ resolves cron_file and fails when its parent
#     directory is not a directory, BEFORE the module's own
#     "You must specify 'value'" check and before anything is written
#     (this plugin used to CREATE the missing parent instead);
#   - CronVar.write() opens the file unguarded, so an unwritable
#     cron_file ends the module with an uncaught OSError, which the
#     controller reports as "Task failed: Module failed: <errno text>".

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String) : String
  playbook = File.tempname("cronvar-spec", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  output.to_s
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "cronvar argument spec" do
  it "rejects a hallucinated option with real's unsupported-parameters wording" do
    output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: hallucinated user
            community.general.cronvar:
              cron_file: krikri-spec-unused
              name: FOO
              value: bar
              user_bogus: me
            ignore_errors: true
    YAML

    output.must_include("Unsupported parameters for (community.general.cronvar) module: user_bogus. " \
                        "Supported parameters include: backup, cron_file, insertafter, insertbefore, name, state, user, value.")
  end

  it "names the module the way the task spelled it" do
    output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: short spelling
            cronvar:
              name: FOO
              value: bar
              bogus: x
            ignore_errors: true
    YAML

    output.must_include("Unsupported parameters for (cronvar) module: bogus.")
  end
end

describe "cronvar cron_file parent directory" do
  it "fails when the parent directory does not exist, instead of creating it" do
    base = PluginSpecHelper.tmp_path("cronvar-missing-parent")
    FileUtils.rm_rf(base)

    result = PluginSpecHelper.run("cronvar", {
      "name"      => "MAILTO",
      "value"     => "admin@example.com",
      "cron_file" => File.join(base, "sub", "vars"),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Parent directory '#{File.join(base, "sub")}' does not exist for cron_file: '#{File.join(base, "sub", "vars")}'")
    File.exists?(base).must_equal(false)
  end

  it "resolves a relative cron_file against /etc/cron.d in the same message" do
    result = PluginSpecHelper.run("cronvar", {
      "name"      => "MAILTO",
      "value"     => "admin@example.com",
      "cron_file" => "krikri-spec-missing-dir/vars",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Parent directory '/etc/cron.d/krikri-spec-missing-dir' does not exist for cron_file: 'krikri-spec-missing-dir/vars'")
  end

  it "beats the module's own missing-value check, like real's constructor" do
    result = PluginSpecHelper.run("cronvar", {
      "name"      => "MAILTO",
      "cron_file" => "/krikri/definitely/not/here/vars",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Parent directory '/krikri/definitely/not/here' does not exist")
  end
end

describe "cronvar cron_file write failure" do
  it "reports real's uncaught-OSError shape when the file cannot be written" do
    # root ignores the mode bits, so there is nothing to observe there.
    skip "running as root: the mode bits do not deny the write" if PluginSpecHelper.running_as_root?

    base = PluginSpecHelper.tmp_path("cronvar-write-denied")
    FileUtils.rm_rf(base)
    FileUtils.mkdir_p(base)
    target = File.join(base, "vars")
    File.chmod(base, 0o500)

    result = PluginSpecHelper.run("cronvar", {
      "name"      => "MAILTO",
      "value"     => "admin@example.com",
      "cron_file" => target,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Task failed: Module failed: [Errno 13] Permission denied: '#{target}'")
  ensure
    File.chmod(base, 0o700) if base && File.exists?(base)
    FileUtils.rm_rf(base) if base && Dir.exists?(base)
  end
end
