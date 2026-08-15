require "../spec_helper"
require "file_utils"

# Read-only - just runs plain commands and inspects captured output, never
# touches the filesystem outside spec/tmp or mutates host state. Commands
# are chosen to need no shell quoting, since command.cr's own parse_command
# is a naive whitespace split (documented limitation, not this fix's
# concern).

describe "command plugin" do
  it "rstrips a trailing newline from stdout, matching real Ansible's own AnsibleModule.run_command()" do
    result = PluginSpecHelper.run("command", {"cmd" => "echo hello"})

    result["stdout"].as_s.should eq("hello")
  end

  it "does not strip internal newlines, only the trailing one" do
    result = PluginSpecHelper.run("command", {"cmd" => "seq 1 3"})

    result["stdout"].as_s.should eq("1\n2\n3")
  end

  it "leaves stdout as-is when there is no trailing newline" do
    result = PluginSpecHelper.run("command", {"cmd" => "printf %s no-newline"})

    result["stdout"].as_s.should eq("no-newline")
  end

  it "does not try to restore the original working directory afterwards (and so can't crash if that directory becomes inaccessible)" do
    # Real bug found benchmarking robertdebock.nextcloud's own
    # `Configure nextcloud` task (`chdir: /var/www/html/nextcloud,
    # become_user: www-data`): the plugin used to save `Dir.current` up
    # front and `Dir.cd` back to it after running the command -
    # completely unnecessary, since this process exits right after
    # `execute` returns and never runs further code in its own original
    # cwd. On a real remote become_user invocation the process starts
    # with cwd inherited from the SSH login user's home (root's,
    # `/root`, mode 700) - restoring to that path as an unprivileged
    # become_user with no permission on `/root` raised an uncaught
    # `Dir.cd` exception AFTER the real command had already run
    # successfully, crashing an otherwise-successful task. Reproduced
    # here without needing a real become_user: delete the process's own
    # starting directory before it even calls `Dir.cd(chdir)` - any
    # attempt to `Dir.cd` back to that now-nonexistent path afterward
    # would raise (ENOENT, not EACCES, but the same "restore blows up"
    # failure class), which the fix avoids entirely by not restoring.
    original = File.join(Dir.tempdir, "crystal-ansible-spec-original-#{Random.rand(1_000_000)}")
    target = File.join(Dir.tempdir, "crystal-ansible-spec-chdir-target-#{Random.rand(1_000_000)}")
    Dir.mkdir(target) unless Dir.exists?(target)
    Dir.mkdir(original) unless Dir.exists?(original)
    saved_cwd = Dir.current

    Dir.cd(original)
    Dir.delete(original)

    begin
      result = PluginSpecHelper.run("command", {"cmd" => "echo ok", "chdir" => target})
      result["changed"].as_bool.should be_true
      result["stdout"].as_s.should eq("ok")
    ensure
      Dir.cd(saved_cwd)
      FileUtils.rm_rf(target)
    end
  end

  it "expands a leading ~ in creates: before checking existence, matching real Ansible's expanduser" do
    # Real bug found benchmarking geerlingguy.composer: its own
    # composer_home_path default is the literal string '~/.composer',
    # fed straight into `creates={{ composer_home_path }}/vendor/...`.
    # Checking that string against the filesystem literally (no `~`
    # expansion) can never match, so the task reported changed: true on
    # every single run and never converged.
    home = ENV["HOME"]? || "/root"
    marker = File.join(home, "crystal-ansible-spec-tilde-marker")
    File.write(marker, "present")

    result = PluginSpecHelper.run("command", {"cmd" => "echo should-be-skipped", "creates" => "~/crystal-ansible-spec-tilde-marker"})

    result["changed"].as_bool.should be_false
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end
end
