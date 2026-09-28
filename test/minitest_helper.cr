require "minitest/autorun"
require "file_utils"
require "json"
require "colorize"
require "yaml"

Colorize.enabled = false

# Shared helper for integration-testing individual plugin binaries the same
# way PluginManager actually invokes them: pipe a JSON config on stdin, read
# a JSON result off stdout. This exercises the real plugin entrypoint (argv
# parsing bugs, stdin handling, etc.) without going through the full
# playbook/inventory/SSH machinery.
module PluginSpecHelper
  PROJECT_ROOT = File.expand_path("..", __DIR__)
  PLUGINS_DIR  = File.join(PROJECT_ROOT, "bin", "plugins")

  # Parallel-safe test temp space. Each running test gets its own subtree
  # under spec/tmp/p/<nonce>: the run_one hook below opens the scope before
  # setup and closes it after teardown, keyed by the worker fiber, so every
  # tmp_path() call from anywhere in that test resolves inside it. Without
  # this, converted specs that rm_rf a fixed shared root in setup would wipe
  # another concurrent test's tree mid-run under minitest --parallel.
  TEST_TMP_BASE = File.join(PROJECT_ROOT, "spec", "tmp")

  @@tmp_mutex = Mutex.new
  @@tmp_dir_by_fiber = {} of Fiber => String

  def self.begin_test_tmp : Nil
    dir = File.join(TEST_TMP_BASE, "p", Random::Secure.hex(8))
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    @@tmp_mutex.synchronize { @@tmp_dir_by_fiber[Fiber.current] = dir }
  end

  def self.end_test_tmp : Nil
    dir = @@tmp_mutex.synchronize { @@tmp_dir_by_fiber.delete(Fiber.current) }
    FileUtils.rm_rf(dir) if dir
  end

  def self.tmp_path(*parts : String) : String
    dir = @@tmp_mutex.synchronize { @@tmp_dir_by_fiber[Fiber.current]? }
    dir ||= begin
      fallback = File.join(TEST_TMP_BASE, "unscoped")
      FileUtils.mkdir_p(fallback)
      fallback
    end
    File.join(dir, *parts)
  end

  # ONE lock for all process-global mutable state: ENV (PATH, HOME,
  # AWS_*, ANSIBLE_* ...) and engine-level class settings (Ec2Api/IamApi
  # transports, poll intervals, CliOptions, Vault, TimingProfile, daemon
  # caches). Under -p N one test's override - or its teardown's restore -
  # would otherwise land in the middle of another test's run at any IO
  # yield point. Reentrant, so a `serial!` test can still call helpers
  # (with_vault, the ENV shims) that take it again. ENV_MUTEX is the same
  # lock: a test can touch ENV and engine state together, and a single lock
  # has no lock-ordering deadlocks.
  STATE_MUTEX = Mutex.new(:reentrant)
  ENV_MUTEX   = STATE_MUTEX

  # Runs `binary` with `config_json` on stdin, streaming stdout into
  # `output`. Crystal 1.21's Process.run has no timeout parameter anymore,
  # so this watchdog kills a plugin that runs past 60s and turns it into a
  # named test failure instead of a suite-wide hang.
  #
  # Order matters: stdout is drained to EOF BEFORE Process#wait, never
  # concurrently with it. #wait closes every pipe in its own `ensure`, so a
  # drain fiber still inside IO.copy when the child exits reads a closed
  # stream and dies ("Unhandled exception in spawn: Closed stream") - the
  # caller then either gets truncated stdout or blocks forever waiting for
  # a completion signal that fiber never sends (both seen under -p 4).
  #
  # `chdir` starts the plugin in that directory and `before_input` runs
  # after the spawn but before the config is written - the plugin blocks
  # reading stdin until then. Together they let a test put the CHILD in a
  # state (e.g. its starting directory deleted) without ever touching this
  # process's own cwd, which every concurrently running test shares.
  #
  # `umask` runs the plugin under that umask via `sh -c 'umask ...; exec'`.
  # Never LibC.umask the test process instead: the umask is process-wide
  # and inherited by EVERY child, so concurrently running tests' plugins
  # (tar/unzip extractions, file creation) would get the wrong modes.
  def self.run_plugin_with_timeout(binary : String, config_json : String, output : IO,
                                   chdir : String? = nil, before_input : Proc(Nil)? = nil,
                                   umask : Int32? = nil) : Nil
    command, args = umask ? {"/bin/sh", ["-c", "umask #{umask.to_s(8)} && exec \"$0\"", binary]} : {binary, [] of String}
    process = Process.new(command, args, input: Process::Redirect::Pipe,
      output: Process::Redirect::Pipe, error: Process::Redirect::Inherit, chdir: chdir)
    before_input.try &.call

    # Fed from its own fiber so a plugin that writes before it reads can't
    # deadlock against a blocked write here.
    spawn do
      process.input.print(config_json)
    rescue IO::Error
      # The plugin exited (or was killed) without reading all its input.
    ensure
      process.input.close
    end

    # Buffered, so the drain fiber never blocks on send after a timeout.
    drained = Channel(Exception?).new(1)
    spawn do
      IO.copy(process.output, output)
      drained.send(nil)
    rescue ex
      drained.send(ex)
    end

    timed_out = false
    drain_error = nil
    select
    when ex = drained.receive
      drain_error = ex
    when timeout 60.seconds
      timed_out = true
      # Process#signal, not #kill - Crystal 1.21 has no Process#kill, and
      # the process may have exited between the check and the signal.
      begin
        process.signal(Signal::KILL) unless process.terminated?
      rescue
      end
    end
    process.wait
    raise "plugin #{binary} hung for 60s and was killed" if timed_out
    raise drain_error if drain_error
  end

  # Runs bin/plugins/<name> with `params` merged into the standard
  # {host, params, vars} config shape BasePlugin expects. Defaults to a
  # localhost host so plugins that check ansible_connection/host.name treat
  # this as a local, non-SSH execution.
  def self.run(name : String, params : Hash(String, String), vars : Hash(String, String) = {} of String => String, host_name : String = "localhost",
               chdir : String? = nil, before_input : Proc(Nil)? = nil,
               umask : Int32? = nil) : JSON::Any
    binary = File.join(PLUGINS_DIR, name)
    raise "Plugin binary not found: #{binary} (run ./build.sh first)" unless File.exists?(binary)

    config = {
      "host" => {
        "name" => host_name,
        "user" => ENV["USER"]? || "root",
        "port" => 22,
      },
      "params" => params,
      "vars"   => vars,
    }

    output = IO::Memory.new
    run_plugin_with_timeout(binary, config.to_json, output, chdir, before_input, umask)

    JSON.parse(output.to_s)
  end

  # Same as #run, but the params keep their NATIVE JSON types (int, float,
  # bool, null, list, dict) instead of being stringified - needed by specs
  # that exercise type-aware plugin behavior (e.g. the strict bool-param
  # validator's "of type int"/NoneType/list error branches, which real
  # Ansible derives from the value's own type).
  def self.run_raw(name : String, params : Hash(String, JSON::Any), vars : Hash(String, String) = {} of String => String, host_name : String = "localhost",
                   chdir : String? = nil, before_input : Proc(Nil)? = nil,
                   umask : Int32? = nil) : JSON::Any
    binary = File.join(PLUGINS_DIR, name)
    raise "Plugin binary not found: #{binary} (run ./build.sh first)" unless File.exists?(binary)

    config = {
      "host" => {
        "name" => host_name,
        "user" => ENV["USER"]? || "root",
        "port" => 22,
      },
      "params" => params,
      "vars"   => vars,
    }

    output = IO::Memory.new
    run_plugin_with_timeout(binary, config.to_json, output, chdir, before_input, umask)

    JSON.parse(output.to_s)
  end

  # Whether the filesystem holding `dir` (default: the spec tempdir)
  # accepts `chattr -i` at all. Rootless fuse-overlayfs containers (and
  # other fuse-backed overlay filesystems) reject every chattr flag
  # operation, even clearing a flag that isn't set - and on such a
  # filesystem real Ansible fails the task with "chattr failed"
  # identically, so the '-'-prefixed attributes specs (which pin the
  # success path only real chattr-capable filesystems can take) probe
  # this first and skip rather than assert success the target fs can
  # never produce.
  def self.chattr_clear_supported?(dir : String? = nil) : Bool
    probe = dir ? File.join(dir, "chattr-probe-#{rand(10_000_000)}") : File.tempname("chattr-probe")
    File.write(probe, "")
    Process.run("/bin/sh", args: ["-c", "command -v chattr >/dev/null && chattr -i #{probe}"],
      output: Process::Redirect::Close, error: Process::Redirect::Close).success?
  ensure
    File.delete(probe) if probe && (File.exists?(probe) || File.symlink?(probe))
  end

  # Whether the spec process itself runs as root (uid 0). Some plugin
  # behaviors only exist as root (sysctl -w actually writing the live
  # kernel value) while others only reproduce as non-root (unarchive's
  # Uid/Gid idempotency, where real Ansible only ignores a tar
  # Uid/Gid-differs line when run as root) - both gate on this same
  # probe so the privilege condition is stated and checked one way.
  def self.running_as_root? : Bool
    LibC.getuid == 0
  end

  # Whether the environment can apply file capabilities at all: a real
  # `setcap` on a throwaway file succeeds. Needs root or CAP_SETFCAP;
  # rootless containers reject every setcap operation, and on such an
  # environment real Ansible fails the task identically, so specs
  # pinning the changed path (which only a capability-capable
  # environment can produce) probe this first and skip rather than
  # assert success the environment can never deliver.
  def self.setcap_supported? : Bool
    probe = File.tempname("setcap-probe")
    File.write(probe, "")
    Process.run("setcap", ["cap_chown+eip", probe],
      output: Process::Redirect::Close, error: Process::Redirect::Close).success?
  ensure
    File.delete(probe) if probe && File.exists?(probe)
  end
