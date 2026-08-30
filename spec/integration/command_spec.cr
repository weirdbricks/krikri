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

  # Real bug found benchmarking konstruktoid.docker_rootless (0.9.618):
  # a nonexistent executable raised a Crystal exception, caught by this
  # plugin's own rescue - but that early return had no rc/stdout at
  # all (only stderr), where real Ansible's run_command() catches
  # ENOENT itself and returns a normal (rc=2, stdout='', stderr=...)
  # result. A `failed_when: false`-guarded probe of an optional binary
  # correctly avoided failing the TASK, but a later `.stdout`/`.rc`
  # reference on the same registered result was genuinely undefined
  # instead of real Ansible's empty string/2.
  it "populates rc/stdout even when the executable itself doesn't exist (ENOENT), matching real Ansible's run_command()" do
    result = PluginSpecHelper.run("command", {"cmd" => "/does/not/exist/anywhere --version"})

    result["rc"].as_i64.should eq(2)
    result["stdout"].as_s.should eq("")
  end

  it "does not strip internal newlines, only the trailing one" do
    result = PluginSpecHelper.run("command", {"cmd" => "seq 1 3"})

    result["stdout"].as_s.should eq("1\n2\n3")
  end

  it "leaves stdout as-is when there is no trailing newline" do
    result = PluginSpecHelper.run("command", {"cmd" => "printf %s no-newline"})

    result["stdout"].as_s.should eq("no-newline")
  end

  it "treats a standalone backslash (whitespace on both sides) as a line-continuation marker, not a space-escape" do
    # Real bug found benchmarking buluma.influxdb2 (round 155): the
    # role's own task is `command: influx ping \ --host "{{ influxdb_host
    # }}"` - a documented, intentional Ansible authoring convention for
    # writing a long command: as if it were multiple lines. Real
    # Ansible's task-arg parser (ansible.parsing.splitter.split_args,
    # which runs BEFORE Jinja templating) treats a bare `\` token
    # (delimited by whitespace/string-boundaries on both sides) as a
    # line-continuation marker and drops it entirely, then rejoins the
    # remaining words with single spaces - `influx ping --host <url>`.
    # parse_command previously treated every unquoted `\` uniformly as
    # "escape the next character", so `\ ` became "escape this space
    # into the current token", producing a malformed ` --host` argv
    # element (stray leading space) that real influx's cobra-based CLI
    # parser rejected as an unknown subcommand - while real
    # ansible-playbook succeeded, a genuine engine divergence live on
    # Rocky Linux 9.6.
    result = PluginSpecHelper.run("command", {"cmd" => %q(printf '[%s]' hi \ --world there)})

    result["stdout"].as_s.should eq("[hi][--world][there]")
  end

  it "still decodes a backslash that escapes a specific adjacent character (not whitespace-delimited)" do
    # Regression guard for the fix above: a backslash immediately
    # followed by a non-whitespace character (e.g. find's own `\;`
    # exec terminator) must still be decoded to that literal character,
    # matching real Ansible's shlex.split() - only a backslash that is
    # its OWN whitespace-delimited token is a line-continuation marker.
    result = PluginSpecHelper.run("command", {
      "cmd" => %q(find /tmp -maxdepth 0 -exec /usr/bin/printf '[%s]' {} \;),
    })

    result["stdout"].as_s.should eq("[/tmp]")
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
    original = File.join(Dir.tempdir, "krikri-playbook-spec-original-#{Random.rand(1_000_000)}")
    target = File.join(Dir.tempdir, "krikri-playbook-spec-chdir-target-#{Random.rand(1_000_000)}")
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
    marker = File.join(home, "krikri-playbook-spec-tilde-marker")
    File.write(marker, "present")

    result = PluginSpecHelper.run("command", {"cmd" => "echo should-be-skipped", "creates" => "~/krikri-playbook-spec-tilde-marker"})

    result["changed"].as_bool.should be_false
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end
end
