require "spec"
require "colorize"
require "json"

Colorize.enabled = false

# Shared helper for integration-testing individual plugin binaries the same
# way PluginManager actually invokes them: pipe a JSON config on stdin, read
# a JSON result off stdout. This exercises the real plugin entrypoint (argv
# parsing bugs, stdin handling, etc.) without going through the full
# playbook/inventory/SSH machinery.
module PluginSpecHelper
  PROJECT_ROOT = File.expand_path("..", __DIR__)
  PLUGINS_DIR  = File.join(PROJECT_ROOT, "bin", "plugins")

  # Runs bin/plugins/<name> with `params` merged into the standard
  # {host, params, vars} config shape BasePlugin expects. Defaults to a
  # localhost host so plugins that check ansible_connection/host.name treat
  # this as a local, non-SSH execution.
  def self.run(name : String, params : Hash(String, String), vars : Hash(String, String) = {} of String => String, host_name : String = "localhost") : JSON::Any
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
    Process.run(binary, input: Process::Redirect::Pipe, output: output, error: Process::Redirect::Inherit) do |process|
      process.input.print(config.to_json)
      process.input.close
    end

    JSON.parse(output.to_s)
  end

  # Same as #run, but the params keep their NATIVE JSON types (int, float,
  # bool, null, list, dict) instead of being stringified - needed by specs
  # that exercise type-aware plugin behavior (e.g. the strict bool-param
  # validator's "of type int"/NoneType/list error branches, which real
  # Ansible derives from the value's own type).
  def self.run_raw(name : String, params : Hash(String, JSON::Any), vars : Hash(String, String) = {} of String => String, host_name : String = "localhost") : JSON::Any
    binary = File.join(PLUGINS_DIR, name)
    raise "Plugin binary not found: \#{binary} (run ./build.sh first)" unless File.exists?(binary)

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
    Process.run(binary, input: Process::Redirect::Pipe, output: output, error: Process::Redirect::Inherit) do |process|
      process.input.print(config.to_json)
      process.input.close
    end

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