end

# Shared helper for krikri-lint task-rule specs: write YAML, load it,
# run one rule, return violations.
def lint_yaml(rule : Krikri::Lint::Rule, yaml : String, file_type : Krikri::Lint::FileType = Krikri::Lint::FileType::PLAYBOOK) : Array(Krikri::Lint::Violation)
  path = File.tempname("lintrule", ".yml")
  File.write(path, yaml)
  file = Krikri::Lint::PositionedFile.new(path, file_type, YAML::Nodes.parse(yaml).nodes.first?, nil)
  violations = [] of Krikri::Lint::Violation
  rule.check(file, violations)
  violations
ensure
  File.delete(path) if path
end

# Runner-level helper: runs only the fqcn rule through the full Runner
# pipeline (config, noqa, profile gating).
def run_fqcn_yaml(yaml : String, config : Krikri::Lint::LintConfig = Krikri::Lint::LintConfig.new) : Array(Krikri::Lint::Violation)
  path = File.tempname("lintrunner", ".yml")
  File.write(path, yaml)
  registry = Krikri::Lint::RuleRegistry.new([Krikri::Lint::FqcnActionCoreRule.new] of Krikri::Lint::Rule)
  Krikri::Lint::Runner.new(registry, config).run([path])
ensure
  File.delete(path) if path
