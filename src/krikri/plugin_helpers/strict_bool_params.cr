require "json"
require "../param_sentinels"

module Krikri
  # Raised by StrictBoolValidation#validate_bool_params! when a documented
  # `type: bool` param carries a value Ansible's check_type_bool
  # would reject. BasePlugin#run_and_capture surfaces the message verbatim
  # as the module failure, exactly like AnsibleModule's argspec
  # validation failing before any module logic runs.
  class BoolParamError < Exception; end

  module PluginHelpers
    # Strict `type: bool` param validation - a matches
    # ansible-core's check_type_bool
    # + boolean() + the
    # parameters.py failure wrapper, shared by BasePlugin (module-side
    # argspec validation) and the controller-side action plugins that
    # real validates the same way (assert).
    #
    # AnsibleModule validates every PROVIDED param's type at module
    # setup, before any module logic: a `type: bool` option whose value
    # is not a bool, one of the boolean literals (case-insensitive,
    # whitespace-stripped), or the numbers 0/1 fails the module before
    # anything runs, e.g. "argument 'remote_src' is of type str and we
    # were unable to convert to bool: The value '/some/path' is not a
    # valid boolean. Valid booleans include: ...". Previously the lenient
    # BasePlugin#true? treated any non-empty string as truthy, so a
    # typo'd or mis-templated bool param silently flipped behavior
    # (force:/remove:/backup: class flags) where Ansible never gets
    # past argument validation.
    #
    # A plugin opts in by overriding #bool_params with its module's
    # documented `type: bool` options (ansible-doc -j <module>, in real
    # argument-spec declaration order) and calling #validate_bool_params!
    # where Ansible's module-setup validation would sit in its own arg-check
    # ordering (top of #execute for plain modules; after the
    # unsupported-params/mutually-exclusive gates for the plugins that
    # hand-roll those first, matching arg_spec.py's check order).
    module StrictBoolValidation
      # The module's documented `type: bool` options. Empty by default: a
      # plugin that never opts in gets no validation, exactly like today.
      protected def bool_params : Array(String)
        [] of String
      end

      # alias -> canonical for bool options Ansible's argspec declares aliases
      # for. A playbook using the alias spelling still fails with the
      # CANONICAL name in the message, because real resolves aliases to the
      # canonical key before argspec validation runs (so the alias key no
      # longer exists in the params dict by then).
      protected def bool_param_aliases : Hash(String, String)
        {} of String => String
      end

      # Bool options whose real default is None rather than True/False.
      # parameters.py skips type conversion entirely when the value is None
      # AND the option is not required AND its default is None - so
      # `service: {enabled: null}` passes module setup (the module then
      # sees None) while `copy: {force: null}` fails with the NoneType
      # message (force's default is True). Both live-verified against
      # ansible-core 2.19.11.
      protected def bool_params_none_default : Array(String)
        [] of String
      end

      # convert_bool.py's BOOLEANS string members (the int/bool members
      # ride along as their string spellings on krikri's strings-only
      # param wire). boolean() lowercases and strips first.
      private BOOL_PARAM_TRUE  = %w[y yes on 1 true t]
      private BOOL_PARAM_FALSE = %w[n no off 0 false f]

      # The "Valid booleans include:" tail. Real serializes a Python SET
      # here, so the order differs between module processes
      # (PYTHONHASHSEED) - Ansible does not reproduce its own order
      # between two runs. This fixed order is the check_type_bool
      # docstring's own listing; only the wording shape is deterministic.
      private BOOLEANS_PARAM_REPR = %w['1' 'on'] + ["1"] + %w['0'] + ["0"] +
                                    %w['n' 'f' 'false' 'true' 'y' 't' 'yes' 'no' 'off']

      # The check_type_bool/boolean() TypeError detail for one value - nil
      # when the value converts fine. Exposed separately from the full
      # message so plugins whose real counterpart validates bools OUTSIDE
      # the module argspec (set_fact - controller-side in 2.19, no
      # "argument 'x' is of type ..." wrapper) can compose their own
      # wrapper around the same detail.
      protected def bool_violation_detail(raw : JSON::Any) : String?
        case value = raw.raw
        when Bool
          nil
        when Nil
          "<class 'NoneType'> cannot be converted to a bool"
        when String
          string_bool_violation(value)
        when Int
          numeric_bool_violation(value == 0 || value == 1, value.to_s)
        when Float
          numeric_bool_violation(value == 0.0 || value == 1.0, value.to_s)
        when Array
          "<class 'list'> cannot be converted to a bool"
        when Hash
          "<class 'dict'> cannot be converted to a bool"
        else
          "<class 'NoneType'> cannot be converted to a bool"
        end
      end

      private def numeric_bool_violation(valid : Bool, text : String) : String?
        return nil if valid
        "The value '#{text}' is not a valid boolean. " \
        "Valid booleans include: #{BOOLEANS_PARAM_REPR.join(", ")}"
      end

      private def string_bool_violation(value : String) : String?
        if value == NONE_SENTINEL
          return "<class 'NoneType'> cannot be converted to a bool"
        end
        normalized = value.downcase.strip
        return nil if BOOL_PARAM_TRUE.includes?(normalized) || BOOL_PARAM_FALSE.includes?(normalized)
        "The value '#{value}' is not a valid boolean. " \
        "Valid booleans include: #{BOOLEANS_PARAM_REPR.join(", ")}"
      end

      # set_fact's controller-side path routes an explicit None through
      # boolean() itself (not check_type_bool's type dispatch), which
      # stringifies it as Python's None repr inside the standard
      # not-a-valid-boolean message rather than the argspec path's
      # NoneType message (live-verified against ansible-core 2.19.11).
      protected def bool_none_violation_detail : String
        "The value 'None' is not a valid boolean. " \
        "Valid booleans include: #{BOOLEANS_PARAM_REPR.join(", ")}"
      end

      # native_type_name(value) + the check_type_bool detail - the full
      # parameters.py failure message for one bool param, or nil when
      # valid. Always reported under the CANONICAL option name: real
      # resolves aliases before argspec validation, so the alias key no
      # longer exists in its params dict by then.
      protected def bool_param_error_msg(canonical : String, raw : JSON::Any) : String?
        if raw.raw.nil? || raw.as_s? == NONE_SENTINEL
          # An explicit None only fails when the option's real default is
          # not None itself (see #bool_params_none_default).
          return nil if bool_params_none_default.includes?(canonical)
          return "argument '#{canonical}' is of type NoneType and we were unable to convert to bool: " \
                 "<class 'NoneType'> cannot be converted to a bool"
        end
        detail = bool_violation_detail(raw) || return nil
        type_name = case raw.raw
                    when Bool   then "bool"
                    when String then "str"
                    when Int    then "int"
                    when Float  then "float"
                    when Array  then "list"
                    else             "dict"
                    end
        "argument '#{canonical}' is of type #{type_name} and we were unable to convert to bool: #{detail}"
      end

      # Validates every PROVIDED bool param (omitted params are never
      # validated - Ansible only sees provided keys plus defaults) in real
      # argument-spec declaration order, raising BoolParamError on the
      # FIRST violation - Ansible only surfaces errors[0] from the
      # AnsibleValidationErrorMultiple. Reads the RAW param wire
      # (@config["params"]) so native JSON types survive: a YAML `force:
      # 2` that arrives as a real JSON number reports "of type int" the
      # way Ansible's native_type_name does, not the stringified @params
      # view.
      protected def validate_bool_params_in!(raw_params : Hash(String, JSON::Any)) : Nil
        aliases = bool_param_aliases
        bool_params.each do |canonical|
          key = raw_params.has_key?(canonical) ? canonical : aliases.find do |alias_name, canon|
            canon == canonical && raw_params.has_key?(alias_name)
          end.try(&.[0])
          next unless key
          # A parser-marked non-string YAML literal (NON_STRING_PARAM_PREFIX)
          # rides the raw wire as a prefixed STRING - decode it back to its
          # native value so the bool check sees the bool/int/float Ansible's
          # check_type_bool would have seen (a literal `flat: false` is a
          # real bool, not the string "nonstring:false").
          raw = raw_params[key]
          if (text = raw.as_s?) && (native = Krikri.non_string_scalar(text))
            raw = native
          end
          if msg = bool_param_error_msg(canonical, raw)
            raise BoolParamError.new(msg)
          end
        end
      end
    end
  end
end
