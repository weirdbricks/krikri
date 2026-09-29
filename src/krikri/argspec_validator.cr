require "json"
require "digest/sha1"
require "big"
require "./param_sentinels"

# Data-driven module argument validation, matching real ansible-core's
# AnsibleModule argument-spec checks word-for-word.
#
# The spec table (data/argspecs.json) is GENERATED from the installed
# ansible-core + collections by scripts/gen_argspecs.py: it captures each
# module's own AnsibleModule(argument_spec=...) call (options, aliases,
# types, required, choices, defaults, mutually_exclusive/required_together/
# required_one_of/required_if/required_by) plus live-probed facts the spec
# itself cannot tell you (which module name real prints in
# "Unsupported parameters for (...) module" when an action plugin delegates
# - template runs copy, shell runs command - and which action-only
# directives validate at all).
#
# Check order mirrors ansible-core's ArgumentSpecValidator.validate() +
# AnsibleModule.__init__ error selection: only the FIRST error in that
# order is ever surfaced (errors[0]):
#   mutually_exclusive -> required -> types -> choices -> required_together
#   -> required_one_of -> required_if -> required_by -> unsupported params
# (unsupported-params is collected during the walk but appended to the
# error list LAST, so a missing-required error beats a typo'd parameter -
# live-verified: docker_container with a typo and no name reports
# "missing required arguments: name", not the typo).
module Krikri
  module ArgspecValidator
    extend self

    # Kept out of validation: engine-internal wire keys real's module
    # never sees (real strips the _ansible_* namespace generically; the
    # others are krikri's own bookkeeping keys).
    # Package-manager modules `package: use:` can name (core + common community).
    PACKAGE_MANAGERS = %w[apt apt_rpm dnf dnf5 yum yum4 dnf4 zypper pacman apk homebrew pkgng openbsd_pkg
      pkgin portage xbps slackpkg swupd urpmi opkg pkg5 rpm_ostree_pkg macports bsd_pkg]

    INTERNAL_KEYS = [
      "_module_name", "_first_gather", "_environment", "_verbosity",
      "_rendered_from_template", "_content_checksum",
      "__original_src_basename",
    ]

    # convert_bool.py's BOOLEANS as real's error message reprs them (a
    # Python set iteration - order differs between module processes, so
    # this fixed order is one real emits; only the membership is stable).
    BOOLEANS_REPR = %w['off' 1 'true' 'y' 0 'false' 'on' 'no' '1' 'yes' '0' 'n' 'f' 't']
    REAL_TRUE     = %w[y yes on 1 true t]
    REAL_FALSE    = %w[n no off 0 false f]

    # The param wire is strings-only; an explicit YAML null rides as
    # NONE_SENTINEL and {{ omit }} removes the key entirely upstream.

    class Failure
      getter msg : String
      # Action-only directives (debug, assert, fail, ...) fail with a
      # chain that has no "Module failed." middle segment.
      getter? action_level : Bool
      # debug's fatal dump carries ONLY msg (real's callback shape for
      # its own action result) - its failure result omits "changed".
      getter? omit_changed : Bool

      def initialize(@msg, @action_level = false, @omit_changed = false)
      end
    end

    @@table : Hash(String, JSON::Any)? = nil

    private def table : Hash(String, JSON::Any)
      @@table ||= JSON.parse({{ read_file("#{__DIR__}/../../data/argspecs.json") }}).as_h
    end

    # Whether this msg on this module is an argspec-validation failure we
    # emitted (used by ResultDisplay to pick the right error-block chain
    # shape - template's own file-not-found chain must not swallow these).
    def failure_kind?(module_name : String, msg : String) : Symbol?
      return :action if action_level_fixed_msg?(module_name, msg)
      entry = table[module_name]?
      return nil unless entry
      return nil if entry["no_validate"]?
      return nil unless validation_msg?(msg)
      entry["action_level"]?.try(&.as_bool?) ? :action : :module
    end

    # The action-plugin-level failures whose text is not a spec-check
    # message (real's action plugins check these before the module's own
    # AnsibleModule init runs), keyed by module; every one of these
    # modules has a table entry, so checking them before the entry
    # lookup changes nothing.
    private def action_level_fixed_msg?(module_name : String, msg : String) : Bool
      case module_name
      when "ansible.builtin.template", "ansible.builtin.assemble"
        msg == "src and dest are required"
      when "ansible.builtin.package"
        msg.starts_with?("Could not find a matching action for the")
      when "ansible.builtin.unarchive"
        {"parameters are mutually exclusive: ('copy', 'remote_src')", "src (or content) and dest are required"}.includes?(msg)
      else
        false
      end
    end

    private def validation_msg?(msg : String) : Bool
      msg.starts_with?("Unsupported parameters for (") ||
        msg.starts_with?("missing required arguments:") ||
        msg.starts_with?("Invalid options for ") ||
        msg.starts_with?("value of ") || msg.starts_with?("argument '") ||
        msg.starts_with?("parameters are ") ||
        msg.starts_with?("one of the following is required:") ||
        msg.starts_with?("missing parameter(s) required by ")
    end

    # Validates one module invocation's params against the real spec.
    # action_name is the module spelling AS WRITTEN in the task (real
    # prints that in the Unsupported-parameters message, except for the
    # delegating action plugins with a fixed name); module_name is the
    # resolved FQCN the table is keyed by. Returns nil when nothing fails
    # (or the module has no spec to check against).
    def validate(
      action_name : String,
      module_name : String,
      params : Hash(String, String),
      vars_context : Hash(String, JSON::Any),
    ) : Failure?
      entry = table[module_name]?
      return nil unless entry
      return nil if entry["no_validate"]?

      # copy's action plugin (copy.py:428-430) likewise checks first, with its
      # own two messages (a failed result, "Action failed." chain) - and its
      # checks are PYTHON TRUTHINESS checks, not key-presence checks: a
      # non-string YAML literal that is falsy (false, 0, 0.0 - the parser
      # marks those, see NON_STRING_PARAM_PREFIX) or an empty string counts
      # as "not provided" exactly like a missing key (live-verified vs
      # 2.19.11: `dest: false`/`dest: 0`/`dest: ""` all fail
      # "dest is required", `src: 0` with no content fails
      # "src (or content) is required", while `src: 0` WITH content runs
      # the content path - the falsy src is simply ignored).
      if module_name == "ansible.builtin.copy"
        unless params.has_key?("content") || Krikri.python_param_truthy?(params["src"]?)
          return Failure.new("src (or content) is required", true)
        end
        return Failure.new("dest is required", true) unless params.has_key?("dest") && Krikri.python_param_truthy?(params["dest"]?)
      end

      # assemble's action plugin (assemble.py:103-104) checks src/dest
      # presence BEFORE the remote_src/isdir staging and before the module
      # validates anything - a typo'd/missing src or dest fails with the
      # action-level "src and dest are required", not the module spec's
      # "missing required arguments" (live-verified vs 2.19.11). Real's
      # check is a None check: an explicitly null param counts as absent,
      # an empty string does not.
      if module_name == "ansible.builtin.assemble" &&
         (!provided_param?(params, "src") || !provided_param?(params, "dest"))
        return Failure.new("src and dest are required", true)
      end

      # Custom callable spec types (assert's str_or_list_of_str) reject a
      # natively-typed scalar where the demoted wire text would pass -
      # capture the markers (alias-resolved to the canonical option name)
      # BEFORE the strip below hides them.
      alias_lookup = alias_map(entry["options"]?.try(&.as_h?) || Hash(String, JSON::Any).new)
      non_string_natives = {} of String => JSON::Any
      params.each do |key, value|
        next if INTERNAL_KEYS.includes?(key)
        if native = Krikri.non_string_scalar(value)
          non_string_natives[alias_lookup[key]? || key] = native
        end
      end

      # The parser's non-string-literal markers (NON_STRING_PARAM_PREFIX)
      # are executor-internal wire dressing: demote them back to the plain
      # string form every spec check has always seen, so a marked
      # `follow: true` validates like the "true" text it always was.
      params = Krikri.strip_non_string_param_markers(params)

      # assemble with remote_src: false: the controller-side action plugin's
      # isdir() check fails BEFORE any module argument validation runs.
      if module_name == "ansible.builtin.assemble" &&
         {"false", "no", "n", "0", "off", "f"}.includes?(params["remote_src"]?.to_s.downcase) &&
         (src = params["src"]?) && !Dir.exists?(src)
        return nil
      end

      # template's controller-side action plugin checks src/dest presence
      # BEFORE any module argument validation (AnsibleActionFail). The
      # check only ever sees the ORIGINAL task params: once the action has
      # run, src has been consumed into the rendered content (the copy
      # module gets a real src tempfile), so a post-action run must fall
      # through to the spec checks - that is where real surfaces the copy
      # module's rejection of the template-only leftovers the action did
      # not consume (a typo'd output_encoding etc.).
      if module_name == "ansible.builtin.template" && !params.has_key?("content") &&
         (!params.has_key?("src") || !params.has_key?("dest"))
        return Failure.new("src and dest are required", true)
      end
      # package's action plugin: an unknown `use:` manager fails before the
      # delegated module ever validates anything.
      if module_name == "ansible.builtin.package" && (use = params["use"]?) && use != "auto" && !PACKAGE_MANAGERS.includes?(use)
        return Failure.new(%(Could not find a matching action for the "#{use}" package manager.), true)
      end
      # unarchive's action plugin, in order: copy+remote_src conflict, src/dest
      # required, then (below) dest must be an existing dir - all before the
      # module validates anything.
      if module_name == "ansible.builtin.unarchive"
        return Failure.new("parameters are mutually exclusive: ('copy', 'remote_src')", true) if params.has_key?("copy") && params.has_key?("remote_src")
        return Failure.new("src (or content) and dest are required", true) unless params.has_key?("src") && params.has_key?("dest")
      end
      # unarchive's action plugin checks that dest is an existing directory
      # (AnsibleActionFail) before the module ever validates its arguments;
      # a dest that is not a directory here defers to the plugin's own failure.
      if module_name == "ansible.builtin.unarchive" && (dest = params["dest"]?) && !Dir.exists?(dest)
        return nil
      end

      print_name, entry = resolve_entry(action_name, module_name, entry, vars_context)
      return nil unless entry

      if supported = entry["supported"]?.try(&.as_a?)
        return virtual_supported_failure(action_name, print_name, entry, params, supported)
      end
      if entry["unsupported_kind"]?.try(&.as_s?) == "invalid_options"
        valid = entry["valid"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
        return virtual_invalid_options_failure(print_name, params, valid)
      end

      options = entry["options"]?.try(&.as_h?) || Hash(String, JSON::Any).new
      provided, unsupported = collect_provided(params, options, consumed_keys(entry))

      defaults = default_values(options)
      failure_msg = run_spec_checks(entry, options, provided, defaults, unsupported, non_string_natives)
      return Failure.new(failure_msg, entry["action_level"]?.try(&.as_bool?) || false) if failure_msg

      if unsupported.empty?
        nil
      else
        Failure.new(unsupported_params_message(print_name, unsupported, options),
          entry["action_level"]?.try(&.as_bool?) || false)
      end
    end

    # `invocation.module_args` of a module result: every spec option under
    # its canonical name, the provided (type-converted) value or its default
    # (null when none). nil for a module without a spec or an action-plugin
    # module whose result carries no invocation.
    def invocation_args(module_name : String, params : Hash(String, String)) : Hash(String, JSON::Any)?
      entry = table[module_name]?
      return nil unless entry
      return nil if entry["no_validate"]? || entry["supported"]? || entry["unsupported_kind"]?
      params = Krikri.strip_non_string_param_markers(params)
      options = entry["options"]?.try(&.as_h?) || return nil
      return nil if options.empty?
      provided, _unsupported = collect_provided(params, options, consumed_keys(entry))
      result = Hash(String, JSON::Any).new
      options.each do |name, spec|
        if (raw = provided[name]?) && raw == Krikri::NONE_SENTINEL
          result[name] = JSON::Any.new(nil)
        elsif raw = provided[name]?
          result[name] = convert_invocation_value(raw, spec["type"]?.try(&.as_s?) || "str")
        else
          result[name] = spec["default"]? || JSON::Any.new(nil)
        end
      end
      result
    end

    private def convert_invocation_value(raw : String, type : String) : JSON::Any
      case type
      when "bool"
        down = raw.downcase
        return JSON::Any.new(true) if REAL_TRUE.includes?(down)
        return JSON::Any.new(false) if REAL_FALSE.includes?(down)
        JSON::Any.new(raw)
      when "int"
        raw.to_i64?.try { |v| JSON::Any.new(v) } || JSON::Any.new(raw)
      when "float"
        raw.to_f64?.try { |v| JSON::Any.new(v) } || JSON::Any.new(raw)
      when "list"
        parsed = (JSON.parse(raw) rescue nil)
        if parsed && parsed.as_a?
          parsed
        else
          JSON::Any.new(raw.split(",").map { |part| JSON::Any.new(part.strip) })
        end
      when "dict"
        (JSON.parse(raw) rescue JSON::Any.new(raw))
      when "path"
        JSON::Any.new(raw.starts_with?("~") ? File.expand_path(raw) : raw)
      else
        JSON::Any.new(raw)
      end
    end

    # Wire params, alias-normalized: canonical name -> raw wire string.
    # Real's _handle_aliases runs before every check, so an alias
    # spelling counts exactly like its canonical name; anything that
    # maps to neither lands in the unsupported list (reported LAST).
    private def collect_provided(
      params : Hash(String, String),
      options : Hash(String, JSON::Any),
      consumed : Array(String),
    ) : {Hash(String, String), Array(String)}
      provided = Hash(String, String).new
      unsupported = [] of String
      aliases = alias_map(options)
      params.each do |key, value|
        next if key.starts_with?("_ansible_") || INTERNAL_KEYS.includes?(key)
        next if consumed.includes?(key)
        canonical = aliases[key]? || (options.has_key?(key) ? key : nil)
        if canonical
          provided[canonical] = value
        else
          unsupported << key
        end
      end
      {provided, unsupported}
    end

    private def consumed_keys(entry : JSON::Any) : Array(String)
      entry["consumed_by_action"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
    end

    # Real's action-plugin presence checks are None checks
    # (self._task.args.get('src', None)): the key must exist AND hold a
    # non-None value - an explicitly null param counts as absent, an
    # empty string does not.
    private def provided_param?(params : Hash(String, String), key : String) : Bool
      value = params[key]?
      !value.nil? && value != Krikri::NONE_SENTINEL
    end

    # The spec-check chain in real Ansible's ArgumentSpecValidator order;
    # only the FIRST failing check's message is ever surfaced (real's
    # AnsibleModule fails on errors[0]).
    private def run_spec_checks(
      entry : JSON::Any,
      options : Hash(String, JSON::Any),
      provided : Hash(String, String),
      defaults : Hash(String, JSON::Any),
      unsupported : Array(String),
      non_string_natives : Hash(String, JSON::Any),
    ) : String?
      # Real's ArgumentSpecValidator.validate runs its no_log value walk
      # (_list_no_log_values) immediately after alias resolution - before
      # mutually_exclusive, required, or any type conversion. A string
      # element of a dict-typed option THAT HAS suboptions (or a dict
      # option itself) which cannot be parsed as a dict raises
      # check_type_dict's bare TypeError there, and its text becomes
      # errors[0] verbatim - the "Elements value for option ..." wrapping
      # only happens later, for options WITHOUT suboptions (which the
      # walk never descends into). Specs regenerated with nested
      # "options"/"elements" keys make this check data-driven.
      if msg = check_no_log_walk(options, provided)
        return msg
      end
      if msg = check_mutually_exclusive(entry, provided)
        return msg
      end
      if msg = check_required(options, provided, defaults)
        return msg
      end
      if msg = check_types(options, provided, non_string_natives)
        return msg
      end
      if msg = check_choices(options, provided)
        return msg
      end
      if msg = check_required_together(entry, provided, defaults)
        return msg
      end
      if msg = check_required_one_of(entry, provided, defaults)
        return msg
      end
      if msg = check_required_if(entry, provided, defaults)
        return msg
      end
      if msg = check_required_by(entry, provided, defaults)
        return msg
      end
      nil
    end

    # Resolves fact-delegated specs (service -> systemd, package -> apt)
    # and computes the module name real would print for this invocation.
    # Returns {print_name, effective_entry} - effective_entry nil means
    # the spec target cannot be determined (no host fact), so validation
    # is skipped rather than guessed.
    private def resolve_entry(action_name : String, module_name : String, entry : JSON::Any, vars_context : Hash(String, JSON::Any)) : {String, JSON::Any?}
      if fact_delegate = entry["fact_delegate"]?
        fact = fact_delegate["fact"].as_s
        fact_value = vars_context[fact]?.try(&.as_s?) || ""
        # Facts not gathered: real's action plugin runs setup for just the
        # delegating fact on demand. service: systemd only when PID 1 is
        # systemd, any other manager runs the service module ITSELF against
        # its own spec. package: the host's package manager (apt on Debian).
        if fact_value.empty?
          case fact
          when "ansible_service_mgr"
            fact_value = File.read("/proc/1/comm").strip == "systemd" ? "systemd" : "service" rescue "service"
          when "ansible_pkg_mgr"
            fact_value = File.exists?("/usr/bin/apt-get") ? "apt" : ""
          end
        end
        target = fact_delegate["map"].as_h[fact_value]?.try(&.as_s)
        if target && (target_entry = table[target]?)
          return {"ansible.legacy.#{target.split(".").last}", target_entry}
        end
        return {action_name, nil} unless fact == "ansible_service_mgr"

        return {"ansible.legacy.#{module_name.split(".").last}", entry}
      end

      print_name = action_name
      if print_spec = entry["print"]?
        if fixed = print_spec["fixed"]?.try(&.as_s?)
          print_name = fixed
        elsif override = print_spec.as_h[action_name]?
          print_name = override.as_s
        end
      end
      {print_name, entry}
    end

    private def alias_map(options : Hash(String, JSON::Any)) : Hash(String, String)
      map = Hash(String, String).new
      options.each do |name, spec|
        if aliases = spec["aliases"]?.try(&.as_a?)
          aliases.each do |a|
            map[a.as_s] = name
          end
        end
      end
      map
    end

    private def default_values(options : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      defaults = Hash(String, JSON::Any).new
      options.each do |name, spec|
        if d = spec["default"]?
          defaults[name] = d
        end
      end
      defaults
    end

    # Real's check_mutually_exclusive runs BEFORE defaults are applied:
    # only actually-provided params count (aliases resolve to their
    # canonical name for the count).
    private def check_mutually_exclusive(entry : JSON::Any, provided : Hash(String, String)) : String?
      groups = entry["mutually_exclusive"]?.try(&.as_a?) || return nil
      failing = [] of String
      groups.each do |group|
        names = group.as_a.map(&.as_s)
        count = names.count { |name| provided.has_key?(name) }
        failing << names.join("|") if count > 1
      end
      failing.empty? ? nil : "parameters are mutually exclusive: #{failing.join(", ")}"
    end

    # Real applies non-null defaults before the required check, so a
    # defaulted option is never missing; required+null-default stays
    # missing (the None default does not stand in for a provided value).
    private def check_required(options : Hash(String, JSON::Any), provided : Hash(String, String), defaults : Hash(String, JSON::Any)) : String?
      missing = [] of String
      options.each do |name, spec|
        next unless spec["required"]?.try(&.as_bool?)
        next if provided.has_key?(name)
        next if defaults[name]? && !defaults[name].raw.nil?
        missing << name
      end
      missing.empty? ? nil : "missing required arguments: #{missing.sort.join(", ")}"
    end

    private def check_types(options : Hash(String, JSON::Any), provided : Hash(String, String), non_string_natives : Hash(String, JSON::Any)) : String?
      options.each do |name, spec|
        raw = provided[name]?
        next unless raw
        wanted = spec["type"]?.try(&.as_s?) || "str"
        error = type_error(name, wanted, raw, spec, non_string_natives[name]?)
        return error if error
      end
      nil
    end

    # Real's custom callable type (assert action's str_or_list_of_str): a
    # string passes, a list whose every element is a string passes, and
    # anything else raises TypeError("a string or list of strings is
    # required"), which _validate_argument_types wraps as "argument 'x' is
    # of type <native type> and we were unable to convert to
    # str_or_list_of_str: ...". The wire sees a marked non-string scalar
    # (int/float/bool) where real sees the native Python value; a plain
    # string wire value IS real's str case, and a JSON-encoded list is
    # real's list case.
    private def str_or_list_type_error(name : String, raw : String, native : JSON::Any?) : String?
      tail = "a string or list of strings is required"
      if list = (JSON.parse(raw) rescue nil).try(&.as_a?)
        return nil if list.all?(&.as_s?)
        return "argument '#{name}' is of type list and we were unable to convert to str_or_list_of_str: #{tail}"
      end
      kind = case native.try(&.raw)
             when Int64, Int32 then "int"
             when Float64      then "float"
             when Bool         then "bool"
             else                   "str"
             end
      return nil if kind == "str"
      "argument '#{name}' is of type #{kind} and we were unable to convert to str_or_list_of_str: #{tail}"
    end

    # Real's _list_no_log_values walk: for every provided option that is
    # type=dict, or type=list with elements=dict AND its own options=
    # sub-spec, each element must be a dict - a string element goes
    # through check_type_dict (bare TypeError on failure, surfaced
    # verbatim as the module failure msg) and a parsed dict descends one
    # level into the sub-spec recursively. Elements that are neither
    # strings nor dicts fail with real's own (format-arg-swapped)
    # "Value 'x' in the sub parameter field 'y' must be a ..." wording.
    private def check_no_log_walk(options : Hash(String, JSON::Any), provided : Hash(String, String)) : String?
      options.each do |name, spec|
        sub_spec = spec["options"]?.try(&.as_h?) || next
        wanted = spec["type"]?.try(&.as_s?) || "str"
        next unless wanted == "dict" ||
                    (wanted == "list" && spec["elements"]?.try(&.as_s?) == "dict")
        raw = provided[name]?
        next unless raw
        next if raw == Krikri::NONE_SENTINEL
        json = JSON.parse(raw) rescue nil
        error = no_log_walk_elements(sub_spec, json || JSON::Any.new(raw), name, wanted)
        return error if error
      end
      nil
    end

    # One option's (container-or-string) wire value against its
    # sub-spec. Real sees the decoded param: a list is iterated, anything
    # else is treated as a one-element list.
    private def no_log_walk_elements(sub_spec : Hash(String, JSON::Any), value : JSON::Any,
                                     arg_name : String, wanted_type : String) : String?
      elements = value.as_a? || [value]
      elements.each do |element|
        case raw = element.raw
        when String
          if error = check_type_dict_error(raw)
            return error
          end
          parsed = parsed_dict_value(raw)
          if parsed && (failure = no_log_walk_params(sub_spec, parsed))
            return failure
          end
        when Hash(String, JSON::Any)
          if failure = no_log_walk_params(sub_spec, element)
            return failure
          end
        else
          return "Value '#{python_value_repr(element)}' in the sub parameter field '#{arg_name}' " \
                 "must be a #{wanted_type}, not '#{python_class_name(element)}'"
        end
      end
      nil
    end

    # Recursion one level down: the parsed dict's values against the
    # sub-spec's own dict-shaped options (real's
    # _list_no_log_values(sub_argument_spec, sub_param)).
    private def no_log_walk_params(spec : Hash(String, JSON::Any), params : JSON::Any) : String?
      return nil unless params_h = params.as_h?
      spec.each do |name, sub|
        sub_sub = sub["options"]?.try(&.as_h?) || next
        wanted = sub["type"]?.try(&.as_s?) || "str"
        next unless wanted == "dict" ||
                    (wanted == "list" && sub["elements"]?.try(&.as_s?) == "dict")
        value = params_h[name]? || next
        next if value.raw.nil?
        error = no_log_walk_elements(sub_sub, value, name, wanted)
        return error if error
      end
      nil
    end

    # check_type_dict's conversion semantics on a string: a "{"-leading
    # string must be a JSON object (real also tries literal_eval - krikri
    # approximates the same way its top-level dict conversion already
    # does), a string containing "=" must be fully key=value shaped, and
    # anything else raises the bare "dictionary requested, could not
    # parse JSON or key=value" TypeError. Returns the error text, or nil
    # when the string parses.
    private def check_type_dict_error(raw : String) : String?
      if raw.strip.starts_with?("{")
        json = JSON.parse(raw) rescue nil
        return nil if json && json.as_h?
        return "unable to evaluate string as dictionary"
      end
      return kv_parse_error(raw) if raw.includes?("=")
      "dictionary requested, could not parse JSON or key=value"
    end

    # Real's key=value field splitter (quote- and escape-aware, fields
    # separated on commas/spaces): every field must carry an "=" or the
    # whole string fails with the "key=value format" wording.
    private def kv_parse_error(raw : String) : String?
      fields = kv_fields(raw)
      fields.each do |field|
        return "unable to evaluate string in the \"key=value\" format as dictionary" unless field.includes?("=")
      end
      nil
    end

    private def kv_fields(raw : String) : Array(String)
      fields = [] of String
      field_buffer = ""
      in_quote = nil
      in_escape = false
      raw.strip.each_char do |char|
        if in_escape
          field_buffer += char
          in_escape = false
        elsif char == '\\'
          in_escape = true
        elsif in_quote.nil? && (char == '\'' || char == '"')
          in_quote = char
        elsif in_quote == char
          in_quote = nil
        elsif in_quote.nil? && (char == ',' || char == ' ')
          fields << field_buffer unless field_buffer.empty?
          field_buffer = ""
        else
          field_buffer += char
        end
      end
      fields << field_buffer unless field_buffer.empty?
      fields
    end

    # The parsed dict behind a string that check_type_dict accepted, for
    # the recursive sub-spec walk (nil when only the k=v shape was
    # validated without building a dict - the recursion then simply
    # finds no sub-values).
    private def parsed_dict_value(raw : String) : JSON::Any?
      if raw.strip.starts_with?("{")
        json = JSON.parse(raw) rescue nil
        return json if json && json.as_h?
        return nil
      end
      fields = kv_fields(raw)
      return nil unless fields.all?(&.includes?("="))
      object = Hash(String, JSON::Any).new
      fields.each do |field|
        key, value = field.split("=", 2)
        object[key] = JSON::Any.new(value)
      end
      JSON::Any.new(object)
    end

    # Python repr/str of a non-string, non-dict element value, for the
    # "Value '...' in the sub parameter field ..." wording (real embeds
    # str(value) there).
    private def python_value_repr(value : JSON::Any) : String
      case raw = value.raw
      when Nil              then "None"
      when Bool             then raw ? "True" : "False"
      when Int64            then raw.to_s
      when Float64          then raw.to_s
      when Array(JSON::Any) then "[#{raw.map { |item| python_value_repr(item) }.join(", ")}]"
      else                       raw.to_s
      end
    end

    private def python_class_name(value : JSON::Any) : String
      case value.raw
      when Nil              then "NoneType"
      when Bool             then "bool"
      when Int64            then "int"
      when Float64          then "float"
      when Array(JSON::Any) then "list"
      else                       "str"
      end
    end

    # One wire value -> real's typed view. The wire is strings-only, so
    # the JSON container shapes a whole-span native param carries are
    # decoded here (real sees the actual list/dict; krikri sees its JSON
    # text). A YAML boolean rides as exactly "true"/"false" - real sees
    # a Python bool, which is an int subclass and passes int/float/list
    # checks but fails dict conversion.
    private def type_error(name : String, wanted : String, raw : String, spec : JSON::Any, native : JSON::Any? = nil) : String?
      is_null = raw == Krikri::NONE_SENTINEL
      # Real skips type conversion entirely for a None that is neither
      # required nor defaulted ("if value is None and not required and
      # default is None: continue").
      if is_null
        return none_type_error(name, wanted, spec)
      end

      if wanted == "str_or_list_of_str"
        return str_or_list_type_error(name, raw, native)
      end

      json = (JSON.parse(raw) rescue nil)
      kind = value_kind(raw, json) # :str | :bool | :list | :dict

      if wanted == "bool"
        bool_type_error(name, raw, kind)
      elsif wanted == "int"
        int_type_error(name, raw, kind)
      elsif wanted == "float"
        float_type_error(name, raw, kind)
      elsif wanted == "dict"
        dict_type_error(name, raw, kind)
      elsif wanted == "list"
        list_type_error(name, kind)
      elsif wanted == "jsonarg"
        jsonarg_type_error(name, kind)
      elsif wanted == "bytes" || wanted == "bits"
        size_type_error(name, wanted, raw, kind)
      else
        # str/path/raw/any: a wire string always converts.
        nil
      end
    end

    private def none_type_error(name : String, wanted : String, spec : JSON::Any) : String?
      required = spec["required"]?.try(&.as_bool?) || false
      has_default = spec["default"]? != nil
      return nil if !required && !has_default
      # Real's checker for None: str converts to "" (no error); bool/
      # float/dict/list/jsonarg raise "<class 'NoneType'> cannot be
      # converted to ..."; int goes through Decimal and reprs the
      # value ('"None" cannot be converted to an int').
      return nil if wanted == "str" || wanted == "path" || wanted == "raw" || wanted == "any"
      tail = case wanted
             when "int"     then "\"None\" cannot be converted to an int"
             when "jsonarg" then "<class 'NoneType'> cannot be converted to a json string"
             else                "<class 'NoneType'> cannot be converted to #{a_word(wanted)}"
             end
      "argument '#{name}' is of type NoneType and we were unable to convert to #{wanted}: #{tail}"
    end

    private def bool_type_error(name : String, raw : String, kind : Symbol) : String?
      if kind == :str
        normalized = raw.downcase.strip
        return nil if REAL_TRUE.includes?(normalized) || REAL_FALSE.includes?(normalized)
        return "argument '#{name}' is of type str and we were unable to convert to bool: " \
               "The value '#{raw}' is not a valid boolean. Valid booleans include: #{BOOLEANS_REPR.join(", ")}"
      end
      if kind == :list || kind == :dict
        return "argument '#{name}' is of type #{kind} and we were unable to convert to bool: " \
               "<class '#{kind}'> cannot be converted to a bool"
      end
      # :bool - already a boolean, nothing to convert.
      nil
    end

    private def int_type_error(name : String, raw : String, kind : Symbol) : String?
      case kind
      when :bool
        nil # bool IS an int in Python
      when :str
        return nil if int_like?(raw)
        "argument '#{name}' is of type str and we were unable to convert to int: " \
        "\"'#{raw}'\" cannot be converted to an int"
      else
        "argument '#{name}' is of type #{kind} and we were unable to convert to int: " \
        "\"#{python_repr(kind, raw)}\" cannot be converted to an int"
      end
    end

    private def float_type_error(name : String, raw : String, kind : Symbol) : String?
      case kind
      when :bool
        nil
      when :str
        return nil if float_like?(raw)
        "argument '#{name}' is of type str and we were unable to convert to float: " \
        "<class 'str'> cannot be converted to a float"
      else
        "argument '#{name}' is of type #{kind} and we were unable to convert to float: " \
        "<class '#{kind}'> cannot be converted to a float"
      end
    end

    private def dict_type_error(name : String, raw : String, kind : Symbol) : String?
      case kind
      when :dict
        nil
      when :str
        # check_type_dict: JSON object, then literal_eval, then the
        # k1=v1,k2=v2 fallback - each failure has its own wording.
        if raw.strip.starts_with?("{")
          "argument '#{name}' is of type str and we were unable to convert to dict: " \
          "unable to evaluate string as dictionary"
        elsif raw.includes?("=")
          nil
        else
          "argument '#{name}' is of type str and we were unable to convert to dict: " \
          "dictionary requested, could not parse JSON or key=value"
        end
      else
        "argument '#{name}' is of type #{kind} and we were unable to convert to dict: " \
        "<class '#{kind}'> cannot be converted to a dict"
      end
    end

    private def list_type_error(name : String, kind : Symbol) : String?
      return nil unless kind == :dict
      "argument '#{name}' is of type dict and we were unable to convert to list: " \
      "<class 'dict'> cannot be converted to a list"
    end

    private def jsonarg_type_error(name : String, kind : Symbol) : String?
      return nil unless kind == :bool
      "argument '#{name}' is of type bool and we were unable to convert to jsonarg: " \
      "<class 'bool'> cannot be converted to a json string"
    end

    private def size_type_error(name : String, wanted : String, raw : String, kind : Symbol) : String?
      return nil unless kind == :str
      return nil if human_size_like?(raw)
      word = wanted == "bytes" ? "Byte value" : "Bit value"
      "argument '#{name}' is of type str and we were unable to convert to #{wanted}: " \
      "<class 'str'> cannot be converted to a #{word}"
    end

    private def value_kind(raw : String, json : JSON::Any?) : Symbol
      return :bool if raw == "true" || raw == "false"
      return :list if json && json.as_a?
      return :dict if json && json.as_h?
      :str
    end

    # Python repr of a list/dict wire value, for the int-conversion
    # error message (real embeds repr(value) there). Rough but only
    # reachable for container values on numeric options.
    private def python_repr(kind : Symbol, raw : String) : String
      return raw unless kind == :list || kind == :dict
      json = JSON.parse(raw) rescue return raw
      String.build do |io|
        io << (kind == :list ? "[" : "{")
        first = true
        if kind == :list
          json.as_a.each do |item|
            io << ", " unless first
            first = false
            io << item.to_s
          end
        else
          json.as_h.each do |k, v|
            io << ", " unless first
            first = false
            io << k << ": " << v.to_s
          end
        end
        io << (kind == :list ? "]" : "}")
      end
    end

    private def python_word(wanted : String) : String
      case wanted
      when "jsonarg" then "a json string"
      when "str"     then "str"
      else                "a #{wanted}"
      end
    end

    private def a_word(wanted : String) : String
      case wanted
      when "int", "bool", "float", "dict", "list", "str" then "a #{wanted}"
      when "jsonarg"                                     then "a json string"
      else                                                    "a #{wanted}"
      end
    end

    # decimal.Decimal-compatible integer shape: the value must equal its
    # own integer truncation ("1.0" passes, "1.5" and "abc" fail).
    private def int_like?(raw : String) : Bool
      s = raw.strip
      begin
        bd = BigDecimal.new(s)
        (bd - BigDecimal.new(bd.to_i)) == BigDecimal.new(0)
      rescue
        false
      end
    end

    private def float_like?(raw : String) : Bool
      s = raw.strip
      return false if s.empty?
      begin
        s.to_f64
        true
      rescue
        false
      end
    end

    # human_to_bytes accepts a bare integer or a <number><unit> size
    # (K/M/G/T/P/E, optional i and B); anything else fails conversion.
    private def human_size_like?(raw : String) : Bool
      s = raw.strip
      return true if s.matches?(/\A[0-9]+\z/)
      s.matches?(/\A[0-9]+(\.[0-9]+)?\s*[KMGTPE](i)?B?\z/i)
    end

    private def check_choices(options : Hash(String, JSON::Any), provided : Hash(String, String)) : String?
      options.each do |name, spec|
        raw = provided[name]?
        next unless raw
        choices = spec["choices"]?.try(&.as_a?) || next
        json = (JSON.parse(raw) rescue nil)
        if json && json.as_a?
          missing = json.as_a.map(&.to_s).reject { |item| choices_strings(choices).includes?(item) }
          unless missing.empty?
            return "value of #{name} must be one or more of: #{choices_strings(choices).join(", ")}. " \
                   "Got no match for: #{missing.join(", ")}"
          end
        else
          value = raw == Krikri::NONE_SENTINEL ? "None" : raw
          unless choices_strings(choices).includes?(value)
            return "value of #{name} must be one of: #{choices_strings(choices).join(", ")}, got: #{value}"
          end
        end
      end
      nil
    end

    private def choices_strings(choices : Array(JSON::Any)) : Array(String)
      choices.map do |choice|
        case raw = choice.raw
        when Bool   then raw ? "True" : "False"
        when Nil    then "None"
        when String then raw
        else             choice.to_s
        end
      end
    end

    # Presence for the group checks: provided, or a non-null spec default
    # (real's first _set_defaults pass runs before these checks).
    private def present?(name : String, provided : Hash(String, String), defaults : Hash(String, JSON::Any)) : Bool
      return true if provided.has_key?(name)
      if d = defaults[name]?
        return !d.raw.nil?
      end
      false
    end

    private def check_required_together(entry : JSON::Any, provided : Hash(String, String), defaults : Hash(String, JSON::Any)) : String?
      groups = entry["required_together"]?.try(&.as_a?) || return nil
      failing = [] of Array(String)
      groups.each do |group|
        names = group.as_a.map(&.as_s)
        present_count = names.count { |name| present?(name, provided, defaults) }
        failing << names if present_count > 0 && present_count < names.size
      end
      failing.empty? ? nil : "parameters are required together: #{failing.map(&.join(", ")).join(", ")}"
    end

    private def check_required_one_of(entry : JSON::Any, provided : Hash(String, String), defaults : Hash(String, JSON::Any)) : String?
      groups = entry["required_one_of"]?.try(&.as_a?) || return nil
      groups.each do |group|
        names = group.as_a.map(&.as_s)
        unless names.any? { |name| present?(name, provided, defaults) }
          return "one of the following is required: #{names.join(", ")}"
        end
      end
      nil
    end

    private def check_required_if(entry : JSON::Any, provided : Hash(String, String), defaults : Hash(String, JSON::Any)) : String?
      requirements = entry["required_if"]?.try(&.as_a?) || return nil
      requirements.each do |req|
        parts = req.as_a
        key = parts[0].as_s
        val = parts[1]
        reqs = parts[2].as_a.map(&.as_s)
        is_one_of = parts.size > 3 && parts[3].as_bool

        # The triggering value: provided wire value, else the spec
        # default (real compares parameters[key] == val after defaults).
        current = provided[key]?
        current = default_value_string(defaults[key]) if current.nil? && defaults[key]?
        next unless current
        next unless value_matches?(current, val)

        missing = reqs.reject { |needed| present?(needed, provided, defaults) }
        max_missing = is_one_of ? reqs.size : 0
        if missing.size >= max_missing && !missing.empty?
          requires = is_one_of ? "any" : "all"
          return "#{key} is #{python_literal(val)} but #{requires} of the following are missing: #{missing.join(", ")}"
        end
      end
      nil
    end

    private def value_matches?(current : String, val : JSON::Any) : Bool
      case raw = val.raw
      when Bool   then current == (raw ? "true" : "false")
      when String then current == raw
      when Int    then current == raw.to_s
      when Float  then current == raw.to_s
      else             false
      end
    end

    # Python "%s"-style rendering of a required_if trigger value
    # (booleans print True/False, strings print bare).
    private def python_literal(val : JSON::Any) : String
      case raw = val.raw
      when Bool   then raw ? "True" : "False"
      when Nil    then "None"
      when String then raw
      else             val.to_s
      end
    end

    private def default_value_string(value : JSON::Any) : String
      case raw = value.raw
      when Bool   then raw ? "true" : "false"
      when Nil    then Krikri::NONE_SENTINEL
      when String then raw
      else             value.to_s
      end
    end

    private def check_required_by(entry : JSON::Any, provided : Hash(String, String), defaults : Hash(String, JSON::Any)) : String?
      requirements = entry["required_by"]?.try(&.as_h?) || return nil
      requirements.each do |key, value|
        next unless present?(key, provided, defaults)
        needed = value.as_a?.try(&.map(&.as_s)) || [value.as_s]
        missing = needed.reject { |req| present?(req, provided, defaults) }
        unless missing.empty?
          return "missing parameter(s) required by '#{key}': #{missing.join(", ")}"
        end
      end
      nil
    end

    # Real's UnsupportedError wording: the offending names sorted, then
    # the spec's own option names sorted with ONE trailing parenthetical
    # holding all the spec's aliases sorted together.
    private def unsupported_params_message(print_name : String, unsupported : Array(String), options : Hash(String, JSON::Any)) : String
      names = options.keys.sort!
      aliases = [] of String
      options.each_value do |spec|
        if list = spec["aliases"]?.try(&.as_a?)
          list.each { |a| aliases << a.as_s }
        end
      end
      aliases.sort!
      supported = aliases.empty? ? names.join(", ") : "#{names.join(", ")} (#{aliases.join(", ")})"
      "Unsupported parameters for (#{print_name}) module: #{unsupported.sort.join(", ")}. " \
      "Supported parameters include: #{supported}."
    end

    # Action-only directives with a fixed supported set (debug/pause/
    # script): same message shape, but the list is the hand-probed one.
    private def virtual_supported_failure(
      action_name : String,
      print_name : String,
      entry : JSON::Any,
      params : Hash(String, String),
      supported : Array(JSON::Any),
    ) : Failure?
      unsupported = params.keys.reject do |key|
        key.starts_with?("_ansible_") || INTERNAL_KEYS.includes?(key) ||
          supported.map(&.as_s).includes?(key)
      end.sort!
      return nil if unsupported.empty?
      Failure.new(
        "Unsupported parameters for (#{print_name}) module: #{unsupported.join(", ")}. " \
        "Supported parameters include: #{supported.map(&.as_s).join(", ")}.",
        action_level: entry["action_level"]?.try(&.as_bool?) || false,
        omit_changed: entry["result_keys"]?.try(&.as_a?) == ["msg"],
      )
    end

    # fail/group_by/wait_for_connection: the action plugin's own
    # "Invalid options for <action>: <names>" check (comma, no space,
    # real's ','.join of the offending set).
    private def virtual_invalid_options_failure(print_name : String, params : Hash(String, String), valid : Array(String)) : Failure?
      unsupported = params.keys.reject do |key|
        key.starts_with?("_ansible_") || INTERNAL_KEYS.includes?(key) || valid.includes?(key)
      end.sort!
      return nil if unsupported.empty?
      Failure.new("Invalid options for #{print_name}: #{unsupported.join(",")}", action_level: true)
    end
  end
end