end

# crystal spec's truthiness matchers have no minitest equivalent, so the
# converter routes `should be_truthy` / `should be_falsey` through these.
def truthy?(value) : Bool
  !(value.nil? || value == false)
end

# Vault secrets are engine-global state (Vault.password / Vault.vault_ids):
# one test's password would make a concurrent test's "undecryptable"
# expectation decrypt successfully instead of raising. Vault-touching tests
# serialize on STATE_MUTEX and always start and end from a clean slate.
def with_vault(&)
  PluginSpecHelper::STATE_MUTEX.synchronize do
    begin
      Krikri::Vault.password = nil
      Krikri::Vault.vault_ids.clear
      yield
    ensure
      Krikri::Vault.password = nil
      Krikri::Vault.vault_ids.clear
    end
  end
end

def falsey?(value) : Bool
  value.nil? || value == false
end

def str_starts_with?(actual, prefix) : Bool
  actual.starts_with?(prefix)
end

def str_ends_with?(actual, suffix) : Bool
  actual.ends_with?(suffix)
end

# crystal spec's `expect_raises(Klass, expected_message_or_regex)` has no direct
# minitest equivalent: `assert_raises` takes only a class. Converted specs call
# this instead, which also checks the message the way the spec did.
module RaisesAssertion
  def assert_raises_message(klass, expected, &block : ->)
    ex = assert_raises(klass, &block)
    text = ex.message || ""
    case expected
    when Regex  then assert_match(expected, text)
    when String then assert_includes(text, expected)
    end
  end
