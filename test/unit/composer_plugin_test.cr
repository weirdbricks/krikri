require "../minitest_helper"
require "file_utils"
require "../../src/krikri/plugin_helpers/composer"

# Regression spec for plugins/composer.cr, the native port of
# community.general.composer added for issue #1797
# (marsante.ansible_role_medshakeehr).
#
# Before the port krikri dropped the role's "Composer update"/
# "Composer upgrade" tasks as unimplemented plugins (`skipping:`, exit 4)
# where real Ansible runs the module - under --check too, where the
# update/require family answers `ok` for a converged project. The missing
# vendor/ then made the role's own install.php task fail on the krikri
# host, so every task after it diverged as well.
#
# Shapes pinned here (all live-verified against community.general 12.5.0
# with ansible-core 2.21.6, through `{{ r | to_json }}` and -v dumps):
# - check mode appends --dry-run only when the command's own
#   `composer help <command> --format=json` lists that option, else the
#   module exits skipped with "command '<c>' does not support check mode,
#   skipping";
# - the option list comes from that help output, in composer's flag
#   order (defaults first, then the params), with --working-dir after the
#   options and before the task's own arguments;
# - changed is decided from the output text alone (has_changed's two
#   wordings);
# - a failed help run reports only msg (collapsed stderr); a failed real
#   run also carries the raw stderr under stdout plus its stdout_lines;
# - a missing php is get_bin_path(required, opt_dirs=["/usr/local/bin"])'s
#   own message, opt_dirs first.
describe "Composer helper" do
  it "collapses whitespace the way parse_out does" do
    Krikri::PluginHelpers::Composer.parse_out("  a\n b\t\tc \n").must_equal("a b c")
    Krikri::PluginHelpers::Composer.parse_out("").must_equal("")
  end

  it "treats both composer no-op wordings as unchanged" do
    Krikri::PluginHelpers::Composer.changed?("Nothing to install or update").must_equal(false)
    Krikri::PluginHelpers::Composer.changed?("Nothing to install, update or remove").must_equal(false)
    Krikri::PluginHelpers::Composer.changed?("Package operations: 1 install").must_equal(true)
  end

  it "keeps the module's default-true params and its apcu option typo" do
    Krikri::PluginHelpers::Composer.param_default_true?("no_dev").must_equal(true)
    Krikri::PluginHelpers::Composer.param_default_true?("optimize_autoloader").must_equal(true)
    Krikri::PluginHelpers::Composer.param_default_true?("prefer_source").must_equal(false)
    # The module maps apcu_autoloader to "acpu-autoloader", so the flag is
    # never advertised by composer and never passed - on real Ansible too.
    Krikri::PluginHelpers::Composer::OPTION_PARAMS["apcu_autoloader"].must_equal("acpu-autoloader")
  end
end

