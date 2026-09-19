#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # Make plugin - runs targets in a Makefile. Compatible with
  # community.general.make (ported from its own real Python source,
  # including its idempotency check).
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
  #
  # Real-module surface (confirmed against real ansible-playbook via the
  # make_edge_cases podman-diff case):
  # - parameters.py wording for the missing required chdir and the
  #   target/targets mutual exclusion
  # - the default binary is resolved through PATH as gmake FIRST (real
  #   get_bin_path's non-Linux-first preference), absolute path; an
  #   explicit `make:` param is used verbatim
  # - success/check-mode results carry NO msg - they carry `command`
  #   (the shlex-quoted base command, -q excluded) plus stdout/stderr
  #   rstripped of trailing newlines
  # - a failing rebuild fails with run_command(check_rc)'s shape: the
  #   sanitized stderr as msg, plus rc/stdout
  class MakePlugin < BasePlugin
    def execute : PluginResult
      chdir = @params["chdir"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: chdir") unless chdir

      target = @params["target"]?
      targets = @params["targets"]?.try { |target| target.split(',').map(&.strip).reject(&.empty?) }

      # Real AnsibleModule's mutually_exclusive check counts non-empty
      # values, in parameters.py's exact wording.
      exclusive_count = (target && !target.empty? ? 1 : 0) + (targets && !targets.empty? ? 1 : 0)
      if exclusive_count > 1
        return PluginResult.new(changed: false, failed: true, msg: "parameters are mutually exclusive: target|targets")
      end

      make_bin = @params["make"]?.presence
      if make_bin.nil?
        # Real make.py prefers gmake (non-Linux make implementations)
        # before falling back to system make, and get_bin_path returns
        # the ABSOLUTE resolved path - the `command` result echoes it.
        make_bin = which_bin("gmake") || which_bin("make")
        return PluginResult.new(changed: false, failed: true, msg: "Failed to find required executable make") unless make_bin
      end

      command = [make_bin]
      if jobs = @params["jobs"]?
        command << "-j" << jobs
      end
      if file = @params["file"]?
        command << "-f" << file
      end

      if target && !target.empty?
        command << target
      elsif targets && !targets.empty?
        command.concat(targets)
      end

      if params_json = @params["params"]?.presence
        parsed = JSON.parse(params_json) rescue nil
        unless parsed && parsed.as_h?
          return PluginResult.new(changed: false, failed: true, msg: "params must be a dictionary")
        end
        parsed.as_h.each do |key, value|
          # Real: f"={v!s}" for non-None values (Python str() - a bool
          # becomes "True"/"False", a number its decimal digits), a bare
          # key for None.
          command << if value.raw.nil?
                       key
                     else
                       "#{key}=#{py_str(value)}"
                     end
        end
      end

      full_command = command.map { |part| shlex_quote(part) }.join(' ')
      check_mode = true?(@params["_ansible_check_mode"]?)

      query_result = remote_exec("cd #{shell_quote(chdir)} && #{full_command} -q")
      needs_rebuild = query_result[:exit_code] != 0

      # Real reports NO msg anywhere - just stdout/stderr (sanitized
      # rstrip) and the shlex-quoted base command the -q check built.
      if check_mode
        return PluginResult.new(changed: needs_rebuild, failed: false, stdout: sanitize(query_result[:stdout]), stderr: sanitize(query_result[:stderr]), command: full_command)
      end

      return PluginResult.new(changed: false, failed: false, stdout: sanitize(query_result[:stdout]), stderr: sanitize(query_result[:stderr]), command: full_command) unless needs_rebuild

      result = remote_exec("cd #{shell_quote(chdir)} && #{full_command}")
      unless result[:exit_code] == 0
        # real run_command(check_rc=True): fail_json(rc, stdout, stderr,
        # msg=the sanitized stderr itself - no "make failed:" prefix).
        return PluginResult.new(changed: false, failed: true, msg: sanitize(result[:stderr]), stdout: sanitize(result[:stdout]), stderr: sanitize(result[:stderr]), rc: result[:exit_code])
      end

      PluginResult.new(changed: true, failed: false, stdout: sanitize(result[:stdout]), stderr: sanitize(result[:stderr]), command: full_command)
    end

    private def py_str(value : JSON::Any) : String
      case value.raw
      when String   then value.as_s
      when Bool     then value.as_bool ? "True" : "False"
      when Int64    then value.as_i64.to_s
      when Float64  then value.as_f.to_s
      else               value.to_s
      end
    end

    # Real sanitize_output: None -> "", else rstrip("\r\n").
    private def sanitize(output : String) : String
      output.rstrip("\r\n")
    end

    # Real get_bin_path: absolute path of the first executable match in
    # PATH order.
    private def which_bin(name : String) : String?
      paths = ENV["PATH"]?.try(&.split(':')) || ["/usr/bin", "/bin"]
      paths.each do |dir|
        candidate = "#{dir}/#{name}"
        return candidate if File.executable?(candidate) && !File.directory?(candidate)
      end
      nil
    end

    # Python shlex.quote: bare only when every char is in
    # [\w@%+=:,./-] (ASCII), else single-quoted with '"'" escaping.
    private def shlex_quote(value : String) : String
      return "''" if value.empty?
      return value if value.matches?(/\A[\w@%+=:,.\-\/]+\z/)

      Shell.single_quote(value)
    end

    private def shell_quote(value : String) : String
      Shell.single_quote(value)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::MakePlugin.new(config)
plugin.run
