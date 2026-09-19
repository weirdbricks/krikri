require "json"
require "../base_plugin"
require "./ansible_arg_validation"

module Krikri
  module PluginHelpers
    # AwsModuleArgs - the argument-validation surface shared by the
    # amazon.aws modules krikri reimplements natively (ec2_key,
    # ec2_ami_info, ec2_instance, ec2_security_group, ec2_vpc_net_info,
    # ec2_vpc_subnet_info, iam_user_info).
    #
    # Real amazon.aws modules wrap AnsibleModule in AnsibleAWSModule
    # (module_utils/modules.py): the AnsibleModule argument-spec
    # validation runs FIRST, then the boto3 check fails any invocation
    # whose args were VALID with "Failed to import the required Python
    # library (botocore and boto3) ...". Every wording below is
    # therefore reachable without any AWS connectivity, and the boto3
    # gate is the last thing that fires before the module's own logic -
    # which for krikri is the native EC2/IAM Query-API helpers (no
    # boto3 anywhere).
    #
    # The gate probes the host's python3 the same way the real module's
    # import check would: if boto3+botocore import cleanly the module
    # (and krikri) proceed to the API work; if not, both fail with the
    # same missing-library message shape (hostname and interpreter path
    # included, exactly like missing_required_lib builds it).
    #
    # Validation order mirrors ansible-core 2.14's
    # ArgumentSpecValidator.validate() (arg_spec.py) + basic.py failing
    # on errors[0] (live-verified against amazon.aws 11.4.0 under
    # ansible-core 2.14 via the podman-diff probe container):
    #   1. _list_no_log_values: for a dict / elements-dict param WITH an
    #      options= sub-spec, a scalar string (or list elements) value is
    #      converted through check_type_dict directly, so the bare
    #      TypeError wording ("dictionary requested, could not parse JSON
    #      or key=value") is errors[0] - the "argument 'x' is of type ..."
    #      wrapper from _validate_argument_types never fires (e.g.
    #      ec2_instance's image). Dict params WITHOUT options (tags,
    #      filters, aws_config) skip this and keep the prefix.
    #   2. mutually_exclusive
    #   3. missing required arguments
    #   4. type conversion failures (merged spec declaration order)
    #   5. choices failures (merged spec declaration order)
    #   6. required_one_of / required_if
    #   7. sub-spec (options=) checks per param
    #   8. unsupported parameters (top level, then suboption keys)
    #   9. the boto3 gate
    module AwsModuleArgs
      # A single argument in the merged argument spec. type is the real
      # spec's type= value ("str" for untyped entries - real Ansible
      # defaults untyped params to str).
      record Arg,
        type : String = "str",
        aliases : Array(String) = [] of String,
        choices : Array(String)? = nil,
        required : Bool = false

      record SubArg,
        type : String = "str",
        choices : Array(String)? = nil,
        required : Bool = false

      record SubSpec,
        args : Hash(String, SubArg),
        mutually_exclusive : Array(Array(String)) = [] of Array(String),
        required_one_of : Array(Array(String)) = [] of Array(String),
        required_by : Hash(String, Array(String)) = {} of String => Array(String),
        required_if : Array(Tuple(String, String, Array(String))) = [] of Tuple(String, String, Array(String))

      record Spec,
        module_name : String,
        args : Hash(String, Arg),
        mutually_exclusive : Array(Array(String)) = [] of Array(String),
        required_one_of : Array(Array(String)) = [] of Array(String),
        required_if : Array(Tuple(String, String, Array(String))) = [] of Tuple(String, String, Array(String)),
        sub : Hash(String, SubSpec) = {} of String => SubSpec

      # module_utils/modules.py _aws_common_argument_spec() + region, in
      # declaration order; every module's merged spec is this plus its
      # own params.
      BASE_ARGS = {
        "access_key"                   => Arg.new(aliases: ["aws_access_key_id", "aws_access_key"]),
        "secret_key"                   => Arg.new(aliases: ["aws_secret_access_key", "aws_secret_key"]),
        "session_token"                => Arg.new(aliases: ["aws_session_token"]),
        "profile"                      => Arg.new(aliases: ["aws_profile"]),
        "endpoint_url"                 => Arg.new(aliases: ["aws_endpoint_url"]),
        "validate_certs"               => Arg.new(type: "bool"),
        "aws_ca_bundle"                => Arg.new(type: "path"),
        "aws_config"                   => Arg.new(type: "dict"),
        "debug_botocore_endpoint_logs" => Arg.new(type: "bool"),
        "region"                       => Arg.new(aliases: ["aws_region"]),
      }

      def self.base_args : Hash(String, Arg)
        BASE_ARGS.dup
      end

      # -- entry points -------------------------------------------------

      # Returns the failed PluginResult for the FIRST argument-spec
      # violation (real fails on errors[0]), or nil when validation
      # passes and the module would move on to the boto3 check.
      def self.validate(spec : Spec, params : Hash(String, String)) : Krikri::PluginResult?
        given = resolve_given(spec.args, params)

        check_no_log_values(spec, given) ||
          check_mutually_exclusive(spec.mutually_exclusive, given) ||
          check_required_arguments(spec.args, given) ||
          check_types(spec.args, given) ||
          check_choices(spec.args, given) ||
          check_required_one_of(spec.required_one_of, given) ||
          check_required_if(spec.required_if, given) ||
          check_sub_specs(spec, given) ||
          check_unsupported(spec, params)
      end

      # The AnsibleAWSModule boto3-check step: with valid args, the
      # module's next act is importing boto3/botocore, and a host
      # without them fails here. krikri probes the host's python3 the
      # same way; a host that HAS the libs gets the native API helpers.
      def self.boto3_gate(params : Hash(String, String)) : Krikri::PluginResult?
        python = python_interpreter
        return nil unless python

        probe = Process.run(python, {"-c", "import botocore, boto3"}, error: Process::Redirect::Close)
        return nil if probe.success?

        PluginResult.new(
          changed: false,
          failed: true,
          msg: "Failed to import the required Python library (botocore and boto3) on #{System.hostname}'s Python #{python}. " \
               "Please read the module documentation and install it in the appropriate location. " \
               "If the required library is installed, but Ansible is using the wrong Python interpreter, " \
               "please consult the documentation on ansible_python_interpreter",
        )
      end

      private def self.python_interpreter : String?
        ["python3", "python"].each do |name|
          io = IO::Memory.new
          status = Process.run(name, {"-c", "import sys; print(sys.executable)"}, output: io, error: Process::Redirect::Close)
          path = io.to_s.strip
          return path if status.success? && !path.empty?
        end
        nil
      end

      # -- spec-level checks ------------------------------------------------

      # Resolves aliases to canonical names: real AnsibleModule replaces
      # an alias's value with the canonical key before validation.
      private def self.resolve_given(args : Hash(String, Arg), params : Hash(String, String)) : Hash(String, String)
        given = Hash(String, String).new
        params.each do |key, raw|
          next if internal_key?(key)
          canonical = args.find { |name, arg| name == key || arg.aliases.includes?(key) }
          if canonical
            name, _arg = canonical
            given[name] = raw unless given.has_key?(name)
          end
        end
        given
      end

      private def self.check_mutually_exclusive(groups : Array(Array(String)), given : Hash(String, String)) : Krikri::PluginResult?
        groups.each do |group|
          next unless group.count { |name| given.has_key?(name) } > 1
          return PluginResult.new(changed: false, failed: true,
            msg: "parameters are mutually exclusive: #{group.join("|")}")
        end
        nil
      end

      private def self.check_required_arguments(args : Hash(String, Arg), given : Hash(String, String)) : Krikri::PluginResult?
        missing = args.select { |name, arg| arg.required && !given.has_key?(name) }.keys
        return nil if missing.empty?
        PluginResult.new(changed: false, failed: true,
          msg: "missing required arguments: #{missing.sort.join(", ")}")
      end

      private def self.check_types(args : Hash(String, Arg), given : Hash(String, String)) : Krikri::PluginResult?
        args.each do |name, arg|
          raw = given[name]?
          next unless raw
          if result = type_error(name, arg.type, raw)
            return result
          end
        end
        nil
      end

      private def self.check_choices(args : Hash(String, Arg), given : Hash(String, String)) : Krikri::PluginResult?
        args.each do |name, arg|
          choices = arg.choices
          next unless choices
          raw = given[name]?
          next unless raw
          value = scalar_text(raw)
          next if choices.includes?(value)
          return PluginResult.new(changed: false, failed: true,
            msg: "value of #{name} must be one of: #{choices.join(", ")}, got: #{value}")
        end
        nil
      end

      private def self.check_required_one_of(groups : Array(Array(String)), given : Hash(String, String)) : Krikri::PluginResult?
        groups.each do |group|
          next if group.any? { |name| given.has_key?(name) }
          return PluginResult.new(changed: false, failed: true,
            msg: "one of the following is required: #{group.join(", ")}")
        end
        nil
      end

      private def self.check_required_if(groups : Array(Tuple(String, String, Array(String))), given : Hash(String, String)) : Krikri::PluginResult?
        groups.each do |param, value, required|
          next unless given[param]? == value
          missing = required.reject { |name| given.has_key?(name) }
          next if missing.empty?
          return PluginResult.new(changed: false, failed: true,
            msg: "#{param} is #{value} but all of the following are missing: #{missing.join(", ")}")
        end
        nil
      end

      private def self.check_unsupported(spec : Spec, params : Hash(String, String)) : Krikri::PluginResult?
        legal = spec.args.flat_map { |name, arg| arg.aliases + [name] }.to_set
        unsupported = params.keys.reject { |key| legal.includes?(key) || internal_key?(key) }.sort!
        return nil if unsupported.empty?

        names = spec.args.keys.sort!
        aliases = spec.args.values.flat_map(&.aliases).sort
        supported = aliases.empty? ? names.join(", ") : "#{names.join(", ")} (#{aliases.join(", ")})"
        PluginResult.new(changed: false, failed: true,
          msg: "Unsupported parameters for (#{spec.module_name}) module: #{unsupported.join(", ")}. " \
               "Supported parameters include: #{supported}.")
      end

      private def self.internal_key?(key : String) : Bool
        key.starts_with?("_ansible_") ||
          {"_ansible_check_mode", "_ansible_diff", "_module_name", "_verbosity", "_environment"}.includes?(key)
      end

      # -- _list_no_log_values step ------------------------------------------

      # Real runs _list_no_log_values before every other fatal check,
      # and for a dict / elements-dict param that HAS an options=
      # sub-spec it runs the value's string elements through
      # check_type_dict directly: a string that fails both JSON and k=v
      # parsing surfaces check_type_dict's bare TypeError as errors[0],
      # and a non-string non-dict element surfaces the Mapping-check
      # wording (with real's "must by a" typo preserved). Params without
      # options are untouched here - they keep the prefixed wording
      # check_types builds later.
      private def self.check_no_log_values(spec : Spec, given : Hash(String, String)) : Krikri::PluginResult?
        spec.sub.each do |param, sub|
          raw = given[param]?
          next unless raw

          value = parse_json_value(raw)
          case raw_value = value.raw
          when String
            next if kv_dict?(raw_value)
            return dict_parse_error(param, !sub.args.empty?)
          when Array
            raw_value.each do |element|
              case element.raw
              when String
                next if kv_dict?(element.as_s)
                return dict_parse_error(param, !sub.args.empty?)
              when Hash
                next
              else
                return PluginResult.new(changed: false, failed: true,
                  msg: "Value '#{sub_scalar_text(element)}' in the sub parameter field '#{param}' " \
                       "must by a dict, not '#{python_class(element)}'")
              end
            end
          end
        end
        nil
      end

      # -- sub-spec (options=) checks ---------------------------------------

      # Mirrors real _validate_sub_spec: per param (spec order), per
      # element; a scalar string where a dict is required fails the
      # whole param first.
      private def self.check_sub_specs(spec : Spec, given : Hash(String, String)) : Krikri::PluginResult?
        spec.sub.each do |param, sub|
          raw = given[param]?
          next unless raw

          parent_arg = spec.args[param]?
          next unless parent_arg

          parsed = dict_value(raw)
          unless parsed
            return dict_parse_error(param, !sub.args.empty?)
          end

          if parent_arg.type == "list"
            parsed.each do |element|
              if result = sub_element_error(spec, param, sub, element, !sub.args.empty?)
                return result
              end
            end
          else
            if result = sub_element_error(spec, param, sub, parsed[0], !sub.args.empty?)
              return result
            end
          end
        end
        nil
      end

      # A dict-typed value: an object passes through; a string only if
      # real's k=v fallback parses it; anything else (list, bool, int)
      # fails dict conversion. Returns the ELEMENT list (for elements=
      # dict parents, one entry per element; for dict parents, the one
      # dict).
      private def self.dict_value(raw : String) : Array(JSON::Any)?
        value = parse_json_value(raw)
        case raw_value = value.raw
        when Hash
          [value]
        when Array
          elements = [] of JSON::Any
          raw_value.each do |element|
            if element.as_h?
              elements << element
            elsif text = element.as_s?
              return nil unless kv_dict?(text)
              elements << JSON.parse(kv_to_json(text))
            else
              return nil
            end
          end
          elements
        when String
          return nil unless kv_dict?(raw_value)
          [JSON.parse(kv_to_json(raw_value))]
        end
      end

      # elements=dict entries WITH an options= spec (network_interfaces)
      # surface the bare dict-parse failure via the _list_no_log_values
      # step above; the ones without (volumes:) only fail in
      # _validate_elements and get real's "Elements value for option"
      # wording.
      private def self.dict_parse_error(param : String, has_options : Bool) : Krikri::PluginResult
        if has_options
          PluginResult.new(changed: false, failed: true,
            msg: "dictionary requested, could not parse JSON or key=value")
        else
          PluginResult.new(changed: false, failed: true,
            msg: "Elements value for option '#{param}' is of type <class 'str'> and we were unable to convert to dict: " \
                 "dictionary requested, could not parse JSON or key=value")
        end
      end

      private def self.sub_element_error(spec : Spec, param : String, sub : SubSpec, element : JSON::Any, has_options : Bool) : Krikri::PluginResult?
        unless element.as_h?
          return dict_parse_error(param, has_options)
        end

        options = element.as_h
        given_sub = resolve_sub_given(sub.args, options)

        sub_missing_required(param, sub, given_sub) ||
          sub_types(param, sub, given_sub) ||
          sub_choices(param, sub, given_sub) ||
          sub_mutually_exclusive(param, sub, given_sub) ||
          sub_required_one_of(param, sub, given_sub) ||
          sub_required_by(param, sub, given_sub) ||
          sub_unsupported(spec, param, sub, options)
      end

      private def self.resolve_sub_given(args : Hash(String, SubArg), options : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        given = Hash(String, JSON::Any).new
        args.each do |name, _arg|
          given[name] = options[name] if options.has_key?(name)
        end
        given
      end

      private def self.sub_missing_required(param : String, sub : SubSpec, given : Hash(String, JSON::Any)) : Krikri::PluginResult?
        missing = sub.args.select { |name, arg| arg.required && !given.has_key?(name) }.keys
        return nil if missing.empty?
        PluginResult.new(changed: false, failed: true,
          msg: "missing required arguments: #{missing.sort.join(", ")} found in #{param}")
      end

      private def self.sub_types(param : String, sub : SubSpec, given : Hash(String, JSON::Any)) : Krikri::PluginResult?
        sub.args.each do |name, arg|
          raw = given[name]?
          next unless raw
          result = sub_type_error(param, name, arg.type, raw)
          return result if result
        end
        nil
      end

      private def self.sub_choices(param : String, sub : SubSpec, given : Hash(String, JSON::Any)) : Krikri::PluginResult?
        sub.args.each do |name, arg|
          choices = arg.choices
          next unless choices
          raw = given[name]?
          next unless raw
          value = sub_scalar_text(raw)
          next if choices.includes?(value)
          return PluginResult.new(changed: false, failed: true,
            msg: "value of #{name} must be one of: #{choices.join(", ")}, got: #{value} found in #{param}")
        end
        nil
      end

      private def self.sub_mutually_exclusive(param : String, sub : SubSpec, given : Hash(String, JSON::Any)) : Krikri::PluginResult?
        sub.mutually_exclusive.each do |group|
          next unless group.count { |name| given.has_key?(name) } > 1
          return PluginResult.new(changed: false, failed: true,
            msg: "parameters are mutually exclusive: #{group.join("|")} found in #{param}")
        end
        nil
      end

      private def self.sub_required_one_of(param : String, sub : SubSpec, given : Hash(String, JSON::Any)) : Krikri::PluginResult?
        sub.required_one_of.each do |group|
          next if group.any? { |name| given.has_key?(name) }
          return PluginResult.new(changed: false, failed: true,
            msg: "one of the following is required: #{group.join(", ")} found in #{param}")
        end
        nil
      end

      private def self.sub_required_by(param : String, sub : SubSpec, given : Hash(String, JSON::Any)) : Krikri::PluginResult?
        sub.required_by.each do |name, required|
          next unless given.has_key?(name)
          missing = required.reject { |required_key| given.has_key?(required_key) }
          next if missing.empty?
          return PluginResult.new(changed: false, failed: true,
            msg: "missing parameter(s) required by '#{name}': #{missing.join(", ")} found in #{param}")
        end
        nil
      end

      private def self.sub_unsupported(spec : Spec, param : String, sub : SubSpec, options : Hash(String, JSON::Any)) : Krikri::PluginResult?
        legal = sub.args.keys.to_set
        unsupported = options.keys.reject { |key| legal.includes?(key) }.sort
        return nil if unsupported.empty?

        unsupported = unsupported.map { |key| "#{param}.#{key}" }
        supported = sub.args.keys.sort.join(", ")
        PluginResult.new(changed: false, failed: true,
          msg: "Unsupported parameters for (#{spec.module_name}) module: #{unsupported.join(", ")}. " \
               "Supported parameters include: #{supported}.")
      end

      # -- value-shaping helpers ---------------------------------------------

      private def self.parse_json_value(raw : String) : JSON::Any
        JSON.parse(raw)
      rescue
        JSON::Any.new(raw)
      end

      # The Python type name real's conversion errors quote: what the
      # YAML value arrived as.
      private def self.python_class(value : JSON::Any) : String
        case value.raw
        when Bool    then "bool"
        when Int64   then "int"
        when Float64 then "float"
        when Array   then "list"
        when Hash    then "dict"
        else              "str"
        end
      end

      # Scalar rendering used in "got: X" and required_if messages -
      # real renders Python literals (False, True) for non-strings.
      private def self.sub_scalar_text(value : JSON::Any) : String
        case value.raw
        when Bool    then value.raw ? "True" : "False"
        when String  then value.as_s
        when Int64   then value.to_s
        when Float64 then value.to_s
        else              value.to_s
        end
      end

      private def self.scalar_text(raw : String) : String
        sub_scalar_text(parse_json_value(raw))
      end

      # -- per-type conversion errors (AnsibleModule check_type_* wordings) ----

      def self.type_error(name : String, type : String, raw : String) : Krikri::PluginResult?
        value = parse_json_value(raw)
        pyclass = python_class(value)

        case type
        when "bool"
          return nil if value.raw.is_a?(Bool) || pyclass == "int" || pyclass == "float"
          return nil if pyclass == "str" && bool_convertible?(value.as_s)
          bool_type_error(name, value)
        when "int"
          case value.raw
          when Int64, Float64, Bool then nil
          when String
            return nil if value.as_s.strip.matches?(/\A[+-]?\d+\z/)
            int_type_error(name, pyclass)
          else
            int_type_error(name, pyclass)
          end
        when "dict"
          return nil if value.raw.is_a?(Hash)
          return nil if pyclass == "str" && kv_dict?(value.as_s)
          PluginResult.new(changed: false, failed: true,
            msg: "argument '#{name}' is of type #{class_repr(pyclass)} and we were unable to convert to dict: " \
                 "dictionary requested, could not parse JSON or key=value")
        when "list"
          case value.raw
          when Array then nil
          when Hash
            PluginResult.new(changed: false, failed: true,
              msg: "argument '#{name}' is of type <class 'dict'> and we were unable to convert to list: " \
                   "<class 'dict'> cannot be converted to a list")
          end
        end
      end

      private def self.sub_type_error(param : String, name : String, type : String, value : JSON::Any) : Krikri::PluginResult?
        pyclass = python_class(value)

        case type
        when "bool"
          return nil if value.raw.is_a?(Bool) || pyclass == "int" || pyclass == "float"
          return nil if pyclass == "str" && bool_convertible?(value.as_s)
          sub_bool_type_error(param, name, value)
        when "int"
          case value.raw
          when Int64, Float64, Bool then nil
          when String
            return nil if value.as_s.strip.matches?(/\A[+-]?\d+\z/)
            sub_int_type_error(param, name, pyclass)
          else
            sub_int_type_error(param, name, pyclass)
          end
        end
      end

      private def self.bool_convertible?(text : String) : Bool
        normalized = text.downcase.strip
        %w[y yes on 1 true t n no off 0 false f].includes?(normalized)
      end

      private def self.class_repr(pyclass : String) : String
        "<class '#{pyclass}'>"
      end

      def self.bool_type_error(name : String, value : JSON::Any) : Krikri::PluginResult
        PluginResult.new(changed: false, failed: true,
          msg: "argument '#{name}' is of type #{class_repr(python_class(value))} and we were unable to convert to bool: " \
               "The value '#{sub_scalar_text(value)}' is not a valid boolean.  " \
               "Valid booleans include: #{AnsibleArgValidation::BOOLEANS_REPR.join(", ")}")
      end

      def self.int_type_error(name : String, pyclass : String) : Krikri::PluginResult
        PluginResult.new(changed: false, failed: true,
          msg: "argument '#{name}' is of type #{class_repr(pyclass)} and we were unable to convert to int: " \
               "#{class_repr(pyclass)} cannot be converted to an int")
      end

      private def self.sub_bool_type_error(param : String, name : String, value : JSON::Any) : Krikri::PluginResult
        PluginResult.new(changed: false, failed: true,
          msg: "argument '#{name}' is of type #{class_repr(python_class(value))} found in '#{param}'. and we were unable to convert to bool: " \
               "The value '#{sub_scalar_text(value)}' is not a valid boolean.  " \
               "Valid booleans include: #{AnsibleArgValidation::BOOLEANS_REPR.join(", ")}")
      end

      private def self.sub_int_type_error(param : String, name : String, pyclass : String) : Krikri::PluginResult
        PluginResult.new(changed: false, failed: true,
          msg: "argument '#{name}' is of type #{class_repr(pyclass)} found in '#{param}'. and we were unable to convert to int: " \
               "#{class_repr(pyclass)} cannot be converted to an int")
      end

      # Real check_type_dict's k=v fallback: "a=b" or "a=b,c=d" parse as
      # dicts; anything without '=' cannot.
      private def self.kv_dict?(text : String) : Bool
        return false if text.strip.empty?
        text.split(',').all? do |pair|
          pair.includes?('=')
        end
      end

      private def self.kv_to_json(text : String) : String
        hash = Hash(String, String).new
        text.split(',').each do |pair|
          key, _, value = pair.partition('=')
          hash[key.strip] = value
        end
        hash.to_json
      end
    end
  end
end