describe "composer plugin" do
  # Ansible runs `php <composer-path> <args...>`; the php shim just execs
  # that path, so the composer shim below sees composer's own argv.
  PHP_SHIM = <<-SHIM
    #!/bin/bash
    prog="$1"
    shift
    exec "$prog" "$@"
    SHIM

  # Fake composer 2. Marker files in state/ steer it:
  #   no_dry_run - help output without a --dry-run option
  #   help_fail  - help exits 1 with that text on stderr
  #   run_fail   - the real verb exits 1 with that text on stderr
  #   changed    - the real verb reports pending work
  # Every real invocation is appended to state/ran.txt.
  COMPOSER_SHIM = <<-SHIM
    #!/bin/bash
    state="__STATE__"
    verb="$1"; shift
    if [ "$verb" = "global" ]; then verb="$1"; shift; fi
    if [ "$verb" = "help" ]; then
      if [ -f "$state/help_fail" ]; then cat "$state/help_fail" >&2; exit 1; fi
      if [ -f "$state/no_dry_run" ]; then
        echo '{"definition":{"options":{"no-ansi":{},"no-interaction":{},"no-progress":{},"no-dev":{},"optimize-autoloader":{}}}}'
      else
        echo '{"definition":{"options":{"no-ansi":{},"no-interaction":{},"no-progress":{},"dry-run":{},"prefer-source":{},"prefer-dist":{},"no-dev":{},"no-scripts":{},"no-plugins":{},"optimize-autoloader":{},"classmap-authoritative":{},"ignore-platform-reqs":{}}}}'
      fi
      exit 0
    fi
    echo "$verb $*" >> "$state/ran.txt"
    if [ -f "$state/run_fail" ]; then cat "$state/run_fail" >&2; exit 1; fi
    if [ -f "$state/changed" ]; then
      echo "Package operations: 1 install, 0 updates, 0 removals" >&2
    else
      echo "Nothing to install, update or remove" >&2
    fi
    exit 0
    SHIM

  private def with_composer_shim(&)
    dir = PluginSpecHelper.tmp_path("composer-shim")
    bin_dir = File.join(dir, "bin")
    state = File.join(dir, "state")
    FileUtils.mkdir_p(bin_dir)
    FileUtils.mkdir_p(state)
    File.write(File.join(bin_dir, "php"), PHP_SHIM)
    File.chmod(File.join(bin_dir, "php"), 0o755)
    File.write(File.join(bin_dir, "composer"), COMPOSER_SHIM.gsub("__STATE__", state))
    File.chmod(File.join(bin_dir, "composer"), 0o755)
    yield dir, bin_dir, state
  ensure
    FileUtils.rm_rf(dir) if dir.is_a?(String)
  end

  private def shim_path(bin_dir : String) : String
    "#{bin_dir}:/usr/bin:/bin"
  end

  private def mark(state : String, name : String, content = "") : Nil
    File.write(File.join(state, name), content)
  end

  private def ran(state : String) : String
    file = File.join(state, "ran.txt")
    File.exists?(file) ? File.read(file).strip : ""
  end

  it "reports a converged project unchanged in check mode" do
    with_composer_shim do |dir, bin_dir, state|
      work = File.join(dir, "project")
      result = PluginSpecHelper.run("composer", {
        "command"             => "update",
        "arguments"           => "--no-cache",
        "working_dir"         => work,
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Nothing to install, update or remove")
      result["stdout"].as_s.must_equal("Nothing to install, update or remove\n")
      result["stdout_lines"].as_a.map(&.as_s).must_equal(["Nothing to install, update or remove"])
      result.as_h.has_key?("failed").must_equal(false)
      ran(state).must_equal("update --no-ansi --no-interaction --no-progress --no-dev " \
                            "--optimize-autoloader --dry-run --working-dir #{work} --no-cache")
    end
  end

  it "reports pending work as changed in check mode" do
    with_composer_shim do |dir, bin_dir, state|
      mark(state, "changed")
      work = File.join(dir, "project")
      result = PluginSpecHelper.run("composer", {
        "command"             => "install",
        "working_dir"         => work,
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Package operations: 1 install, 0 updates, 0 removals")
      ran(state).must_match(/--dry-run/)
    end
  end

  it "skips a command whose help advertises no --dry-run" do
    with_composer_shim do |dir, bin_dir, state|
      mark(state, "no_dry_run")
      result = PluginSpecHelper.run("composer", {
        "command"             => "update",
        "working_dir"         => File.join(dir, "project"),
        "_ansible_check_mode" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(false)
      result["skipped"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("command 'update' does not support check mode, skipping")
      ran(state).must_equal("")
    end
  end

  it "fails with composer's collapsed stderr when help fails" do
    with_composer_shim do |dir, bin_dir, state|
      mark(state, "help_fail", "Composer could not find a composer.json file\nin #{dir}\n")
      result = PluginSpecHelper.run("composer", {
        "command"     => "update",
        "working_dir" => File.join(dir, "project"),
      }, env: {"PATH" => shim_path(bin_dir)})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Composer could not find a composer.json file in #{dir}")
      # The module's get_available_options fail_json passes only msg.
      result.as_h.has_key?("stdout").must_equal(false)
    end
  end

  it "echoes a failed run's stderr as stdout with the module's key order" do
    with_composer_shim do |dir, bin_dir, state|
      mark(state, "run_fail", "Your requirements could not be resolved\n")
      result = PluginSpecHelper.run("composer", {
        "command"     => "update",
        "working_dir" => File.join(dir, "project"),
      }, env: {"PATH" => shim_path(bin_dir)})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Your requirements could not be resolved")
      result["stdout"].as_s.must_equal("Your requirements could not be resolved\n")
      result["stdout_lines"].as_a.map(&.as_s).must_equal(["Your requirements could not be resolved"])
      result.as_h.keys.must_equal(%w[changed failed exception msg stdout stdout_lines])
    end
  end

  it "fails a missing php with get_bin_path's own search list" do
    empty = PluginSpecHelper.tmp_path("composer-no-path")
    FileUtils.mkdir_p(empty)
    begin
      result = PluginSpecHelper.run("composer", {
        "command"     => "update",
        "working_dir" => "/tmp",
      }, env: {"PATH" => empty})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      # opt_dirs first, then $PATH, then the sbin dirs the module adds.
      result["msg"].as_s.must_match(/\AFailed to find required executable "php" in paths: \/usr\/local\/bin:#{Regex.escape(empty)}:/)
    ensure
      FileUtils.rm_rf(empty)
    end
  end

  it "runs global commands through composer's global subcommand" do
    with_composer_shim do |_, bin_dir, state|
      result = PluginSpecHelper.run("composer", {
        "command"        => "require",
        "arguments"      => "my/package",
        "global_command" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})

      result["changed"].as_bool.must_equal(false)
      ran(state).must_equal("require --no-ansi --no-interaction --no-progress --no-dev " \
                            "--optimize-autoloader my/package")
    end
  end

  it "requires working_dir unless the run is global" do
    result = PluginSpecHelper.run("composer", {"command" => "update"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("global_command is False but all of the following are missing: working_dir")

    with_composer_shim do |_, bin_dir, state|
      ok = PluginSpecHelper.run("composer", {
        "command"        => "update",
        "global_command" => "true",
      }, env: {"PATH" => shim_path(bin_dir)})
      ok.as_h.has_key?("failed").must_equal(false)
      ran(state).must_match(/update --no-ansi/)
    end
  end

  it "rejects arguments embedded in command" do
    result = PluginSpecHelper.run("composer", {
      "command"     => "require my/package",
      "working_dir" => "/tmp",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Use the 'arguments' param for passing arguments with the 'command'")
  end

  it "honours an explicit executable param instead of searching PATH" do
    with_composer_shim do |dir, bin_dir, state|
      result = PluginSpecHelper.run("composer", {
        "command"             => "update",
        "working_dir"         => File.join(dir, "project"),
        "executable"          => "#{bin_dir}/php",
        "composer_executable" => "#{bin_dir}/composer",
      }, env: {"PATH" => "/nonexistent"})

      result.as_h.has_key?("failed").must_equal(false)
      ran(state).must_match(/update --no-ansi/)

      # argument_spec aliases executable as php_path.
      FileUtils.rm_f(File.join(state, "ran.txt"))
      aliased = PluginSpecHelper.run("composer", {
        "command"             => "update",
        "working_dir"         => File.join(dir, "project"),
        "php_path"            => "#{bin_dir}/php",
        "composer_executable" => "#{bin_dir}/composer",
      }, env: {"PATH" => "/nonexistent"})
      aliased.as_h.has_key?("failed").must_equal(false)
      ran(state).must_match(/update --no-ansi/)
    end
  end
end
