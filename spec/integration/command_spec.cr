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

  it "resolves a relative creates: against chdir: when both are given, matching real Ansible" do
    # Real divergence found benchmarking kyl191.openvpn's warm run: its
    # "server_keys | Generate CA key" task is
    # `argv: [openssl, req, ...]`, `chdir: "{{ openvpn_key_dir }}"`,
    # `creates: ca-key.pem` - real ansible-playbook resolves the
    # RELATIVE creates: path against chdir: (chdir changes what
    # "relative" means for the whole task, not just the command's own
    # execution), finds ca-key.pem already there, and reports the task
    # ok with changed=0 on the warm pass. The check used to test the
    # raw relative path against the plugin process's own inherited cwd
    # (the SSH session's home) instead, never finding the file and
    # re-running the task on every single warm run (changed=1). The
    # marker file below exists ONLY in chdir, not in the spec process's
    # cwd, so the pre-fix code could never skip here.
    dir = File.tempname("command-creates-chdir-spec")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "ca-key.pem"), "")

    result = PluginSpecHelper.run("command", {"cmd" => "echo should-be-skipped", "chdir" => dir, "creates" => "ca-key.pem"})

    result["changed"].as_bool.should be_false
    result["msg"].as_s.should contain("Did not run command since")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "resolves a relative removes: against chdir: the same way" do
    # Mirror of the creates: fix above - same relative-to-chdir
    # resolution, opposite direction (skip when the file does NOT
    # exist). The marker file exists ONLY in chdir, so the pre-fix
    # code (checking against the process's own cwd) would have found
    # "nothing" there too and skipped for the wrong reason; pointing
    # removes: at a file that DOES exist in chdir proves the check now
    # looks in the right place (task must RUN, not skip).
    dir = File.tempname("command-removes-chdir-spec")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "stale.lock"), "")

    result = PluginSpecHelper.run("command", {"cmd" => "echo ran", "chdir" => dir, "removes" => "stale.lock"})

    result["changed"].as_bool.should be_true
    result["stdout"].as_s.should eq("ran")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "creates: accepts a GLOB pattern, matching real Ansible's glob.glob() check" do
    # Real bug found via appsilon.mount_efs's own "install | build
    # amazon-efs-utils" (`creates: ".../build/amazon-efs-utils*deb"`,
    # the built package's filename varies by version): `File.exists?`
    # alone never matches a path containing `*` (never a literal
    # filename), so the build script re-ran on every single warm
    # rerun instead of correctly no-opping once already built.
    dir = File.tempname("command-creates-glob-spec")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "amazon-efs-utils_1.2.3.deb"), "")

    result = PluginSpecHelper.run("command", {"cmd" => "echo should-be-skipped", "creates" => File.join(dir, "amazon-efs-utils*.deb")})

    result["changed"].as_bool.should be_false
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "creates:/removes: report an ordinary ok result, not a task-level skip" do
    # Live-verified against ansible-core 2.19.4: a creates:-guarded
    # command: that skips reports `ok: [...] => {"changed": false,
    # ...}` and recaps under `ok=`, NEVER `skipping:`/`skipped=` - this
    # codebase's own `skipped: true` on the plugin result used to
    # divert it into the wrong recap bucket entirely (a real, separate
    # divergence from the glob gap above).
    dir = File.tempname("command-creates-not-skipped-spec")
    Dir.mkdir_p(dir)
    marker = File.join(dir, "marker")
    File.write(marker, "")

    result = PluginSpecHelper.run("command", {"cmd" => "echo should-be-skipped", "creates" => marker})

    result["changed"].as_bool.should be_false
    result["msg"].as_s.should contain("Did not run command since")
    result.as_h.has_key?("skipped").should be_false
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # Regression (kyl191.openvpn, 120-author kata round): `argv:` is real
  # Ansible's own alternative to `cmd:`/free-form for avoiding shell
  # quoting entirely - the plugin never recognized it at all, so every
  # argv:-only task failed "Missing required parameter: cmd" before this
  # fix. The JSON-array wire format here matches what
  # playbook_parser.cr's own argv special case now encodes it as (see
  # that file's RAW_COMMAND_MODULES branch) - PluginSpecHelper bypasses
  # the parser and hands the plugin binary its wire params directly.
  it "accepts argv: as an alternative to cmd:, with no shell splitting on its elements" do
    result = PluginSpecHelper.run("command", {"argv" => ["echo", "hello world with spaces"].to_json})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["stdout"].as_s.should eq("hello world with spaces")
  end

  it "still requires cmd/_raw_params/argv - one of the three - to be present" do
    result = PluginSpecHelper.run("command", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Missing required parameter: cmd")
  end

  # Proactive param-coverage pass: real Ansible's `command` still ACCEPTS
  # `executable:` but ignores it entirely, emitting module.warn(...) - the
  # task succeeds normally (via execvp, no shell) and the result carries a
  # top-level "warnings" list with exactly this message. Live-verified
  # against ansible-core 2.19.4. Not previously implemented (the param was
  # silently tolerated with no warning at all). The warning convention
  # matches apache2_module.cr's extra["warnings"] usage.
  it "accepts executable:, ignores it, and emits real Ansible's exact warning" do
    result = PluginSpecHelper.run("command", {"cmd" => "echo hi", "executable" => "/bin/bash"})

    result["failed"]?.try(&.as_bool).should be_falsey
    result["stdout"].as_s.should eq("hi")
    warnings = result["warnings"].as_a.map(&.as_s)
    warnings.should eq(["As of Ansible 2.4, the parameter 'executable' is no longer supported with the 'command' module. Not using '/bin/bash'."])
  end

  it "carries the executable: warning on skip results too, like real module.warn()" do
    # module.warn accumulates into whatever exit_json comes next, so a
    # creates:-skip on the same task also carries the warning (real
    # Ansible behavior - the warn happens at the top of the module's
    # main(), long before the creates: check).
    marker = File.tempname("command-executable-warn-skip")
    File.write(marker, "")

    result = PluginSpecHelper.run("command", {"cmd" => "echo should-be-skipped", "creates" => marker, "executable" => "/bin/bash"})

    result["changed"].as_bool.should be_false
    result["warnings"].as_a.size.should eq(1)
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end

  # Proactive param-coverage pass: real Ansible's `command` documents
  # `stdin_add_newline` as "Whether to append a newline to stdin data"
  # (bool, default yes) - run_command appends '\n' unless it is false.
  # Live-verified against ansible-core 2.19.4: `wc -l` fed "line1\nline2"
  # counts 2 lines by default, 1 with stdin_add_newline: false. Not
  # previously implemented (stdin was sent verbatim, no newline ever).
  it "appends a newline to stdin: by default (stdin_add_newline default true)" do
    result = PluginSpecHelper.run("command", {"cmd" => "wc -l", "stdin" => "line1\nline2"})

    result["stdout"].as_s.should eq("2")
  end

  it "does not append a newline when stdin_add_newline is false" do
    result = PluginSpecHelper.run("command", {"cmd" => "wc -l", "stdin" => "line1\nline2", "stdin_add_newline" => "false"})

    result["stdout"].as_s.should eq("1")
  end

  # Proactive param-coverage pass: real Ansible's `command` documents
  # `strip_empty_ends` as "Strip empty lines from the end of stdout/stderr
  # in result" (bool, default yes) - its command.py only rstrips
  # "\r\n" when strip is true, so false returns the raw bytes untouched.
  # Live-verified against ansible-core 2.19.4: printf-style output ending
  # in several newlines keeps them all with strip_empty_ends: false and
  # collapses to the bare text with the default. Not previously
  # implemented (the rstrip was unconditional). The executor derives
  # stdout_lines/stderr_lines centrally from the plugin's stdout/stderr,
  # so the *_lines keys follow this setting automatically.
  it "strips trailing newlines from stdout/stderr by default (strip_empty_ends default true)" do
    result = PluginSpecHelper.run("command", {"cmd" => "seq 1 3"})

    result["stdout"].as_s.should eq("1\n2\n3")
  end

  it "preserves trailing newlines when strip_empty_ends is false" do
    result = PluginSpecHelper.run("command", {"cmd" => "seq 1 3", "strip_empty_ends" => "false"})

    result["stdout"].as_s.should eq("1\n2\n3\n")
  end

  it "applies strip_empty_ends to stderr the same way" do
    result = PluginSpecHelper.run("command", {"cmd" => "sh -c 'seq 1 2 1>&2'", "strip_empty_ends" => "false"})

    result["stderr"].as_s.should eq("1\n2\n")
  end
end
