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
  def self.run(name : String, params : Hash(String, String), vars : Hash(String, String) = {} of String => String) : JSON::Any
    binary = File.join(PLUGINS_DIR, name)
    raise "Plugin binary not found: #{binary} (run ./build.sh first)" unless File.exists?(binary)

    config = {
      "host" => {
        "name" => "localhost",
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
end
