#!/usr/bin/env crystal

require "json"
require "base64"
require "file_utils"
require "../src/krikri/base_plugin"
require "../src/krikri/python_module_runner"

module Krikri
  # PythonModuleRunner plugin - executes a role-private custom module
  # (a `library/*.py` the playbook/role ships) on THIS host using the
  # target's own python3, the same way real Ansible runs arbitrary
  # Python modules. The controller-side PythonModuleRunner module
  # (src/krikri/python_module_runner.cr) resolves the source and
  # decides new-style (JSON args via the ANSIBLE_MODULE_ARGS env var
  # the module's own AnsibleModule reads) vs old-style (key=value
  # argv); this plugin does the write-to-temp-file + run + result-JSON
  # extraction on the target side, through the normal plugin transport
  # (local spawn or the uploaded-binary SSH path every other plugin
  # uses).
  #
  # Parameters (set by the TaskExecutor dispatch, not by the user):
  #   module_source (required): base64-encoded module source.
  #   module_name (optional): the module's short name - used for the
  #     temp file name and error messages.
  #   module_args (optional): JSON-encoded argument dict for a
  #     new-style module (plus the reserved `_ansible_*` keys).
  #   kv_argv (optional): JSON-encoded array of `key=value` strings for
  #     an old-style module.
  #   new_style (required): "true"/"false" - the invocation shape.
  #   check_mode: passed through into the module's `_ansible_check_mode`
  #     and the ANSIBLE_CHECK_MODE env var (real Ansible runs custom
  #     modules under check mode too; a module that doesn't support it
  #     is expected to report no changes itself).
  #
  # The module's stdout is scanned for its result JSON (real modules
  # print one; anything before it - warnings, prints - is stripped the
  # way real Ansible strips it). A module that never printed JSON fails
  # with its rc and raw output, matching real Ansible's
  # "MODULE FAILURE" shape.
  class PyModulePlugin < BasePlugin
    def execute : PluginResult
      source_b64 = @params["module_source"]?
      unless source_b64
        return PluginResult.new(changed: false, failed: true, msg: "py_module: missing module_source")
      end

      module_name = @params["module_name"]? || "custom_module"
      new_style = @params["new_style"]? != "false"
      check_mode = true?(@params["check_mode"]?)
      args_json = @params["module_args"]? || "{}"
      kv_argv = @params["kv_argv"]? || "[]"

      source = begin
        String.new(Base64.decode(source_b64))
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: "py_module: bad module_source: #{ex.message}")
      end

      python = %w[python3 python].find { |bin| !`command -v #{bin} 2>/dev/null`.strip.empty? }
      unless python
        return PluginResult.new(changed: false, failed: true, msg: "py_module: no python3/python on the target - cannot run custom module #{module_name}")
      end

      work_dir = File.join(Dir.tempdir, "krikri-pymod-#{Process.pid}-#{Random.rand(1_000_000)}")
      Dir.mkdir_p(work_dir)
      module_path = File.join(work_dir, "#{module_name.gsub(/[^\w.-]/, "_")}.py")
      File.write(module_path, source)
      File.chmod(module_path, 0o500)

      env = ENV.to_h
      if new_style
        env["ANSIBLE_MODULE_ARGS"] = args_json
        env["ANSIBLE_MODULE_NAME"] = module_name
        env["ANSIBLE_CHECK_MODE"] = check_mode ? "1" : "0"
      else
        env["ANSIBLE_CHECK_MODE"] = check_mode ? "1" : "0"
      end

      argv = new_style ? [python, module_path] : ([python, module_path] + parse_kv_argv(kv_argv))

      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(argv[0], argv[1..], env: env, output: stdout, error: stderr)
      rc = status.exit_code

      begin
        FileUtils.rm_r(work_dir)
      rescue
      end

      out_text = stdout.to_s
      err_text = stderr.to_s

      if parsed = PythonModuleRunner.parse_module_output(out_text)
        result_hash = parsed.as_h
        changed = result_hash["changed"]?.try(&.as_bool?) || false
        failed = result_hash["failed"]?.try(&.as_bool?) || false
        msg = result_hash["msg"]?.try(&.as_s?) || (failed ? "Module failed (see result)" : "")

        extra = Hash(String, JSON::Any).new
        result_hash.each do |key, value|
          next if key.in?("changed", "failed", "msg", "invocation")
          extra[key] = value
        end

        result = PluginResult.new(changed: changed, failed: failed, msg: msg)
        result.extra.merge!(extra)
        unless err_text.empty?
          result.extra["stderr"] = JSON::Any.new(err_text)
        end
        return result
      end

      # No result JSON at all - real Ansible's MODULE FAILURE shape.
      result = PluginResult.new(
        changed: false,
        failed: true,
        msg: "MODULE FAILURE (rc=#{rc}): module #{module_name} printed no result JSON",
      )
      result.extra["rc"] = JSON::Any.new(rc.to_i64)
      result.extra["stdout"] = JSON::Any.new(out_text)
      result.extra["stderr"] = JSON::Any.new(err_text)
      result
    rescue ex : Exception
      PluginResult.new(changed: false, failed: true, msg: "py_module failed: #{ex.message}")
    end

    private def parse_kv_argv(kv_json : String) : Array(String)
      parsed = JSON.parse(kv_json)
      parsed.as_a?.try(&.map(&.as_s)) || [] of String
    rescue
      [] of String
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::PyModulePlugin.new(config)
plugin.run
