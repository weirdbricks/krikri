#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Make plugin - runs targets in a Makefile. Compatible with
  # community.general.make (ported from its own real Python source
  # exactly, including its idempotency check).
  #
  # Entirely unimplemented before - robertdebock.earlyoom's own "Make
  # earlyoom" handler (`community.general.make: chdir: ...`, notified
  # alongside "Install earlyoom" by the same "Clone repository" task)
  # silently dropped at parse time ("Plugin not available"), so the
  # earlyoom binary was never actually built - the very next handler,
  # "Install earlyoom" (a `copy: src: .../earlyoom remote_src: true`),
  # then failed with "Source file not found".
  #
  # Supported parameters: chdir (required), target, targets, params,
  # file, jobs, make. Idempotency ported exactly from the real module:
  # run the built command with an extra trailing `-q` first (make's own
  # "question mode" - exit 0 if the target is already up to date, exit
  # non-zero if a rebuild is needed); only actually re-run (without
  # `-q`) when that check says a rebuild is needed.
  class MakePlugin < BasePlugin
    def execute : PluginResult
      chdir = @params["chdir"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: chdir") unless chdir

      target = @params["target"]?
      targets = @params["targets"]?.try { |t| Array(String).from_json(t) }
      make_bin = @params["make"]? || "make"

      command = [make_bin]
      if jobs = @params["jobs"]?
        command << "-j" << jobs
      end
      if file = @params["file"]?
        command << "-f" << file
      end

      if target
        command << target
      elsif targets
        command.concat(targets)
      end

      if params_json = @params["params"]?
        params = Hash(String, String?).from_json(params_json)
        params.each do |key, value|
          command << (value ? "#{key}=#{value}" : key)
        end
      end

      full_command = command.map { |part| shell_quote(part) }.join(' ')
      check_mode = true?(@params["check_mode"]?)

      query_result = remote_exec("cd #{shell_quote(chdir)} && #{full_command} -q")
      needs_rebuild = query_result[:exit_code] != 0

      if check_mode
        return PluginResult.new(changed: needs_rebuild, failed: false, msg: needs_rebuild ? "Target would be rebuilt" : "Target is up to date")
      end

      return PluginResult.new(changed: false, failed: false, msg: "Target is up to date", stdout: query_result[:stdout], stderr: query_result[:stderr]) unless needs_rebuild

      result = remote_exec("cd #{shell_quote(chdir)} && #{full_command}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: "make failed: #{result[:stderr]}", stdout: result[:stdout], stderr: result[:stderr])
      end

      PluginResult.new(changed: true, failed: false, msg: "Target rebuilt", stdout: result[:stdout], stderr: result[:stderr])
    end

    private def shell_quote(value : String) : String
      "'" + value.gsub("'", "'\\\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::MakePlugin.new(config)
plugin.run
