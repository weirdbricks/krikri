#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"

module Krikri
  # Make plugin - runs targets in a Makefile. Compatible with
  # community.general.make (behavior matched to its own real Python source,
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
  # file, jobs, make. Idempotency ported exactly from the Ansible module:
  # run the built command with an extra trailing `-q` first (make's own
  # "question mode" - exit 0 if the target is already up to date, exit
  # non-zero if a rebuild is needed); only actually re-run (without
  # `-q`) when that check says a rebuild is needed.
  #
  # Real-module surface (confirmed against ansible-playbook via the
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
      targets = @params["targets"]?.try { |value| value.split(',').map(&.strip).reject(&.empty?) }

      # AnsibleModule's mutually_exclusive check counts non-empty
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
        return PluginResult.new(changed: false, failed: true, msg: missing_executable_message("make")) unless make_bin
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

      params_val : JSON::Any? = nil
      if params_json = @params["params"]?.presence
        parsed = JSON.parse(params_json) rescue nil
        unless parsed && parsed.as_h?
          return PluginResult.new(changed: false, failed: true, msg: "params must be a dictionary")
        end
        params_val = parsed
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
      # An explicit `make:` param is used verbatim - real make.py never
      # existence-checks it, so the failure surfaces at run_command's
      # spawn of the -q check: basic.py's OSError handler does
      # fail_json(rc=errno, stdout='', stderr='', msg="Error executing
      # command.", cmd=..., exception=ex) - the [ERROR] header composes
      # "<msg>: <exception>" while the dumped result keeps the bare msg
      # (live-verified against ansible-playbook 2.19.11:
      # `make: /tmp/kpg-work/out2.txt` with no such file).
      if @params["make"]?.presence && !File.exists?(make_bin)
        return PluginResult.new(changed: false, failed: true, msg: "Error executing command.",
          rc: 2, cmd: "#{full_command} -q", stdout: "", stderr: "",
          stdout_lines: [] of String, stderr_lines: [] of String,
          exception: "[Errno 2] No such file or directory: b'#{make_bin}'")
      end

      # Real run_command(cwd=chdir) drops an invalid cwd entirely
      # (ignore_invalid_cwd=True default: only a real directory is
      # passed to the subprocess) - the command then runs in the
      # current directory instead of failing like this plugin's old
      # `cd <chdir> && ...` shell wrapper did.
      chdir_part = Dir.exists?(chdir) ? "cd #{shell_quote(chdir)} && " : ""

      query_result = remote_exec("#{chdir_part}#{full_command} -q")
      needs_rebuild = query_result[:exit_code] != 0

      # Ansible reports NO msg anywhere - just stdout/stderr (sanitized
      # rstrip) and the shlex-quoted base command the -q check built.
      # Ansible 2.19.11 registered order (live-verified, `{{ r | to_json }}`):
      # changed, failed, stdout, stderr, target, targets, params, chdir,
      # file, jobs, command - exit_json(changed=..., failed=False, ...)
      # emits failed EXPLICITLY (second), and the module echoes its raw
      # params back (null when absent). stdout_lines/stderr_lines land
      # after command via the register-time lines augmentation, exactly
      # where Ansible's registered result shows them.
      if check_mode
        return PluginResult.new(changed: needs_rebuild, failed: false, stdout: sanitize(query_result[:stdout]), stderr: sanitize(query_result[:stderr]), command: full_command,
          failed_flag: true, target: target, targets: targets, params: params_val, chdir: chdir, file: @params["file"]?, jobs: @params["jobs"]?,
          key_order: %w[changed failed stdout stderr target targets params chdir file jobs command])
      end

      return PluginResult.new(changed: false, failed: false, stdout: sanitize(query_result[:stdout]), stderr: sanitize(query_result[:stderr]), command: full_command,
        failed_flag: true, target: target, targets: targets, params: params_val, chdir: chdir, file: @params["file"]?, jobs: @params["jobs"]?,
        key_order: %w[changed failed stdout stderr target targets params chdir file jobs command]) unless needs_rebuild

      result = remote_exec("#{chdir_part}#{full_command}")
      unless result[:exit_code] == 0
        # real run_command(check_rc=True): fail_json(rc, stdout, stderr,
        # msg=the sanitized stderr itself - no "make failed:" prefix).
        return PluginResult.new(changed: false, failed: true, msg: sanitize(result[:stderr]), stdout: sanitize(result[:stdout]), stderr: sanitize(result[:stderr]), rc: result[:exit_code])
      end

      PluginResult.new(changed: true, failed: false, stdout: sanitize(result[:stdout]), stderr: sanitize(result[:stderr]), command: full_command,
        failed_flag: true, target: target, targets: targets, params: params_val, chdir: chdir, file: @params["file"]?, jobs: @params["jobs"]?,
        key_order: %w[changed failed stdout stderr target targets params chdir file jobs command])
    end

    private def py_str(value : JSON::Any) : String
      case value.raw
      when String  then value.as_s
      when Bool    then value.as_bool ? "True" : "False"
      when Int64   then value.as_i64.to_s
      when Float64 then value.as_f.to_s
      else              value.to_s
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
        return candidate if File::Info.executable?(candidate) && !File.directory?(candidate)
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
