require "json"
require "base64"

# Runner for role-private custom modules - a role's own `library/*.py`,
# outside the plugin set this engine ships as native binaries. Real
# Ansible executes these as ordinary Python on the target; the previous
# scope cut skipped them with a parse-time "uses unimplemented plugin"
# warning (exit 4 via reachable_unavailable_modules since 0.9.558),
# which diverged on every role leaning on its own library/ - seen
# repeatedly benchmarking linux-system-roles (sr_fingerprint,
# timesync_provider, kernel_settings_get_config, blivet).
#
# The runner delegates to the TARGET's own python3, the same way real
# Ansible does - no Python is embedded or reimplemented here. The
# module source is uploaded and executed through the same plugin-binary
# transport everything else uses (see plugins/py_module.cr), so local
# and SSH connections both work without any new plumbing.
#
# Deliberately scoped to role-private `library/` directories and the
# playbook-adjacent `library/` (real Ansible's two most common search
# roots); third-party COLLECTION modules (bodsch.*, community.*) are
# still the unchanged scope cut - those live inside installed
# collections on the comparison side, not in the playbook tree this
# runner can see.
module Krikri
  module PythonModuleRunner
    extend self

    # Short module name for the FQCN spellings a task can write
    # (`sr_fingerprint`, `linux_system_roles.sr_fingerprint`, ...).
    def short_name(module_name : String) : String
      module_name.rpartition('.')[2]
    end

    # Finds a role-private module source for *module_name*, or nil.
    # Search roots mirror real Ansible's two most-used locations: the
    # current role's own `library/` (role_files_dir points at
    # <role>/files, so the role root is one level up) and the
    # playbook-adjacent `library/`. First match wins (real Ansible's
    # own nearest-first order).
    def find_source(module_name : String, role_files_dir : String?, playbook_dir : String?) : String?
      short = short_name(module_name)
      return nil if short.empty?

      roots = [] of String
      roots << File.join(File.dirname(role_files_dir), "library") if role_files_dir
      roots << File.join(playbook_dir, "library") if playbook_dir && !playbook_dir.empty?

      roots.each do |root|
        candidate = File.join(root, "#{short}.py")
        return candidate if File.file?(candidate)
      end
      nil
    end

    # Real Ansible's own new-style detection (ansiballz): a module
    # importing ansible.module_utils gets its args as a JSON dict (via
    # the ANSIBLE_MODULE_ARGS env var its basic.py reads when no argv
    # is given); everything else is old-style key=value argv.
    def new_style?(source : String) : Bool
      source.includes?("from ansible.module_utils") ||
        source.includes?("import ansible.module_utils") ||
        source.includes?("ansible.module_utils.basic")
    end

    # The module's argument dict: the substituted task params (already
    # stringified by the parser) re-typed as JSON where they parse -
    # the parser JSON-encodes list/dict-valued params verbatim, so
    # `"['a','b']"` becomes a real array for the module, the way real
    # Ansible passes typed args. Plus real Ansible's own reserved
    # `_ansible_*` keys a new-style module's AnsibleModule reads.
    def build_module_args(params : Hash(String, String), check_mode : Bool) : String
      args = Hash(String, JSON::Any).new
      args["_ansible_check_mode"] = JSON::Any.new(check_mode)
      args["_ansible_diff"] = JSON::Any.new(false)
      args["_ansible_verbosity"] = JSON::Any.new(0_i64)
      params.each do |key, value|
        next if key.in?("check_mode", "diff_mode", "_verbosity", "_environment")
        args[key] = typed_value(value)
      end
      args.to_json
    end

    # The old-style key=value argv line (one entry per param).
    def build_kv_argv(params : Hash(String, String)) : Array(String)
      params.reject { |key, _| key.in?("check_mode", "diff_mode", "_verbosity", "_environment") }
        .map do |key, value|
          "#{key}=#{value}"
        end
    end

    private def typed_value(value : String) : JSON::Any
      stripped = value.strip
      return JSON.parse(stripped) if stripped.starts_with?('{') || stripped.starts_with?('[')
      return JSON::Any.new(true) if stripped == "true" || stripped == "True"
      return JSON::Any.new(false) if stripped == "false" || stripped == "False"
      return JSON::Any.new(nil) if stripped == "None" || stripped == "null"
      if int = stripped.to_i64?
        return JSON::Any.new(int)
      end
      JSON::Any.new(value)
    end

    # Parses the module's stdout into its result JSON: real modules
    # print a JSON object (pretty or single-line), possibly preceded by
    # other output (warnings, prints) that real Ansible also strips.
    # Walks backwards from the end for the first offset where a JSON
    # object parse succeeds.
    def parse_module_output(stdout : String) : JSON::Any?
      idx = stdout.size
      while pos = stdout.rindex('{', idx - 1)
        if parsed = (JSON.parse(stdout[pos..]) rescue nil)
          return parsed if parsed.as_h?
        end
        idx = pos
      end
      nil
    end
  end
end
