require "../minitest_helper"

# community.general.composer, the module marsante.ansible_role_medshakeehr's
# "Composer update"/"Composer upgrade" tasks run (issue #1791, where krikri used
# to skip them as an unimplemented plugin). A real run needs a php binary and
# network access (composer fetches packages), so every spec here drives the
# plugin through the module's two knobs - `executable:` is the php binary and
# `composer_executable:` the phar it is handed - with a shell stub standing in
# for php. That is also how the argv assertions pin the module's own command
# line: the stub logs `"$*"`, i.e. everything the plugin passed AFTER php,
# which is what real ansible's `-v` transcript cannot show.
#
# The expected wordings and command lines were captured from real ansible-core
# 2.21.6 + community.general 13.2.0 running the same task.

private def composer_stub(dir : String, name : String, body : String) : String
  path = File.join(dir, name)
  File.write(path, "#!/bin/sh\n#{body}")
  File.chmod(path, 0o755)
  path
end

# The option set a composer install/update advertises through
# `help <command> --format=json` - the defaults the module always appends,
# plus --dry-run for check mode.
DEFAULT_HELP_JSON = %({"definition":{"options":{"no-ansi":{},"no-interaction":{},"no-progress":{},"no-dev":{},"optimize-autoloader":{},"prefer-dist":{},"dry-run":{}}}})

