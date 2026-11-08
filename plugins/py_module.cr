#!/usr/bin/env crystal

require "json"
require "base64"
require "file_utils"
require "../src/krikri/base_plugin"
require "../src/krikri/python_module_runner"
require "../src/krikri/plugin_helpers/python_lib_gate"
require "../src/krikri/plugin_helpers/ansible_splitlines"

module Krikri
  # PythonModuleRunner plugin - executes a role-private custom module
  # (a `library/*.py` the playbook/role ships) on THIS host using the
  # target's own python3, the same way Ansible runs arbitrary
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
  #     and the ANSIBLE_CHECK_MODE env var (Ansible runs custom
  #     modules under check mode too; a module that doesn't support it
  #     is expected to report no changes itself).
  #
  # The module's stdout is scanned for its result JSON (Ansible modules
  # print one; anything before it - warnings, prints - is stripped the
  # way Ansible strips it). A module that never printed JSON fails
  # with its rc and raw output, matching Ansible's
  # "MODULE FAILURE" shape.
  class PyModulePlugin < BasePlugin
    # A python module's ansible.module_utils import deprecations come from
    # ITS OWN imports, which the shim bundle reproduces at run time (its
    # _text/_collections_compat shims record them, and exit_json/fail_json
    # put them on the result in real's shape).
    # BasePlugin#finalize_result's table is for the modules this engine runs
    # WITHOUT python and is keyed by module name, so a role's own
    # library/<name>.py shadowing a natively implemented module of the same
    # name would otherwise gain deprecations its source never triggers.
    def finalize_result(result : PluginResult) : PluginResult
      result
    end

    def execute : PluginResult
      source_b64 = @params["module_source"]?
      unless source_b64
        return PluginResult.new(changed: false, failed: true, msg: "py_module: missing module_source")
      end

      module_name = @params["module_name"]? || "custom_module"
      new_style = @params["new_style"]? != "false"
      check_mode = true?(@params["_ansible_check_mode"]?)
      args_json = @params["module_args"]? || "{}"
      kv_argv = @params["kv_argv"]? || "[]"
      # The controller's INJECT_INVOCATION resolution (see
      # InvocationInjection): the flag rides OUTSIDE module_args and rides
      # with EVERY new-style module run, true or false, the way real 2.21's
      # action layer passes it - the work-dir-local shim bundle below
      # (which always shadows any installed ansible-core) mirrors real
      # _return_formatted's inject-or-pop on it.
      inject_invocation = true?(@params["_ansible_inject_invocation"]?)

      source = begin
        String.new(Base64.decode(source_b64))
      rescue ex
        return PluginResult.new(changed: false, failed: true, msg: "py_module: bad module_source: #{ex.message}")
      end

      # Which interpreter runs the module: Ansible executes a custom
      # module THROUGH ITS OWN SHEBANG LINE (rewritten to the resolved
      # interpreter path), not always python3 - a shell module like
      # linux-system-roles.timesync's library/timesync_provider.sh
      # (#!/bin/bash) previously ran as `python3 <module>.py` and died on
      # its first bash syntax (round 970350). A shebang line naming a
      # python interpreter (or no shebang at all - the controller's
      # missing-interpreter guard has already failed shebangless
      # old-style modules by then) keeps the python path unchanged.
      first_line = source.lines.first?
      python_module = first_line.nil? || !first_line.starts_with?("#!") ||
                      first_line.includes?("python")

      # The interpreter's own path lands in the module's
      # missing_required_lib message (basic.py embeds sys.executable),
      # and Ansible runs the module under ITS discovered interpreter - a
      # bare `python3` here made the message name /usr/bin/python3 where
      # real named /usr/bin/python3.13 (issue #557, observed on
      # linux-system-roles.selinux's library/selinux_modules_facts.py).
      # Prefer the same discovery Ansible does; the plain PATH lookup
      # stays as the fallback for a target where no fallback name
      # resolves.
      #
      # An interpreter the task's vars name wins over discovery, as in
      # real's _get_shebang: a `delegate_to: localhost` task runs under
      # the implicit localhost's ansible_python_interpreter (the Python
      # ansible itself runs under, where libraries installed beside
      # ansible live - boto3 for amazon.aws, issue #1005) and an
      # inventory-pinned ansible_python_interpreter decides the run
      # instead of whichever python3 discovery happens to find first.
      python = Krikri.interpreter_from_vars(@vars) || Krikri.discovered_target_python ||
               %w[python3 python].find { |bin| !`command -v #{bin} 2>/dev/null`.strip.empty? }
      if python_module && !python
        return PluginResult.new(changed: false, failed: true, msg: "py_module: no python3/python on the target - cannot run custom module #{module_name}")
      end
      # 0700 + Random::Secure: the dir (and anything we write into it,
      # including the shim bundle below) must not be readable by other
      # local users, and the name must not be predictable enough to
      # race (a pre-planted dir with symlinked contents would otherwise
      # turn File.write below into an arbitrary-file-write).
      work_dir = File.join(Dir.tempdir, "krikri-pymod-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(work_dir, 0o700)
      File.chmod(work_dir, 0o700)
      module_path = File.join(work_dir, "#{module_name.gsub(/[^\w.-]/, "_")}.py")
      File.write(module_path, source)
      File.chmod(module_path, 0o500)

      # A new-style module's `from ansible.module_utils.basic import
      # AnsibleModule` needs module_utils importable ON THE TARGET. Real
      # Ansible never requires ansible-core there: the AnsiballZ wrapper
      # bundles the CONTROLLER's module_utils INTO the module payload it
      # ships, and the target's own install (if any) is never imported.
      # This plugin runs the raw module script instead, so the shim
      # bundle is written into the module's own directory on EVERY
      # new-style run - Python puts the script's directory first on
      # sys.path, and a regular package there wins, so the shim shadows
      # any installed ansible-core exactly like the bundled payload
      # does. Previously the bundle was probe-gated (written only where
      # the `from ansible.module_utils.basic import AnsibleModule`
      # import failed - found via newrelic.newrelic-infra's own "Setup
      # agent config *NIX": the role ships its own library/merge_yaml.py,
      # which died with ModuleNotFoundError on every fresh target), and
      # a target WITH ansible-core kept importing its own real
      # basic.py, whose version then decided the invocation echo (issue
      # #915): a pre-2.21 basic.py neither knows
      # `_ansible_inject_invocation` nor injects `invocation`, so the
      # echo vanished where real always shows one. The trade: the shim
      # (not the target's basic.py) now defines the module's import
      # surface everywhere - accepted, since any module real runs
      # successfully must already be compatible with controller-2.21
      # module_utils, which the shim mirrors.
      #
      # A role shipping its OWN custom module_utils packages (e.g.
      # linux-system-roles.storage's the Ansible module beside its
      # library/blivet.py) gets that tree staged under
      # the Ansible module here too, the way Ansible's AnsiballZ
      # wrapper bundles the role's own module_utils into the zipapp. The
      # controller only sends this when the role actually ships a
      # module_utils/ tree (see executor_run_loop's dispatch), so the
      # common no-module_utils role costs nothing. The standard
      # shims are written FIRST and role files never overwrite an
      # existing staged path: a role shipping its own module_utils/basic.
      # py (a name colliding with the shim) keeps the shim, noted here as
      # an accepted edge case rather than solved.
      PythonModuleRunner.write_module_utils_bundle(work_dir) if python_module && python
      staged_utils = begin
        raw = @params["module_utils_files"]?
        raw.nil? || raw.empty? ? nil : JSON.parse(raw).as_h
      rescue
        nil
      end
      if staged_utils && !staged_utils.empty?
        staged_utils.each do |rel, encoded|
          next unless encoded.as_s?
          rel_path = rel
          # Path-traversal guard on the controller-supplied relative
          # path: only plain subdirectory components under
          # the Ansible module are ever staged.
          next if rel_path.empty? || rel_path.starts_with?('/')
          next if rel_path.split('/').includes?("..")
          dest = File.join(work_dir, "ansible", "module_utils", rel_path)
          next if File.exists?(dest)
          begin
            content = String.new(Base64.decode(encoded.as_s))
          rescue
            next
          end
          FileUtils.mkdir_p(File.dirname(dest))
          File.write(dest, content)
        end
      end

      env = ENV.to_h
      env["ANSIBLE_MODULE_NAME"] = module_name
      env["ANSIBLE_CHECK_MODE"] = check_mode ? "1" : "0"

      # Real ansible never needs the collections importable on the
      # target: its AnsiballZ wrapper bundles every
      # ansible_collections.<ns>.<coll>.plugins.module_utils.* import
      # INTO the module payload it ships, so `from
      # ansible_collections.amazon.aws.plugins.module_utils.retries
      # import AWSRetry` (the standard AnsibleAWSModule pattern) runs on
      # a python that cannot import the collection at all. This plugin
      # runs the raw script with the target's python instead, so when
      # that python is not the one the collections were installed into
      # (Homebrew's isolated Cellar interpreter, issue #692; a galaxy
      # user install under ~/.ansible/collections, which no python has
      # on sys.path) the import died with ModuleNotFoundError where
      # ansible-playbook ran the module fine. Only modules that actually
      # reference the collection namespace get the extra path - a
      # module importing nothing beyond ansible.module_utils keeps
      # working exactly as before.
      if python_module && source.includes?("ansible_collections")
        collection_roots = PythonModuleRunner.collection_import_roots
        unless collection_roots.empty?
          existing = env["PYTHONPATH"]?
          env["PYTHONPATH"] = existing && !existing.empty? ? "#{existing}:#{collection_roots.join(":")}" : collection_roots.join(":")
        end
      end

      # The bundle above is written on every new-style run, so the
      # module always runs against the shim and the invocation flag
      # always rides with the args (a non-python module keeps the
      # pre-shim no-flag behavior - its protocol has no
      # _return_formatted to interpret the key).
      shim_staged = python_module && !python.nil?
      if new_style
        parsed_args = begin
          JSON.parse(args_json).as_h
        rescue
          nil
        end
        if parsed_args
          if shim_staged
            # Mirror the real 2.21 action layer: the flag rides with EVERY
            # module run, true or false, and the shim's _return_formatted
            # equivalent injects or pops `invocation` off it.
            parsed_args["_ansible_inject_invocation"] = JSON::Any.new(inject_invocation)
          else
            parsed_args.delete("_ansible_inject_invocation")
          end
          args_json = JSON::Any.new(parsed_args).to_json
        end
      end

      argv = if python_module && (py = python)
               new_style ? [py, module_path] : ([py, module_path] + parse_kv_argv(kv_argv))
             else
               # Ansible's non-python module protocols (module dev docs):
               # a module whose source contains WANT_JSON receives its whole
               # argument dict as ONE serialized-JSON argv element; everything
               # else gets old-style key=value. Executed directly (the file is
               # chmod +x) so the kernel honors the module's own shebang.
               if source.includes?("WANT_JSON")
                 [module_path, args_json]
               else
                 [module_path] + parse_kv_argv(kv_argv)
               end
             end

      # A new-style module reads its args via ansible-core's own
      # `_debugging.load_params()` - the debug-invocation path every
      # module falls back to when it isn't run through the real
      # AnsiballZ wrapper (exactly this plugin's situation: it runs the
      # raw module script directly with `python3 module.py`, argv[1]
      # omitted). That path reads a JSON blob from STDIN - NOT an
      # `ANSIBLE_MODULE_ARGS` environment variable, which
      # ansible-core 2.19's basic.py doesn't read at all - and the blob
      # must be a WRAPPER object, `{"ANSIBLE_MODULE_ARGS": {...actual
      # args...}}`, or `_load_params` raises "ANSIBLE_MODULE_ARGS not
      # provided." even with real args present at the top level.
      # Confirmed live against ansible-core 2.19.4's own
      # `the Ansible module` - the previous env-var
      # approach failed EVERY new-style module invocation with "Failed
      # to decode JSON module parameters." (no valid JSON on stdin at
      # all), silently masking the whole 0.9.819 py_module feature for
      # any module using the common `from ansible.module_utils.basic
      # import AnsibleModule` shape - found re-testing linux-system-
      # roles.storage's own `sr_fingerprint`/`blivet`.
      stdin_payload = new_style ? %({"ANSIBLE_MODULE_ARGS": #{args_json}}) : nil

      stdout = IO::Memory.new
      stderr = IO::Memory.new
      process = Process.new(
        argv[0], argv[1..], env: env, output: stdout, error: stderr,
        input: stdin_payload ? Process::Redirect::Pipe : Process::Redirect::Close
      )
      if stdin_payload
        process.input.print(stdin_payload)
        process.input.close
      end
      status = process.wait
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
        # Real _return_formatted's inject-or-pop runs INSIDE the module
        # (the shim's own exit_json/fail_json, which always sees the
        # `_ansible_inject_invocation` flag since #915's always-bundle):
        # an `invocation` echo rides the controller result untouched when
        # the resolution is on and is popped when it is off - dropping it
        # here instead vanished the echo on every path (issue #915).
        result_hash.delete("invocation") unless inject_invocation
        result_hash.each do |key, value|
          # Real ansible drops a module's own fail_json(exception=...) key from
          # the controller result - it surfaces only at -vvv, never in the
          # [ERROR] block (issue #557). Keeping it here would feed
          # result_display's "<msg>: <exception>" composition, which is meant
          # only for krikri-native plugins emulating a controller-side
          # ErrorSummary.
          next if key.in?("changed", "failed", "msg", "exception")
          extra[key] = value
        end

        # The ErrorSummary object a real basic.py fail_json(exception=...)
        # emits is dropped above like any exception key (issue #557), but
        # real ansible still composes the "[ERROR] <msg>: <cause>" header
        # from its cause chain (issue #384) - hand the chain text to
        # result_display under the same internal key the shim's fail_json
        # already uses.
        if summary = PythonModuleRunner.error_exception_summary(JSON::Any.new(result_hash))
          extra["_ansible_error_exception"] = JSON::Any.new(summary)
        end

        result = PluginResult.new(changed: changed, failed: failed, msg: msg)
        result.extra.merge!(extra)
        unless err_text.empty?
          result.extra["stderr"] = JSON::Any.new(err_text)
        end
        # Real ansible derives stdout_lines/stderr_lines for the displayed
        # failed result even when the module's own JSON only carries the
        # bare strings (issue #384's missing-binary run) - without them the
        # fatal result dump diverges.
        if failed
          {"stdout", "stderr"}.each do |stream|
            next if result.extra.has_key?("#{stream}_lines")
            next unless text = result.extra[stream]?.try(&.as_s?)
            result.extra["#{stream}_lines"] = JSON::Any.new(
              PluginHelpers::AnsibleSplitlines.split(text).map { |line| JSON::Any.new(line) }
            )
          end
        end
        return result
      end

      # Ansible's AnsiballZ loader catches Exception around the module
      # run and reports it as a clean module failure - the raw run here
      # instead leaves the traceback on stderr with no result JSON.
      # BaseException-only exits (SystemExit etc., nil from the helper,
      # or no traceback at all) still fall through to MODULE FAILURE.
      if python_module && (detail = PythonModuleRunner.uncaught_exception_detail(err_text))
        crash = PluginResult.new(changed: false, failed: true,
          msg: detail.empty? ? "Task failed: Module failed." : "Task failed: Module failed: #{detail}",
          _ansible_error_detail: detail)
        return crash
      end

      # No result JSON at all - Ansible's MODULE FAILURE shape.
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
