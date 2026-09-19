#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/get_bin_path"

module Krikri
  # Getent Plugin - populate a host's fact dict from a system database
  # (passwd, shadow, group, hosts, services, ...), matching
  # ansible.builtin.getent. Registers the result as facts under
  # `getent_<database>` (e.g. getent_passwd, getent_shadow) so later tasks
  # can read `ansible_facts.getent_passwd[user][1]` etc.
  #
  # Real getent.py forks the ACTUAL `getent` binary (get_bin_path
  # required=True) and maps its exit code: 0 -> parse, 1 -> "Missing
  # arguments, or database unknown.", 2 -> not-found (fail_key decides
  # fail vs null), 3 -> "Enumeration not supported on this database.",
  # anything else -> "Unexpected failure!". This plugin used to parse the
  # database files directly instead, which diverged wherever libc's NSS
  # resolution order differs from file order - `getent hosts localhost`
  # returns the ::1 line (AF_INET6 preferred) while /etc/hosts lists
  # 127.0.0.1 first, so the fact was keyed "127.0.0.1" here and "::1" in
  # real Ansible; keyed services lookups hit the same ordering gap. Found
  # via the podman-diff getent_edge_cases harness. Forking the binary the
  # way real does makes NSS itself the source of truth (and resolves the
  # old `service:` deliberate limit for free - `-s` is passed through).
  #
  # The parse format is Ansible's: each output line maps to a list of the
  # delimiter-separated fields *after* the key field. For passwd the key
  # is the username and the value is `[password, uid, gid, gecos, home,
  # shell]`, so `getent_passwd["root"][1]` is the UID and `[4]` the home
  # directory. `split:` defaults to ':' only for passwd/shadow/group/
  # gshadow (the module's own `colon` list); every other database splits
  # on runs of whitespace (`getent hosts localhost` ->
  # "127.0.0.1  localhost  ip6-..."). A duplicate key (tcp+udp service
  # pairs) becomes a list of field-lists on enumeration only.
  class GetentPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Databases real Ansible colon-splits by default; everything else
    # (hosts, services, protocols, ...) splits on runs of whitespace.
    private COLON_DATABASES = ["passwd", "shadow", "group", "gshadow"]

    # Real argument_spec (ansible-core 2.14 getent.py), insertion order -
    # no aliases, so the unsupported-params message has no parenthetical.
    SPEC = {
      "database" => %w[],
      "key"      => %w[],
      "service"  => %w[],
      "split"    => %w[],
      "fail_key" => %w[],
    }

    EXTRA_BIN_DIRS = %w[/sbin /usr/sbin /bin /usr/bin]
    @searched_paths = ""

    def execute : PluginResult
      if error = validate_params
        return error
      end

      # get_bin_path('getent', required=True) runs right after module
      # validation, before any database work - a host without the getent
      # binary fails the task no matter how well-formed the args are.
      getent_bin = find_binary("getent")
      unless getent_bin
        return PluginResult.new(
          changed: false,
          failed: true,
          msg: PluginHelpers::GetBinPath.missing_executable_error("getent", @searched_paths)
        )
      end

      database = @params["database"].to_s
      key = @params["key"]?
      service = @params["service"]?
      split = @params["split"]?
      fail_key = @params["fail_key"]? ? true?(@params["fail_key"]) : true

      cmd = "#{getent_bin} #{sh_quote(database)}"
      cmd += " #{sh_quote(key)}" if key
      cmd += " -s #{sh_quote(service)}" if service

      result = remote_exec(cmd)
      rc = result[:exit_code]

      if split.nil? && COLON_DATABASES.includes?(database)
        split = ":"
      end

      dbtree = "getent_#{database}"
      case rc
      when 0
        facts = parse_output(result[:stdout].to_s, split)
        PluginResult.new(
          changed: false,
          failed: false,
          msg: "",
          ansible_facts: JSON::Any.new({dbtree => JSON::Any.new(facts)}),
          invocation: invocation_block(database)
        )
      when 1
        fail_result(database, "Missing arguments, or database unknown.")
      when 2
        # rc 2 = the requested key isn't in the database: fail_key (the
        # spec default) fails the task; with fail_key: false real exits
        # SUCCESSFULLY with the key mapped to a real JSON null and the
        # not-found message still on the result - `getent_passwd[key] ==
        # none` is exactly how a role decides "this user doesn't exist
        # yet, create it" (found via filviu.activemq/.tomcat's "env |
        # determine if <user> exists" -> "setup | create system user"
        # pair; an empty array `!= none` under real Python/Jinja equality
        # is the bug class that used to skip user creation silently).
        unless fail_key
          facts = Hash(String, JSON::Any).new
          facts[key.to_s] = JSON::Any.new(nil)
          return PluginResult.new(
            changed: false,
            failed: false,
            msg: "One or more supplied key could not be found in the database.",
            ansible_facts: JSON::Any.new({dbtree => JSON::Any.new(facts)}),
            invocation: invocation_block(database)
          )
        end
        fail_result(database, "One or more supplied key could not be found in the database.")
      when 3
        fail_result(database, "Enumeration not supported on this database.")
      else
        fail_result(database, "Unexpected failure!")
      end
    end

    # Real argument-spec validation order (established across the
    # sudoers/pamd/pam_limits/sefcontext/ufw fixes): required args first
    # (sorted plural wording), then type conversion (fail_key is the
    # spec's only bool), then unsupported params in the live-verified
    # sorted format.
    private def validate_params : PluginResult?
      unless @params.has_key?("database")
        return PluginResult.new(changed: false, failed: true,
          msg: "missing required arguments: database")
      end

      if raw = @params["fail_key"]?
        unless bool_convertible?(raw)
          return bool_type_error("fail_key", raw)
        end
      end

      if unsupported = unsupported_param_keys(@params, SPEC)
        unless unsupported.empty?
          return unsupported_params_error("ansible.builtin.getent", unsupported, SPEC)
        end
      end

      nil
    end

    private def fail_result(database : String, msg : String) : PluginResult
      PluginResult.new(
        changed: false,
        failed: true,
        msg: msg,
        invocation: invocation_block(database)
      )
    end

    # Real module's rc==0 parse: `record = line.split(split)` per line,
    # keyed by record[0] with the remaining fields as the value. A key
    # appearing more than once (e.g. a service listed for both tcp and
    # udp in /etc/services) becomes a list of field-lists (real 2.11+
    # enumeration handling).
    private def parse_output(output : String, split : String?) : Hash(String, JSON::Any)
      results = Hash(String, JSON::Any).new
      seen = Hash(String, Int32).new

      output.each_line do |line|
        fields = split ? line.split(split) : line.split
        next if fields.empty?
        key = fields.shift
        value = JSON::Any.new(fields.map { |field| JSON::Any.new(field) })
        if seen.has_key?(key)
          if seen[key] == 1
            existing = results[key]
            results[key] = JSON::Any.new([existing])
          end
          results[key] = JSON::Any.new(results[key].as_a + [value])
          seen[key] += 1
        else
          results[key] = value
          seen[key] = 1
        end
      end

      results
    end

    # Real Ansible's module protocol (module_utils/basic.py's
    # _return_formatted, called from both exit_json and fail_json) ALWAYS
    # attaches `invocation: {module_args: <the module's params>}` to a
    # module's raw JSON result - so it is present on a failing lookup
    # exactly as on a successful one. Round 813375 (galaxyproject.pulsar)
    # reads `item.invocation.module_args.key` off a looped+registered
    # getent task to recover the ORIGINAL key that produced each
    # results[] entry, then uses it to index
    # `ansible_facts.getent_passwd[...]`; without this block the key
    # resolved to None and `[2]` on it crashed with "None has no element
    # 2". module_args mirrors the RAW param values exactly as real
    # Ansible reports them: `split:` stays null when the user didn't pass
    # it (the ':' colon-database default above is internal, not reported)
    # and `fail_key` is the boolean the user's value (or its default)
    # produces. Note the controller separately strips a top-level
    # `invocation` from a NON-looped register (ansible-core's strategy
    # plugin does the same); only the per-item entries inside a looped
    # register's results[] are meant to expose it - which is exactly the
    # access path the pulsar role's pattern takes.
    private def invocation_block(database : String) : JSON::Any
      args = Hash(String, JSON::Any).new
      args["database"] = JSON::Any.new(database)
      args["fail_key"] = JSON::Any.new(@params["fail_key"]? ? true?(@params["fail_key"]) : true)
      args["key"] = (v = @params["key"]?) ? JSON::Any.new(v) : JSON::Any.new(nil)
      args["service"] = (v = @params["service"]?) ? JSON::Any.new(v) : JSON::Any.new(nil)
      args["split"] = (v = @params["split"]?) ? JSON::Any.new(v) : JSON::Any.new(nil)
      JSON::Any.new({"module_args" => JSON::Any.new(args)})
    end

    private def find_binary(name : String) : String?
      script = <<-SH
        found=""
        for d in $(printf '%s' "$PATH" | tr ':' ' ') #{EXTRA_BIN_DIRS.join(' ')}; do
          if [ -z "$found" ] && [ -x "$d/#{name}" ]; then found="$d/#{name}"; fi
        done
        searched=""
        for d in $(printf '%s' "$PATH" | tr ':' ' ') #{EXTRA_BIN_DIRS.join(' ')}; do
          case ":$searched:" in *":$d:"*) ;; *) searched="${searched:+$searched:}$d" ;; esac
        done
        printf '%s\\n%s' "$found" "$searched"
        SH

      result = remote_exec(script)
      found, _, searched = result[:stdout].to_s.strip.partition("\n")
      @searched_paths = searched
      found.empty? ? nil : found
    end

    private def sh_quote(value : String) : String
      "'" + value.gsub("'", "'\\''") + "'"
    end
  end
end

# Entry point
input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::GetentPlugin.new(config)
plugin.run