# Its own describe subject: test/unit/composer_plugin_test.cr already owns
# "composer plugin" (the suite turns a duplicate subject into a compile error).
describe "composer plugin - module invocation" do
  it "runs the role's composer update task instead of skipping it" do
    dir = PluginSpecHelper.tmp_path("composer-role-task")
    Dir.mkdir_p(dir)
    php = composer_stub(dir, "php", <<-SH)
      case " $* " in
        *" help "*) printf '%s\\n' '#{DEFAULT_HELP_JSON}'; exit 0 ;;
      esac
      printf 'Installing dependencies from lock file\\n'
      SH

    result = PluginSpecHelper.run("composer", {
      "command"             => "update",
      "arguments"           => "--no-cache",
      "working_dir"         => dir,
      "executable"          => php,
      "composer_executable" => "/usr/local/bin/composer",
    })

    result["failed"]?.try(&.as_bool?).must_equal(nil)
    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Installing dependencies from lock file")
    result["stdout"].as_s.must_equal("Installing dependencies from lock file\n")
    result["stdout_lines"].as_a.map(&.as_s).must_equal(["Installing dependencies from lock file"])
  end

  it "builds the same argv the module does, --working-dir before the task's arguments" do
    dir = PluginSpecHelper.tmp_path("composer-argv")
    Dir.mkdir_p(dir)
    log = File.join(dir, "argv.log")
    php = composer_stub(dir, "php", <<-SH)
      printf '%s\\n' "$*" >> #{Process.quote(log)}
      case " $* " in
        *" help "*) printf '%s\\n' '#{DEFAULT_HELP_JSON}'; exit 0 ;;
      esac
      printf 'Installing dependencies from lock file\\n'
      SH
    composer = File.join(dir, "composer")

    PluginSpecHelper.run("composer", {
      "command"             => "update",
      "arguments"           => "--no-cache",
      "working_dir"         => dir,
      "executable"          => php,
      "composer_executable" => composer,
    })

    File.read(log).must_equal(
      "#{composer} help update --working-dir #{dir} --no-interaction --format=json\n" \
      "#{composer} update --no-ansi --no-interaction --no-progress --no-dev " \
      "--optimize-autoloader --working-dir #{dir} --no-cache\n")
  end

  it "passes global and drops --working-dir for a global run" do
    dir = PluginSpecHelper.tmp_path("composer-global")
    Dir.mkdir_p(dir)
    log = File.join(dir, "argv.log")
    php = composer_stub(dir, "php", <<-SH)
      printf '%s\\n' "$*" >> #{Process.quote(log)}
      case " $* " in
        *" help "*) printf '%s\\n' '#{DEFAULT_HELP_JSON}'; exit 0 ;;
      esac
      printf 'Nothing to install or update\\n'
      SH
    composer = File.join(dir, "composer")

    result = PluginSpecHelper.run("composer", {
      "command"             => "require",
      "arguments"           => "my/package",
      "global_command"      => "true",
      "executable"          => php,
      "composer_executable" => composer,
    })

    result["changed"].as_bool.must_equal(false)
    File.read(log).must_equal(
      "#{composer} global help require --no-interaction --format=json\n" \
      "#{composer} global require --no-ansi --no-interaction --no-progress --no-dev " \
      "--optimize-autoloader my/package\n")
  end

  it "adds a param flag only when composer's own help advertises it" do
    dir = PluginSpecHelper.tmp_path("composer-flag-gate")
    Dir.mkdir_p(dir)
    log = File.join(dir, "argv.log")
    php = composer_stub(dir, "php", <<-SH)
      printf '%s\\n' "$*" >> #{Process.quote(log)}
      case " $* " in
        *" help "*) printf '%s\\n' '#{DEFAULT_HELP_JSON}'; exit 0 ;;
      esac
      printf 'Nothing to install or update\\n'
      SH

    PluginSpecHelper.run("composer", {
      "command"              => "update",
      "working_dir"          => dir,
      "prefer_dist"          => "true",
      "ignore_platform_reqs" => "true",
      "executable"           => php,
      "composer_executable"  => File.join(dir, "composer"),
    })

    # --prefer-dist is offered by this composer, --ignore-platform-reqs is
    # not - so only the former may reach the command line.
    File.read(log).lines[1].must_equal(
      "#{File.join(dir, "composer")} update --no-ansi --no-interaction --no-progress " \
      "--prefer-dist --no-dev --optimize-autoloader --working-dir #{dir}")
  end

  it "fails a non-zero run with the collapsed stderr as msg and the raw stderr as stdout" do
    dir = PluginSpecHelper.tmp_path("composer-failure")
    Dir.mkdir_p(dir)
    php = composer_stub(dir, "php", <<-SH)
      case " $* " in
        *" help "*) printf '%s\\n' '#{DEFAULT_HELP_JSON}'; exit 0 ;;
      esac
      printf 'Your requirements could not be resolved.\\n\\nProblem 1\\n  - root composer.json requires x\\n' >&2
      exit 2
      SH

    result = PluginSpecHelper.run("composer", {
      "command"             => "update",
      "working_dir"         => dir,
      "executable"          => php,
      "composer_executable" => File.join(dir, "composer"),
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    # fail_json(msg=parse_out(err), stdout=err) - no rc, no cmd, no stderr
    # key, exactly like the module.
    result["msg"].as_s.must_equal("Your requirements could not be resolved. Problem 1 - root composer.json requires x")
    result["stdout"].as_s.must_equal("Your requirements could not be resolved.\n\nProblem 1\n  - root composer.json requires x\n")
    result["stdout_lines"].as_a.map(&.as_s).must_equal(["Your requirements could not be resolved.", "", "Problem 1", "  - root composer.json requires x"])
    result["rc"]?.must_equal(nil)
  end

  it "fails the option probe with only the collapsed stderr as msg" do
    dir = PluginSpecHelper.tmp_path("composer-help-failure")
    Dir.mkdir_p(dir)
    php = composer_stub(dir, "php", <<-SH)
      printf 'composer: command not understood\\nsecond line\\n' >&2
      exit 1
      SH

    result = PluginSpecHelper.run("composer", {
      "command"             => "update",
      "working_dir"         => dir,
      "executable"          => php,
      "composer_executable" => File.join(dir, "composer"),
    })

    # get_available_options fails with fail_json(msg=parse_out(err)) - no
    # stdout key at all, unlike the run's own failure.
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("composer: command not understood second line")
    result["stdout"]?.must_equal(nil)
  end

  it "fails get_bin_path-style when php is not on PATH" do
    result = PluginSpecHelper.run("composer", {
      "command"     => "update",
      "working_dir" => "/tmp",
    }, env: {"PATH" => "/nonexistent-krikri-composer-path"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include(%(Failed to find required executable "php" in paths: ))
    result["msg"].as_s.must_include("/nonexistent-krikri-composer-path")
  end

  it "fails get_bin_path-style when composer is not on PATH" do
    dir = PluginSpecHelper.tmp_path("composer-no-composer")
    Dir.mkdir_p(dir)
    php = composer_stub(dir, "php", "exit 0\n")

    result = PluginSpecHelper.run("composer", {
      "command"     => "update",
      "working_dir" => dir,
      "executable"  => php,
    }, env: {"PATH" => "/nonexistent-krikri-composer-path"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include(%(Failed to find required executable "composer" in paths: ))
    result["msg"].as_s.must_include("/nonexistent-krikri-composer-path")
  end

  it "requires working_dir unless the run is global" do
    result = PluginSpecHelper.run("composer", {"command" => "update"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("global_command is False but all of the following are missing: working_dir")
  end

  it "rejects a command that carries its own arguments" do
    result = PluginSpecHelper.run("composer", {
      "command"     => "update --no-dev",
      "working_dir" => "/tmp",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Use the 'arguments' param for passing arguments with the 'command'")
  end

  it "adds --dry-run in check mode when composer offers it" do
    dir = PluginSpecHelper.tmp_path("composer-check-dry-run")
    Dir.mkdir_p(dir)
    log = File.join(dir, "argv.log")
    php = composer_stub(dir, "php", <<-SH)
      printf '%s\\n' "$*" >> #{Process.quote(log)}
      case " $* " in
        *" help "*) printf '%s\\n' '#{DEFAULT_HELP_JSON}'; exit 0 ;;
      esac
      printf 'Installing dependencies from lock file\\n'
      SH

    result = PluginSpecHelper.run("composer", {
      "command"             => "update",
      "working_dir"         => dir,
      "executable"          => php,
      "composer_executable" => File.join(dir, "composer"),
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    File.read(log).lines[1].must_include("--dry-run")
  end

  it "skips in check mode when composer has no dry-run option" do
    dir = PluginSpecHelper.tmp_path("composer-check-no-dry-run")
    Dir.mkdir_p(dir)
    log = File.join(dir, "argv.log")
    php = composer_stub(dir, "php", <<-SH)
      printf '%s\\n' "$*" >> #{Process.quote(log)}
      printf '%s\\n' '{"definition":{"options":{"no-ansi":{}}}}'
      SH

    result = PluginSpecHelper.run("composer", {
      "command"             => "update",
      "working_dir"         => dir,
      "executable"          => php,
      "composer_executable" => File.join(dir, "composer"),
      "_ansible_check_mode" => "true",
    })

    result["skipped"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("command 'update' does not support check mode, skipping")
    File.read(log).lines.size.must_equal(1)
  end
end