end

# Every describe-generated Spec class inherits this, so converted specs can
# call assert_raises_message without repeating `include RaisesAssertion` per
# describe (the per-describe includes some converted files carry stay legal).
class Minitest::Spec
  include RaisesAssertion

  # minitest's own `it` names a bare `it { }` test_anonymous and turns any
  # name into a method, so two unnamed examples - or two whose names
  # sanitize to the same method - silently overwrite each other and the
  # suite quietly runs fewer tests (found converting spec/lint: 4 unnamed
  # fixer examples collapsed into 1). Same method-naming as minitest's
  # macro, but both cases are compile errors here.
  macro it(name = nil, &block)
    {% raise "every `it` needs a name (minitest names a bare `it { }` test_anonymous, silently overwriting its siblings)" if name.is_a?(NilLiteral) %}
    {% meth = "test_" + name.strip.gsub(/[^\p{L}\p{N}]+/, "_") %}
    {% if @type.methods.any? { |m| m.name.stringify == meth } %}
      {% raise "duplicate test name in #{@type}: #{meth} (a second `it` with this name would silently replace the first)" %}
    {% end %}
    def {{ meth.id }}
      {{ yield }}
    end
  end

  # Describes whose tests mutate process-global state (ENV, engine class
  # settings) call `serial!` in their body: every test in that describe -
  # and in its nested describes, which minitest generates as subclasses -
  # then holds STATE_MUTEX across setup, body AND teardown, so
  # before_each/after_each ENV pinning is covered too. Only serial tests
  # wait on each other; the rest of the suite keeps running concurrently.
  def serial? : Bool
    false
  end

  macro serial!
    def serial? : Bool
      true
    end
  end

  # One tmp scope per test: setup, body and teardown all run inside run_one
  # on the same worker fiber, so begin/end here bracket exactly one test.
  def run_one(name : String, proc : Test ->) : Nil
    PluginSpecHelper.begin_test_tmp
    if serial?
      PluginSpecHelper::STATE_MUTEX.synchronize { super }
    else
      super
    end
  ensure
    PluginSpecHelper.end_test_tmp
  end
end

# crystal spec's before_each/after_each have no minitest equivalent. Minitest's
# `before`/`after` macros replace `setup`/`teardown` wholesale instead of
# chaining, so these are macros that call `super` and can be stacked.
macro before_each(&block)
  def setup
    super()
    {{ yield }}
  end
end

macro after_each(&block)
  def teardown
    {{ yield }}
    super()
  end
end

# minitest's own `describe` derives the generated class name from the
# describe argument ALONE, so two files describing the same subject (e.g.
# two files doing `describe Krikri::ConditionalEvaluator`) would compile
# into ONE class and silently merge their helper defs and test methods -
# the last required file's `private def vars`-style helper winning over
# every earlier file's. crystal spec kept every describe block a separate
# closure context, so a faithful conversion needs that separation back.
# There is no macro-visible call-site file/line in this Crystal version to
# derive uniqueness from, so every TOP-LEVEL describe subject must be
# unique TEXT across the whole suite - colliding files hand-suffix their
# subject with their own filename (nested describes need nothing).
