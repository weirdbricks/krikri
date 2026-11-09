require "big"
require "../arg_specs"
require "../../krikri/python_literal"

module Krikri
  module Lint
    # Upstream parity: ansible-lint's args[module] rule (reported as a
    # warning by upstream). Validates a task's module parameters against
    # the module's own AnsibleModule argument spec (arg_specs.cr) the
    # way ansible-core's ArgumentSpecValidator does, and reports the one
    # failure AnsibleModule itself would fail with (its errors[0] - the
    # only one upstream's mocked module run ever surfaces). Reported at
    # the task line with no column.
    class ArgsModuleRule < Rule
      # convert_bool.py's BOOLEANS as Ansible's error message reprs them
      # (a Python set iteration - the order differs between module
      # processes, so this fixed order is one Ansible emits; only the
      # membership is stable).
      VALID_BOOLEANS = %w[0 1 'no' 'on' 'yes' '1' 'false' 'n' '0' 'y' 'f' 't' 'off' 'true']

      # PyYAML's YAML 1.1 plain-scalar resolution: a plain scalar is a
      # bool/int/float/null only for these exact spellings, so `y`, `n`
      # and `tRue` stay strings and `0755` is the octal int 493.
      NULL_WORDS    = {"", "~", "null", "Null", "NULL"}
      BOOL_WORDS    = {"yes", "Yes", "YES", "no", "No", "NO", "true", "True", "TRUE", "false", "False", "FALSE", "on", "On", "ON", "off", "Off", "OFF"}
      INT_PATTERN   = /\A(?:[-+]?0b[0-1_]+|[-+]?0o?[0-7_]+|[-+]?(?:0|[1-9][0-9_]*)|[-+]?0x[0-9a-fA-F_]+|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+)\z/
      FLOAT_PATTERN = /\A(?:[-+]?(?:[0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?|\.[0-9_]+(?:[eE][-+][0-9]+)?|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))\z/

      # ansiblelint.text.RE_HAS_JINJA: any {{...}}, {%...%} or {#...#}
      # span (its closing class is loose, and a span may cross lines).
      JINJA_PATTERN = /\{[{%#].*[%#}]/m

      # The regexes ansible-lint's args rule extracts the offending
      # option name with (args.py _parse_failed_msg): the name is looked
      # up in the task's action dict, which drives both its jinja-value
      # drop and its KeyError crash emulation.
      TYPE_ERROR_PATTERN    = /(?:argument|option) '(.*)' is of type/
      CHOICES_ERROR_PATTERN = /value of (.*) must be one of:/

      # pathlib.Path.is_file() (what ansible-core's module bootstrap
      # stats the args string with) ignores these errnos and raises on
      # anything else - ENAMETOOLONG above all, on filesystems with a
      # file-name limit below the args JSON's length.
      IGNORED_STAT_ERRNOS = {Errno::ENOENT, Errno::ENOTDIR, Errno::EBADF, Errno::ELOOP}

      def id : String
        "args[module]"
      end

      def severity : Severity
        Severity::VERY_LOW
      end

      def tags : Array(String)
        ["core"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      # Task-oriented: violations belong to an enclosing task, so a
      # `# noqa:` anywhere in that task's body suppresses them.
      def task_scoped? : Bool
        true
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        collected = [] of Violation
        TaskWalker.each_task(file) do |task|
          result = task_message(task)
          # upstream's matchtasks aborts on any rule exception and
          # loses every args match for the whole file ("Ignored
          # exception from ArgsRule.matchtasks while processing ..."), so
          # one crashing task silences its earlier and later matches too.
          return if result[:crash]
          if message = result[:message]
            collected << Violation.new(file.path, task.line, 0, id, severity, message, task.line)
          end
        end
        collected.each { |violation| violations << violation }
      end

      # The one upstream match for this task, or nothing when upstream
      # reports nothing; crash marks the file-wide exception upstream
      # dies with.
      private def task_message(task : LintTask) : {message: String?, crash: Bool}
        none = {message: nil, crash: false}
        name = task.module_name
        # `action:`/`local_action:` directives are parsed as free-form
        # module invocations upstream; the linter keeps its historical
        # skip of them (their "module name" is a directive keyword).
        return none if directive?(name)
        return none if jinja_string_args?(task)
        return none unless key_entry = ArgSpecs.find(name)
        _key, entry = key_entry
        return {message: nil, crash: true} if ArgSpecs.crash?(name)
        return none if ArgSpecs.skip?(name)

        params = collect_params(task)
        # The mocked module run stats its args JSON as a file path
        # before validating anything: a name too long for the filesystem
        # raises ENAMETOOLONG and takes the file's matches down.
        return {message: nil, crash: true} if stat_crash?(params)

        message = first_error(entry, params)
        return none unless message

        # upstream's _parse_failed_msg jinja-drop and its KeyError crash
        # both key off the offending option's raw value in the action
        # dict.
        if match = TYPE_ERROR_PATTERN.match(message) || CHOICES_ERROR_PATTERN.match(message)
          value = params[match[1]]?
          return {message: nil, crash: true} unless value
          # has_jinja is @cache'd (it hashes its argument): a sequence
          # or mapping value raises "unhashable type" there, which is
          # the same file-wide loss.
          return {message: nil, crash: true} if value.seq? || value.map?
          return none if value.jinja?
        end

        # _sanitize_results: these texts never become a match.
        return none if message.starts_with?("parameters are mutually exclusive:")
        return none if message == "unable to evaluate string as dictionary"

        {message: message, crash: false}
      end

      private def directive?(name : String) : Bool
        bare = name.sub("ansible.builtin.", "").sub("ansible.legacy.", "")
        bare == "action" || bare == "local_action"
      end

      # upstream reports nothing at all for a task whose `args:` is a
      # templated string (args.py, ansible-lint#3199).
      private def jinja_string_args?(task : LintTask) : Bool
        return false unless node = task.args_node
        text = NodeUtil.scalar_value(node) || return false
        !!(text =~ JINJA_PATTERN)
      end

      # The task's module arguments as upstream's Task action dict has
      # them: the `args:` entries first (they act as defaults and are
      # overridden by the module's own parameters - mod_args.py), then
      # the action mapping's entries, or the parse_kv form for a
      # free-form scalar action.
      private def collect_params(task : LintTask) : Hash(String, Arg)
        params = {} of String => Arg
        if args = task.args_node.as?(YAML::Nodes::Mapping)
          NodeUtil.each_entry(args) do |key_node, value_node|
            key = key_node.as?(YAML::Nodes::Scalar).try(&.value) || next
            params[key] = Arg.new(value_node)
          end
        end
        action = task.action_node
        if mapping = action.as?(YAML::Nodes::Mapping)
          NodeUtil.each_entry(mapping) do |key_node, value_node|
            key = key_node.as?(YAML::Nodes::Scalar).try(&.value) || next
            params[key] = Arg.new(value_node)
          end
        elsif action.is_a?(YAML::Nodes::Scalar)
          parse_free_form(NodeUtil.scalar_value(action) || "").each do |key, value|
            params[key] = value
          end
        end
        params
      end

      # parse_kv's shape for a non-free-form module's scalar action:
      # `k=v` tokens become parameters, everything else accumulates into
      # _raw_params.
      private def parse_free_form(text : String) : Hash(String, Arg)
        params = {} of String => Arg
        raw = [] of String
        tokenize(text).each do |token|
          unescaped = token.gsub("\\=", "=")
          pos = unescaped.index("=")
          if pos && pos > 0
            params[unescaped[0...pos].strip] = Arg.new(unquote(unescaped[pos + 1..].strip))
          else
            raw << unescaped
          end
        end
        params["_raw_params"] = Arg.new(raw.join(" ")) unless raw.empty?
        params
      end

      # split_args' quote-aware whitespace split, with jinja blocks kept
      # whole (their inner spaces never split a token).
      private def tokenize(text : String) : Array(String)
        tokens = [] of String
        current = String::Builder.new
        quote = nil
        jinja = false
        escape = false
        started = false
        chars = text.chars
        index = 0
        while index < chars.size
          char = chars[index]
          index += 1
          if escape
            current << char
            escape = false
            started = true
            next
          end
          case char
          when '\\' then escape = true; current << char; started = true
          when '{'
            if !jinja && chars[index]? == '{'
              jinja = true
              current << char << chars[index]
              index += 1
            else
              current << char
            end
            started = true
          when '}'
            if jinja && chars[index]? == '}'
              jinja = false
              current << char << chars[index]
              index += 1
            else
              current << char
            end
            started = true
          when '"', '\''
            if quote == char
              quote = nil
            else
              quote ||= char
            end
            current << char
            started = true
          when ' ', '\t', '\n'
            if quote || jinja
              current << char
              started = true
            elsif started
              tokens << current.to_s
              current = String::Builder.new
              started = false
            end
          else
            current << char
            started = true
          end
        end
        tokens << current.to_s if started
        tokens
      end

      private def unquote(text : String) : String
        if text.size >= 2 &&
           ((text.starts_with?('"') && text.ends_with?('"')) ||
           (text.starts_with?('\'') && text.ends_with?('\'')))
          text[1..-2]
        else
          text
        end
      end

      # json.dumps({"ANSIBLE_MODULE_ARGS": <params>}) is stat()ed as a
      # file path by ansible-core's module bootstrap before validation;
      # a name the filesystem cannot even look up (longer than its
      # NAME_MAX) raises there and upstream loses the file's matches.
      private def stat_crash?(params : Hash(String, Arg)) : Bool
        json = String.build do |io|
          io << %({"ANSIBLE_MODULE_ARGS": )
          dump_object(io, params.to_a)
          io << '}'
        end
        # a JSON string that names an existing file is read as the args
        # payload instead, which then fails decoding - same loss.
        File.info(json)
        true
      rescue ex : File::Error
        os_error = ex.os_error
        !(os_error && IGNORED_STAT_ERRNOS.includes?(os_error))
      rescue
        # an embedded NUL byte: Path.is_file() swallows the ValueError
        false
      end

      private def dump_object(io : IO, entries : Array({String, Arg})) : Nil
        io << '{'
        first = true
        entries.each do |key, value|
          io << ", " unless first
          first = false
          dump_string(io, key)
          io << ": "
          dump_arg(io, value)
        end
        io << '}'
      end

      private def dump_arg(io : IO, arg : Arg) : Nil
        case arg.kind
        when :none        then io << "null"
        when :bool        then io << (arg.truthy ? "true" : "false")
        when :int, :float then io << arg.number.to_s
        when :seq
          io << '['
          arg.members.each_with_index do |member, index|
            io << ", " unless index == 0
            dump_arg(io, member)
          end
          io << ']'
        when :map
          dump_object(io, arg.entries)
        else
          dump_string(io, arg.text)
        end
      end

      # Python's ensure_ascii json.dumps string escaping (which is what
      # the args string's byte length is made of).
      private def dump_string(io : IO, text : String) : Nil
        io << '"'
        text.each_char do |char|
          case char
          when '"'  then io << "\\\""
          when '\\' then io << "\\\\"
          when '\b' then io << "\\b"
          when '\f' then io << "\\f"
          when '\n' then io << "\\n"
          when '\r' then io << "\\r"
          when '\t' then io << "\\t"
          else
            ord = char.ord
            if ord < 0x20 || ord > 0x7e
              if ord > 0xffff
                point = ord - 0x10000
                io << "\\u" << (0xD800 + (point >> 10)).to_s(16)
                io << "\\u" << (0xDC00 + (point & 0x3ff)).to_s(16)
              else
                io << "\\u" << ord.to_s(16).rjust(4, '0')
              end
            else
              io << char
            end
          end
        end
        io << '"'
      end

      # Ansible's ArgumentSpecValidator.validate error order: the no-log
      # dict walk, mutually exclusive, required, types, choices,
      # required_together, required_one_of, required_if, required_by,
      # and the (collected) unsupported parameters last. `params` is
      # keyed as the task wrote them.
      private def first_error(entry : JSON::Any, params : Hash(String, Arg)) : String?
        options = ArgSpecs.options(entry)
        aliases = ArgSpecs.alias_map(options)

        # _handle_aliases: an alias's value copies to its canonical
        # name (both keys stay visible to the presence checks).
        provided = {} of String => Arg
        params.each do |key, value|
          provided[aliases[key]? || key] = value
        end
        parameters = provided.dup
        ArgSpecs.defaults(options).each do |name, default|
          parameters[name] = Arg.new(default) unless parameters.has_key?(name)
        end

        if message = no_log_walk_error(options, provided)
          return message
        end
        if message = mutually_exclusive_error(entry, provided, nil)
          return message
        end
        if message = required_error(options, parameters, nil)
          return message
        end
        if message = types_error(options, parameters, nil)
          return message
        end
        if message = choices_error(options, parameters, nil)
          return message
        end
        %w[required_together required_one_of required_if required_by].each do |kind|
          if message = group_error(kind, entry, parameters, nil)
            return message
          end
        end
        if message = sub_spec_error(options, parameters)
          return message
        end
        unsupported_message(options, params, provided)
      end

      # _list_no_log_values' element walk: a string element of a
      # dict-typed option that has suboptions must parse as a dict (the
      # bare check_type_dict TypeError becomes errors[0] verbatim), and
      # every other non-mapping element is its own error.
      private def no_log_walk_error(options : Array(Tuple(String, JSON::Any)), provided : Hash(String, Arg)) : String?
        options.each do |name, spec|
          sub_spec = spec["options"]?.try(&.as_h?) || next
          wanted = ArgSpecs.wanted_type(spec)
          next unless wanted == "dict" || (wanted == "list" && spec["elements"]?.try(&.as_s?) == "dict")
          value = provided[name]? || next
          each_element(value) do |element|
            if message = no_log_element_error(sub_spec, element, name, wanted)
              return message
            end
          end
        end
        nil
      end

      private def no_log_element_error(sub_spec : Hash(String, JSON::Any), element : Arg, field : String, wanted : String) : String?
        if element.str?
          if error = dict_parse_error(element.text)
            return error
          end
          return nil
        end
        return nested_no_log_error(sub_spec, element) if element.map?
        "Value '#{element.repr}' in the sub parameter field '#{field}' must be a #{wanted}, not '#{element.type_name}'"
      end

      private def nested_no_log_error(sub_spec : Hash(String, JSON::Any), value : Arg) : String?
        value.entries.each do |name, sub_value|
          sub = sub_spec[name]?.try(&.as_h?) || next
          wanted = sub["type"]?.try(&.as_s?) || "str"
          next unless wanted == "dict" || (wanted == "list" && sub["elements"]?.try(&.as_s?) == "dict")
          next if sub_value.kind == :none
          each_element(sub_value) do |element|
            if element.str?
              if error = dict_parse_error(element.text)
                return error
              end
            elsif element.map?
              return nested_no_log_error(sub, element)
            else
              return "Value '#{element.repr}' in the sub parameter field '#{name}' must be a #{wanted}, not '#{element.type_name}'"
            end
          end
        end
        nil
      end

      # check_type_dict's three string failures.
      private def dict_parse_error(text : String) : String?
        stripped = text.strip
        if stripped.starts_with?("{")
          return nil if parseable_dict?(stripped)
          return "unable to evaluate string as dictionary"
        end
        return kv_parse_error(stripped) if stripped.includes?("=")
        "dictionary requested, could not parse JSON or key=value"
      end

      private def parseable_dict?(text : String) : Bool
        json = JSON.parse(text) rescue nil
        return true if json && json.as_h?
        # check_type_dict's literal_eval fallback accepts a single-quoted
        # Python dict literal too.
        !!PythonLiteral.dict_json(text).try(&.as_h?)
      end

      # Ansible's key=value field splitter: every comma/space-separated
      # field must carry an "=".
      private def kv_parse_error(text : String) : String?
        text.split(/[,\s]/).reject(&.empty?).each do |field|
          return %(unable to evaluate string in the "key=value" format as dictionary) unless field.includes?("=")
        end
        nil
      end

      private def mutually_exclusive_error(entry : JSON::Any, provided : Hash(String, Arg), context : String?) : String?
        groups = entry["mutually_exclusive"]?.try(&.as_a?) || return nil
        failing = groups.compact_map do |group|
          names = group.as_a.map(&.as_s)
          names.count { |name| provided.has_key?(name) } > 1 ? names.join("|") : nil
        end
        return nil if failing.empty?
        suffix = context ? " found in '#{context}'" : ""
        "parameters are mutually exclusive: #{failing.join(", ")}#{suffix}"
      end

      private def required_error(options : Array(Tuple(String, JSON::Any)), parameters : Hash(String, Arg), context : String?) : String?
        missing = options.compact_map do |name, spec|
          next nil unless spec["required"]?.try(&.as_bool?)
          parameters.has_key?(name) ? nil : name
        end
        return nil if missing.empty?
        suffix = context ? " found in '#{context}'." : ""
        "missing required arguments: #{missing.sort.join(", ")}#{suffix}"
      end

      # _validate_argument_types, walking the spec's declaration order.
      private def types_error(options : Array(Tuple(String, JSON::Any)), parameters : Hash(String, Arg), context : String?) : String?
        options.each do |name, spec|
          value = parameters[name]? || next
          wanted = ArgSpecs.wanted_type(spec)
          next if skipped_none?(spec, value)
          if error = type_error(name, wanted, value, context)
            return error
          end
          if elements = spec["elements"]?.try(&.as_s?)
            elements_of(value, wanted).each do |element|
              if error = element_type_error(name, elements, element, context)
                return error
              end
            end
          end
        end
        nil
      end

      # A None value skips conversion entirely unless the option is
      # required or carries a non-null default (parameters.py).
      private def skipped_none?(spec : JSON::Any, value : Arg) : Bool
        return false unless value.kind == :none
        return false if spec["required"]?.try(&.as_bool?)
        default = spec["default"]?
        default.nil? || default.raw.nil?
      end

      # validation.py's check_type_* errors, as "argument 'x' is of type
      # ... and we were unable to convert to ...: ..." (with the " found
      # in 'y'." clause _validate_argument_types splices in mid-message
      # for sub-specs).
      private def type_error(name : String, wanted : String, value : Arg, context : String?) : String?
        tail = conversion_error(wanted, value)
        return nil unless tail
        context_part = context ? " found in '#{context}'." : ""
        "argument '#{name}' is of type #{value.type_name}#{context_part} and we were unable to convert to #{wanted}: #{tail}"
      end

      private def element_type_error(name : String, wanted : String, element : Arg, context : String?) : String?
        tail = conversion_error(wanted, element)
        return nil unless tail
        context_part = context ? " found in '#{context}'" : ""
        "Elements value for option '#{name}'#{context_part} is of type #{element.type_name} and we were unable to convert to #{wanted}: #{tail}"
      end

      # The TypeError text check_type_<wanted> raises for this value, or
      # nil when the value converts (str/path/raw always convert).
      private def conversion_error(wanted : String, value : Arg) : String?
        case wanted
        when "str", "path", "raw"
          nil
        when "bool"
          case value.kind
          when :bool              then nil
          when :str, :int, :float then boolean_valid?(value) ? nil : boolean_error(value)
          else                         "<class '#{value.type_name}'> cannot be converted to a bool"
          end
        when "int"
          return nil if value.kind == :int || value.kind == :bool
          return nil if int_like?(value)
          %("#{value.repr}" cannot be converted to an int)
        when "float"
          return nil if value.kind == :float || value.kind == :int || value.kind == :bool
          return nil if value.kind == :str && float_like?(value.text)
          "<class '#{value.type_name}'> cannot be converted to a float"
        when "list"
          return nil if value.kind == :seq || value.kind == :str || value.kind == :int || value.kind == :float
          "<class '#{value.type_name}'> cannot be converted to a list"
        when "dict"
          return nil if value.map?
          return dict_parse_error(value.text) if value.str?
          "<class '#{value.type_name}'> cannot be converted to a dict"
        when "jsonarg"
          return nil if value.str? || value.seq? || value.map?
          "<class '#{value.type_name}'> cannot be converted to a json string"
        end
      end

      # convert_bool.boolean(): a string matches BOOLEANS lowercased and
      # stripped; the ints/floats 0 and 1 count as well.
      private def boolean_valid?(value : Arg) : Bool
        case value.kind
        when :bool then true
        when :int, :float
          number = value.number
          !!number && (number == 0 || number == 1)
        when :str
          {"y", "yes", "on", "1", "true", "t", "n", "no", "off", "0", "false", "f"}.includes?(value.text.downcase.strip)
        else
          false
        end
      end

      # convert_bool's error text (the valid-booleans tail is a set
      # iteration upstream, so the fixed order above is one of many).
      private def boolean_error(value : Arg) : String
        "The value '#{value.text}' is not a valid boolean. " \
        "Valid booleans include: #{VALID_BOOLEANS.join(", ")}"
      end

      # check_type_int's decimal-compatibility: the value must equal its
      # own integer truncation ("1.0" passes, "1.5" and "abc" fail).
      private def int_like?(value : Arg) : Bool
        case value.kind
        when :int then true
        when :float
          number = value.number
          !!number && number == number.to_i
        else
          text = value.text
          return false if text.strip.empty?
          decimal = BigDecimal.new(text)
          (decimal - BigDecimal.new(decimal.to_i)) == BigDecimal.new(0)
        end
      rescue
        false
      end

      private def float_like?(text : String) : Bool
        stripped = text.strip
        return false if stripped.empty?
        !!stripped.to_f64?
      end

      # _validate_argument_values, walking the spec's declaration order
      # over the type-converted parameters.
      private def choices_error(options : Array(Tuple(String, JSON::Any)), parameters : Hash(String, Arg), context : String?) : String?
        options.each do |name, spec|
          choices = spec["choices"]?.try(&.as_a?) || next
          value = parameters[name]? || next
          allowed = ArgSpecs.choice_strings(choices)
          wanted = ArgSpecs.wanted_type(spec)
          suffix = context ? " found in '#{context}'" : ""
          # Allow one or more when type='list' param with choices: the
          # check is per member (and a scalar is what check_type_list
          # comma-split it into by then).
          if wanted == "list" || (wanted == "raw" && value.seq?)
            members = elements_of(value, wanted)
            missing = members.reject { |member| allowed.includes?(member.text) }
            next if missing.empty?
            return "value of #{name} must be one or more of: #{allowed.join(", ")}. " \
                   "Got no match for: #{missing.map(&.text).join(", ")}#{suffix}"
          end
          text = value.kind == :none && skipped_none?(spec, value) ? "None" : value.converted_text(wanted)
          next if allowed.includes?(text)
          # PyYaml converts certain strings to bools; a value that
          # stringified to exactly 'True'/'False' rewrites to the choice
          # when the choices overlap the boolean sets in exactly one
          # member (parameters.py), and the rewritten value is what the
          # later group checks see.
          if (text == "True" || text == "False") && (rewritten = bool_choice_rewrite(text, allowed))
            parameters[name] = Arg.new(rewritten)
            next
          end
          return "value of #{name} must be one of: #{allowed.join(", ")}, got: #{text}#{suffix}"
        end
        nil
      end

      # BOOLEANS_TRUE / BOOLEANS_FALSE membership as Python values: the
      # collapsed bool/int/float members and the lowercase spellings.
      private def bool_choice_rewrite(text : String, allowed : Array(String)) : String?
        words = text == "True" ? %w[y yes on 1 true t] : %w[n no off 0 false f]
        natives = text == "True" ? ["True", "1"] : ["False", "0"]
        overlap = allowed.select { |choice| words.includes?(choice) || natives.includes?(choice) }
        overlap.size == 1 ? overlap.first : nil
      end

      # check_required_together / check_required_one_of /
      # check_required_if / check_required_by - the first failing group.
      private def group_error(kind : String, entry : JSON::Any, parameters : Hash(String, Arg), context : String?) : String?
        suffix = context ? " found in '#{context}'" : ""
        case kind
        when "required_together"
          groups = entry["required_together"]?.try(&.as_a?) || return nil
          groups.each do |group|
            names = group.as_a.map(&.as_s)
            present = names.count { |name| parameters.has_key?(name) }
            if present > 0 && present < names.size
              return "parameters are required together: #{names.join(", ")}#{suffix}"
            end
          end
        when "required_one_of"
          groups = entry["required_one_of"]?.try(&.as_a?) || return nil
          groups.each do |group|
            names = group.as_a.map(&.as_s)
            unless names.any? { |name| parameters.has_key?(name) }
              return "one of the following is required: #{names.join(", ")}#{suffix}"
            end
          end
        when "required_if"
          requirements = entry["required_if"]?.try(&.as_a?) || return nil
          requirements.each do |req|
            parts = req.as_a
            key = parts[0].as_s
            trigger = parts[1]
            needed = parts[2].as_a.map(&.as_s)
            any = parts.size > 3 && parts[3].as_bool
            given = parameters[key]? || next
            next unless trigger_matches?(given, trigger, options_type(entry, key))
            missing = needed.reject { |name| parameters.has_key?(name) }
            max_missing = any ? needed.size : 0
            next if missing.empty? || missing.size < max_missing
            requires = any ? "any" : "all"
            return "#{key} is #{ArgSpecs.literal(trigger)} but #{requires} of the following are missing: #{missing.join(", ")}#{suffix}"
          end
        when "required_by"
          requirements = entry["required_by"]?.try(&.as_h?) || return nil
          requirements.each do |key, value|
            given = parameters[key]? || next
            next if given.kind == :none
            needed = value.as_a?.try(&.map(&.as_s)) || [value.as_s]
            missing = needed.select do |name|
              candidate = parameters[name]?
              candidate.nil? || candidate.kind == :none
            end
            next if missing.empty?
            return "missing parameter(s) required by '#{key}': #{missing.join(", ")}#{suffix}"
          end
        end
        nil
      end

      # required_if compares parameters[key] == val after type
      # conversion: a bool trigger only matches a bool-typed option, a
      # string trigger only the converted string.
      private def trigger_matches?(value : Arg, trigger : JSON::Any, wanted : String?) : Bool
        text = value.converted_text(wanted || "str")
        case raw = trigger.raw
        when Bool   then wanted == "bool" && value.kind == :bool && value.truthy == raw
        when String then text == raw
        when Int    then text == raw.to_s
        when Float  then text == raw.to_s
        else             false
        end
      end

      private def options_type(entry : JSON::Any, key : String) : String?
        spec = entry["options"]?.try(&.as_h?).try(&.[key]?)
        spec && ArgSpecs.wanted_type(spec)
      end

      # _validate_sub_spec: one level of suboption checks per provided
      # element (an unknown suboption joins the unsupported message
      # dotted; the rest are errors of their own, in the top-level
      # order, each carrying the parent name as context).
      private def sub_spec_error(options : Array(Tuple(String, JSON::Any)), parameters : Hash(String, Arg)) : String?
        options.each do |name, spec|
          sub_spec = spec["options"]?.try(&.as_h?) || next
          wanted = ArgSpecs.wanted_type(spec)
          next unless wanted == "dict" || (wanted == "list" && spec["elements"]?.try(&.as_s?) == "dict")
          value = parameters[name]? || next
          next if value.kind == :none
          each_element(value) do |element|
            unless element.map?
              return "value of '#{name}' must be of type dict or list of dicts"
            end
            sub_options = sub_spec.to_a
            sub_aliases = ArgSpecs.alias_map(sub_options)
            sub_provided = {} of String => Arg
            element.entries.each do |key, sub_value|
              sub_provided[sub_aliases[key]? || key] = sub_value
            end
            sub_parameters = sub_provided.dup
            ArgSpecs.defaults(sub_options).each do |sub_name, default|
              sub_parameters[sub_name] = Arg.new(default) unless sub_parameters.has_key?(sub_name)
            end
            sub_entry = JSON::Any.new({"options" => JSON::Any.new(sub_spec)})
            if message = mutually_exclusive_error(sub_entry, sub_provided, name)
              return message
            end
            if message = required_error(sub_options, sub_parameters, name)
              return message
            end
            if message = types_error(sub_options, sub_parameters, name)
              return message
            end
            if message = choices_error(sub_options, sub_parameters, name)
              return message
            end
            %w[required_together required_one_of required_if required_by].each do |kind|
              if message = group_error(kind, sub_entry, sub_parameters, name)
                return message
              end
            end
          end
        end
        nil
      end

      # The unsupported-parameters message, with any unknown suboption
      # spelled dotted ("parent.child") like Ansible's own flattening.
      private def unsupported_message(options : Array(Tuple(String, JSON::Any)),
                                      params : Hash(String, Arg), provided : Hash(String, Arg)) : String?
        aliases = ArgSpecs.alias_map(options)
        legal = options.map(&.first) + aliases.keys
        unknown = params.keys.reject { |key| legal.includes?(key) }
        unknown += sub_unsupported(options, provided)
        return nil if unknown.empty?
        names = options.map(&.first).sort!
        alias_names = aliases.keys.sort!
        supported = names.reject { |name| alias_names.includes?(name) }
        tail = alias_names.empty? ? "" : " (#{alias_names.join(", ")})"
        "Unsupported parameters for (basic.py) module: #{unknown.uniq.sort!.join(", ")}. " \
        "Supported parameters include: #{supported.join(", ")}#{tail}."
      end

      private def sub_unsupported(options : Array(Tuple(String, JSON::Any)), provided : Hash(String, Arg)) : Array(String)
        found = [] of String
        options.each do |name, spec|
          sub_spec = spec["options"]?.try(&.as_h?) || next
          wanted = ArgSpecs.wanted_type(spec)
          next unless wanted == "dict" || (wanted == "list" && spec["elements"]?.try(&.as_s?) == "dict")
          value = provided[name]? || next
          next if value.kind == :none
          sub_aliases = ArgSpecs.alias_map(sub_spec.to_a)
          each_element(value) do |element|
            next unless element.map?
            element.entries.each do |key, _|
              canonical = sub_aliases[key]? || key
              found << "#{name}.#{key}" unless sub_spec.has_key?(canonical)
            end
          end
        end
        found
      end

      private def each_element(value : Arg, &)
        if value.seq?
          value.members.each { |member| yield member }
        else
          yield value
        end
      end

      # The converted members of a list-typed option: the sequence's own
      # members, or what check_type_list comma-split a scalar into.
      private def elements_of(value : Arg, wanted : String) : Array(Arg)
        return value.members if value.seq?
        if wanted == "list" && value.str?
          return value.text.split(",").map { |piece| Arg.new(piece) }
        end
        [value]
      end
    end

    # One module argument as ansible's validation sees it: the Python
    # value PyYAML resolves a YAML node to (a plain scalar's YAML 1.1
    # type, or the node's sequence/mapping shape), or the plain string a
    # free-form action produced.
    struct Arg
      getter source : YAML::Nodes::Node | String | JSON::Any

      def initialize(@source)
      end

      def seq? : Bool
        case source = @source
        when YAML::Nodes::Sequence then true
        when JSON::Any             then !source.as_a?.nil?
        else                            false
        end
      end

      def map? : Bool
        case source = @source
        when YAML::Nodes::Mapping then true
        when JSON::Any            then !source.as_h?.nil?
        else                           false
        end
      end

      def str? : Bool
        kind == :str
      end

      # PyYAML's YAML 1.1 resolution of a plain scalar, or a spec
      # default's own JSON-native type.
      def kind : Symbol
        case source = @source
        when String                then :str
        when YAML::Nodes::Sequence then :seq
        when YAML::Nodes::Mapping  then :map
        when JSON::Any
          case source.raw
          when Nil     then :none
          when Bool    then :bool
          when Int64   then :int
          when Float64 then :float
          when String  then :str
          else              source.as_h? ? :map : :seq
          end
        else
          node = source.as(YAML::Nodes::Scalar)
          return :str unless node.style == YAML::ScalarStyle::PLAIN
          text = node.value
          return :none if ArgsModuleRule::NULL_WORDS.includes?(text)
          return :bool if ArgsModuleRule::BOOL_WORDS.includes?(text)
          return :int if text =~ ArgsModuleRule::INT_PATTERN
          return :float if text =~ ArgsModuleRule::FLOAT_PATTERN
          :str
        end
      end

      def text : String
        case source = @source
        when String              then source
        when YAML::Nodes::Scalar then source.value
        when JSON::Any
          case raw = source.raw
          when Bool   then raw ? "True" : "False"
          when String then raw
          when Nil    then "None"
          else             source.to_s
          end
        else ""
        end
      end

      def truthy : Bool
        if json = @source.as?(JSON::Any)
          return json.raw == true if json.raw.is_a?(Bool)
        end
        {"yes", "Yes", "YES", "true", "True", "TRUE", "on", "On", "ON"}.includes?(text)
      end

      def type_name : String
        case kind
        when :none  then "NoneType"
        when :bool  then "bool"
        when :int   then "int"
        when :float then "float"
        when :seq   then "list"
        when :map   then "dict"
        else             "str"
        end
      end

      # Python's int()/float() view of a literal (PyYAML's constructors
      # parse 0x/0o/0b and leading-zero octal too).
      def number : Int64 | Float64 | Nil
        case source = @source
        when JSON::Any
          raw = source.raw
          return raw if raw.is_a?(Int64) || raw.is_a?(Float64)
          nil
        else
          case kind
          when :int
            cleaned = text.tr("_", "")
            if cleaned =~ /\A[-+]?0[bB]/
              cleaned.to_i64?(prefix: true)
            elsif cleaned =~ /\A[-+]?0[oO]?[0-7]+\z/
              negative = cleaned.starts_with?('-')
              digits = cleaned.lstrip("+-").sub(/\A0[oO]?/, "")
              parsed = digits.to_i64?(8)
              parsed && (negative ? -parsed : parsed)
            elsif cleaned =~ /\A[-+]?0[xX]/
              cleaned.to_i64?(prefix: true)
            else
              cleaned.to_i64?
            end
          when :float
            text.tr("_", "").to_f64?
          end
        end
      end

      # Python repr() of the value, for the messages that embed it.
      def repr : String
        case kind
        when :none  then "None"
        when :bool  then truthy ? "True" : "False"
        when :int   then (number || 0).to_s
        when :float then (number || 0.0).to_s
        when :seq   then "[#{members.map(&.repr).join(", ")}]"
        when :map   then "{#{entries.map { |key, value| "'#{key}': #{value.repr}" }.join(", ")}}"
        else             "'#{text}'"
        end
      end

      def members : Array(Arg)
        case source = @source
        when YAML::Nodes::Sequence then source.nodes.map { |node| Arg.new(node) }
        when JSON::Any
          list = source.as_a? || return [] of Arg
          list.map { |item| Arg.new(item) }
        else
          [] of Arg
        end
      end

      def entries : Array({String, Arg})
        list = [] of {String, Arg}
        case source = @source
        when YAML::Nodes::Mapping
          NodeUtil.each_entry(source) do |key_node, value_node|
            key = key_node.as?(YAML::Nodes::Scalar).try(&.value) || next
            list << {key, Arg.new(value_node)}
          end
        when JSON::Any
          if hash = source.as_h?
            hash.each do |key, value|
              list << {key, Arg.new(value)}
            end
          end
        end
        list
      end

      # ansiblelint.text.has_jinja (a string-only test upstream - a
      # sequence/mapping value raises in its @cache before it runs).
      def jinja? : Bool
        str? && !!(text =~ ArgsModuleRule::JINJA_PATTERN)
      end

      # str() of the type-converted value - what the choices check and
      # its "got: " rendering see.
      def converted_text(wanted : String) : String
        case kind
        when :none
          wanted == "str" || wanted == "path" ? "" : "None"
        when :bool
          wanted == "str" || wanted == "path" ? (truthy ? "True" : "False") : text
        when :int, :float
          wanted == "str" || wanted == "path" ? number.to_s : text
        else
          text
        end
      end
    end
  end
end
