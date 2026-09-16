require "json"
require "../base_plugin"

module Krikri
  module PluginHelpers
    # AnsibleArgValidation - reusable fragments of real AnsibleModule's
    # argument-validation surface (ansible-core's parameters.py /
    # validation.py / arg_spec.py wordings), for the plugins that
    # hand-roll their own argument-spec checks the way the real module's
    # AnsibleModule setup does. Each plugin owns its own merged-spec
    # ORDER (real iterates the merged argument_spec in declaration
    # order and only ever surfaces errors[0]); this module only owns
    # the per-check wording so the copies can't drift apart.
    module AnsibleArgValidation
      # convert_bool.py's BOOLEANS_TRUE / BOOLEANS_FALSE (the string
      # members; int/bool members can't reach a plugin - wire values
      # are always strings). boolean() lowercases and strips first.
      REAL_TRUE  = %w[y yes on 1 true t]
      REAL_FALSE = %w[n no off 0 false f]
      # convert_bool.py's BOOLEANS, repr'd - real Ansible iterates a
      # Python SET here, so the order differs between module processes
      # (PYTHONHASHSEED); this fixed order is one of the orders real
      # emits, and only the wording shape is deterministic.
      BOOLEANS_REPR = %w[y yes on '1' 'true' 't' 1 1.0 True n no off '0' 'false' 'f' 0 0.0 False]

      def bool_convertible?(raw : String) : Bool
        normalized = raw.downcase.strip
        REAL_TRUE.includes?(normalized) || REAL_FALSE.includes?(normalized)
      end

      def bool_type_error(param : String, raw : String) : PluginResult
        PluginResult.new(changed: false, failed: true,
          msg: "argument '#{param}' is of type <class 'str'> and we were unable to convert to bool: " \
               "The value '#{raw}' is not a valid boolean.  Valid booleans include: #{BOOLEANS_REPR.join(", ")}")
      end

      def int_type_error(param : String, raw : String) : PluginResult
        PluginResult.new(changed: false, failed: true,
          msg: "argument '#{param}' is of type <class 'str'> and we were unable to convert to int: " \
               "<class 'str'> cannot be converted to an int")
      end

      def choices_error(param : String, allowed : Array(String), value : String) : PluginResult
        PluginResult.new(changed: false, failed: true,
          msg: "value of #{param} must be one of: #{allowed.join(", ")}, got: #{value}")
      end

      def missing_required_error(missing : Array(String)) : PluginResult
        PluginResult.new(changed: false, failed: true,
          msg: "missing required arguments: #{missing.sort.join(", ")}")
      end

      def required_together_error(group : Array(String)) : PluginResult
        PluginResult.new(changed: false, failed: true,
          msg: "parameters are required together: #{group.join(", ")}")
      end

      # Real UnsupportedError tail - the live-verified format (bookworm
      # ansible-core 2.14's basic.py, observed via the podman-diff
      # docker_login/docker_network/docker_network_info cases): spec
      # keys sorted, then ONE trailing parenthetical holding ALL the
      # spec's aliases, sorted together, attached to the last name.
      def unsupported_params_error(module_name : String, unsupported : Array(String), spec : Hash(String, Array(String))) : PluginResult
        names = spec.keys.sort!
        aliases = spec.values.flatten.sort!
        supported = aliases.empty? ? names.join(", ") : "#{names.join(", ")} (#{aliases.join(", ")})"
        PluginResult.new(changed: false, failed: true,
          msg: "Unsupported parameters for (#{module_name}) module: " \
               "#{unsupported.sort.join(", ")}. Supported parameters include: #{supported}.")
      end

      # Real _get_unsupported_parameters: any param key outside the spec
      # names and their aliases. Engine-internal executor keys never
      # reach the real module's params - real strips the _ansible_*
      # internal-args namespace generically before argspec validation
      # (check_mode/diff_mode ride in there), while a user-supplied
      # check_mode is NOT in that namespace and fails validation like
      # any other unsupported param.
      def unsupported_param_keys(params : Hash(String, String), spec : Hash(String, Array(String)), sub_spec_keys : Hash(String, Array(String)) = {} of String => Array(String)) : Array(String)
        unsupported = params.keys.reject do |key|
          spec.has_key?(key) || spec.values.any?(&.includes?(key)) ||
            sub_spec_keys.has_key?(key) || INTERNAL.includes?(key) ||
            key.starts_with?("_ansible_")
        end
        sub_spec_keys.each do |param, suboptions|
          raw = params[param]?
          next unless raw
          parse_sub_list(raw).each do |element|
            next unless element.as_h?
            element.as_h.each_key do |key|
              unsupported << "#{param}.#{key}" unless suboptions.includes?(key)
            end
          end
        end
        unsupported
      end

      # check_type_list semantics (ansible-core 2.14: a plain string is
      # comma-split, no JSON probing). The wire JSON round-trip is
      # undone first, since every krikri param arrives as a string.
      def parse_sub_list(raw : String) : Array(JSON::Any)
        case value = (JSON.parse(raw) rescue nil).try(&.raw)
        when Array
          value
        when String
          value.split(",").map { |entry| JSON::Any.new(entry) }
        when Nil
          raw.split(",").map { |entry| JSON::Any.new(entry) }
        else
          [JSON::Any.new(value)]
        end
      end

      private INTERNAL = {"_ansible_check_mode", "_ansible_diff", "_module_name", "_verbosity", "_environment"}

      # community.crypto's _time.py get_relative_time_option: a timespec
      # is either sshd_config(5)-relative (a leading +/-, then
      # weeks/days/hours/minutes/seconds components in that exact order)
      # or one of four absolute ASN.1/generalized-time shapes. Anything
      # else fails the module with 'The time spec "..." for ... is
      # invalid'.
      RELATIVE_TIME_RE = /^[+-](\d+[wW])?(\d+[dD])?(\d+[hH])?(\d+[mM])?(\d+[sS]?)?$/

      def crypto_time_spec_valid?(value : String) : Bool
        if value.starts_with?('+') || value.starts_with?('-')
          return value.size > 1 && value.matches?(RELATIVE_TIME_RE)
        end

        case value.size
        when 15
          parse_utc(value, "%Y%m%d%H%M%SZ")
        when 13
          parse_utc(value, "%Y%m%d%H%MZ")
        when 19
          parse_utc(value, "%Y%m%d%H%M%S%z")
        when 17
          parse_utc(value, "%Y%m%d%H%M%z")
        else
          false
        end
      rescue
        false
      end

      private def parse_utc(value : String, format : String) : Bool
        Time.parse_utc(value, format)
        true
      rescue Time::Format::Error
        false
      end
    end
  end
end
