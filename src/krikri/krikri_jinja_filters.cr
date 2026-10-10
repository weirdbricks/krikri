require "json"
require "krikri-jinja/krikri_jinja"
require "./variable_substitutor/filter_core"
require "./ipaddr_core"
require "./jmespath"
require "./python_lookup_runner"
require "./python_test_runner"
require "./jinja_host_context"
require "./variable_substitutor/filter_engine"
require "./py_random"
require "./vault"
require "./task_executor/result_display"
require "./krikri_jinja_lookups"
require "./jinja_datetime"

module Krikri
  # Ansible's own filters, registered directly on the krikri-jinja engine
  # shared by the module-level `render` / `evaluate_expression` helpers, so
  # expression evaluation and template rendering resolve the same names with
  # the same semantics. This is the first batch: the filters whose behavior is
  # pure value shaping and is already implemented against JSON::Any in
  # FilterCore, with no Ansible-lookup or register-result dependencies.
  module KrikriJinjaFilters
    # Real Python/Jinja2 truthiness over JSON values: `false`, `0`, null,
    # undefined, the empty string, and empty collections are falsy.
    def self.py_truthy(value : JSON::Any) : Bool
      case raw = value.raw
      when Nil          then false
      when Bool         then raw
      when Int64, Int32 then raw != 0
      when Float64      then raw != 0.0
      when String       then !raw.empty?
      when Array        then !raw.empty?
      when Hash         then !raw.empty?
      else                   true
      end
    end

    def self.any_list(items : Array(String)) : Array(JSON::Any)
      items.map { |item| JSON::Any.new(item) }
    end

    # YAML documents carry no JSON typing, so convert structurally rather
    # than round-tripping through JSON text.
    def self.yaml_to_json(node : YAML::Any) : JSON::Any
      case raw = node.raw
      when Nil     then JSON::Any.new(nil)
      when Bool    then JSON::Any.new(raw)
      when Int64   then JSON::Any.new(raw)
      when Float64 then JSON::Any.new(raw)
      when String  then JSON::Any.new(raw)
      when Array   then JSON::Any.new(raw.map { |item| yaml_to_json(item) })
      when Hash    then JSON::Any.new(raw.to_h { |key, item| {key.to_s, yaml_to_json(item)} })
      else              JSON::Any.new(node.to_s)
      end
    end

    # Role-local `filter_plugins/*.py` define filters on the controller at
    # run time, so they are resolved per render (the rendering scope decides
    # which role's plugin directory applies) and registered on that render's
    # own engine.
    def self.ensure_python_filter(name : String, vars : Hash(String, JSON::Any),
                                  engine : KrikriJinja::Engine) : Bool
      role_path = vars["role_path"]?.try(&.as_s?)
      playbook_dir = vars["playbook_dir"]?.try(&.as_s?)
      return false unless role_path || playbook_dir
      return false unless PythonFilterRunner.defines_filter?(name, PythonFilterRunner.find_sources(role_path, playbook_dir))

      engine.register_json_filter(name) do |value, args, kwargs|
        sources = PythonFilterRunner.find_sources(
          vars["role_path"]?.try(&.as_s?), vars["playbook_dir"]?.try(&.as_s?)
        )
        if sources.empty? || !PythonFilterRunner.defines_filter?(name, sources)
          raise KrikriJinja::TemplateError.new("No filter named '#{name}'.", 0)
        end
        PythonFilterRunner.call_filter(name, sources, value, args, kwargs, vars)
      end
      true
    end

    # Role-local `test_plugins/*.py` define tests on the controller at run
    # time, so they are resolved per render (the rendering scope decides
    # which role's plugin directory applies) and registered on that render's
    # own engine - the test-side twin of #ensure_python_filter (Aisbergg.
    # networkmanager's `value is list`, round 2300110).
    def self.ensure_python_test(name : String, vars : Hash(String, JSON::Any),
                                engine : KrikriJinja::Engine) : Bool
      role_path = vars["role_path"]?.try(&.as_s?)
      playbook_dir = vars["playbook_dir"]?.try(&.as_s?)
      return false unless role_path || playbook_dir
      return false unless PythonTestRunner.defines_test?(name, PythonTestRunner.find_sources(role_path, playbook_dir))

      engine.register_json_test(name) do |value, args, kwargs|
        sources = PythonTestRunner.find_sources(
          vars["role_path"]?.try(&.as_s?), vars["playbook_dir"]?.try(&.as_s?)
        )
        if sources.empty? || !PythonTestRunner.defines_test?(name, sources)
          raise KrikriJinja::TemplateError.new("No test named '#{name}'.", 0)
        end
        py_truthy(PythonTestRunner.call_test(name, sources, value, args, kwargs, vars))
      end
      true
    end

    private def self.subelements_walk(elements : Array(JSON::Any), fields : Array(String),
                                      skip_missing : Bool, results : Array(JSON::Any)) : Nil
      field = fields[0]? || return
      elements.each do |element|
        found = element.as_h?.try(&.[field]?)
        unless found
          next if skip_missing
          raise KrikriJinja::TemplateError.new("subelements: element missing key '#{field}': #{element.to_json}", 0)
        end
        if fields.size > 1
          subelements_walk(found.as_a? || [] of JSON::Any, fields[1..], skip_missing, results)
        elsif items = found.as_a?
          items.each { |item| results << JSON::Any.new([element, item]) }
        else
          results << JSON::Any.new([element, found])
        end
      end
    end

    # Shared-engine twin of #ensure_python_filter, for the `{{ }}` expression
    # path: the filter is registered once on the process-wide default engine,
    # so it must resolve the rendering scope's plugin sources and variables
    # from each call's host context, never from the scope that happened to
    # register it (a later role would otherwise dispatch to the wrong
    # role's plugin file).
    def self.ensure_shared_python_filter(name : String, vars : Hash(String, JSON::Any)) : Bool
      role_path = vars["role_path"]?.try(&.as_s?)
      playbook_dir = vars["playbook_dir"]?.try(&.as_s?)
      return false unless role_path || playbook_dir
      return false unless PythonFilterRunner.defines_filter?(name, PythonFilterRunner.find_sources(role_path, playbook_dir))

      KrikriJinja.register_default_filter(name) do |value, args, kwargs, ctx|
        host = ctx.host_context
        scope = host.is_a?(Krikri::JinjaHostContext) ? host.vars : {} of String => JSON::Any
        sources = PythonFilterRunner.find_sources(
          scope["role_path"]?.try(&.as_s?), scope["playbook_dir"]?.try(&.as_s?)
        )
        if sources.empty? || !PythonFilterRunner.defines_filter?(name, sources)
          raise KrikriJinja::TemplateError.new("No filter named '#{name}'.", 0)
        end
        KrikriJinja.from_json_any(PythonFilterRunner.call_filter(
          name, sources, KrikriJinja.to_json_any(value),
          args.map { |arg| KrikriJinja.to_json_any(arg) },
          kwargs.transform_values { |arg| KrikriJinja.to_json_any(arg) }, scope
        ))
      end
      true
    end

    # The filter name a krikri-jinja "unknown filter" error names, if any.
    def self.unknown_filter_name(error : KrikriJinja::TemplateError) : String?
      message = error.message || return nil
      return nil unless message.includes?("unknown filter")
      message.split('"')[1]?
    end

    # The test name a krikri-jinja "unknown test" error names, if any -
    # the test-side twin of #unknown_filter_name.
    def self.unknown_test_name(error : KrikriJinja::TemplateError) : String?
      message = error.message || return nil
      return nil unless message.includes?("unknown test")
      message.split('"')[1]?
    end

    # Shared-engine twin of #ensure_python_test, for the `{{ }}` expression
    # path: the test is registered once on the process-wide default engine,
    # so it must resolve the rendering scope's plugin sources and variables
    # from each call's host context, never from the scope that happened to
    # register it (a later role would otherwise dispatch to the wrong role's
    # plugin file). Mirrors #ensure_shared_python_filter.
    def self.ensure_shared_python_test(name : String, vars : Hash(String, JSON::Any)) : Bool
      role_path = vars["role_path"]?.try(&.as_s?)
      playbook_dir = vars["playbook_dir"]?.try(&.as_s?)
      return false unless role_path || playbook_dir
      return false unless PythonTestRunner.defines_test?(name, PythonTestRunner.find_sources(role_path, playbook_dir))

      KrikriJinja.register_default_test(name) do |value, args, kwargs, ctx|
        host = ctx.host_context
        scope = host.is_a?(Krikri::JinjaHostContext) ? host.vars : {} of String => JSON::Any
        sources = PythonTestRunner.find_sources(
          scope["role_path"]?.try(&.as_s?), scope["playbook_dir"]?.try(&.as_s?)
        )
        if sources.empty? || !PythonTestRunner.defines_test?(name, sources)
          raise KrikriJinja::TemplateError.new("No test named '#{name}'.", 0)
        end
        py_truthy(PythonTestRunner.call_test(
          name, sources, KrikriJinja.to_json_any(value),
          args.map { |arg| KrikriJinja.to_json_any(arg) },
          kwargs.transform_values { |arg| KrikriJinja.to_json_any(arg) }, scope
        ))
      end
      true
    end

    # Python's type name for a JSON value, as Ansible's error messages
    # report it.
    def self.py_type_name(value : JSON::Any) : String
      case value.raw
      when Nil     then "NoneType"
      when Bool    then "bool"
      when Int64   then "int"
      when Float64 then "float"
      when String  then "str"
      when Array   then "list"
      else              "dict"
      end
    end

    # Python's `str()` of a JSON value, for tests that read their operand as
    # text (path and pattern tests).
    def self.py_str(value : JSON::Any) : String
      case raw = value.raw
      when String         then raw
      when Nil            then "None"
      when Bool           then raw ? "True" : "False"
      when Int64, Float64 then raw.to_s
      else                     value.to_json
      end
    end

    # LooseVersion component parse for the `version` test -
    # ansible-core's version comparison walks distutils LooseVersion's
    # component list: digit runs become ints, [a-z]+ runs stay strings,
    # literal dots are kept as components, and EVERYTHING else is
    # dropped. List comparison: prefix-exhaustion is less, and the first
    # int-vs-str mismatch is a TypeError ("'<' not supported between
    # instances of 'str' and 'int'" - always '<', Python list ordering
    # bottoms out in __lt__ no matter which operator was asked for).
    def self.loose_version_components(s : String) : Array(Int64 | String)
      parts = [] of Int64 | String
      s.scan(/\d+|[a-z]+|\./).each do |match|
        text = match[0]
        parts << (text.matches?(/\d+/) ? text.to_i64 : text)
      end
      parts
    end

    def self.compare_versions(a : String, b : String) : Int32
      a_parts = loose_version_components(a)
      b_parts = loose_version_components(b)
      Math.max(a_parts.size, b_parts.size).times do |i|
        x = a_parts[i]?
        y = b_parts[i]?
        return -1 if x.nil?
        return 1 if y.nil?
        x_int = x.is_a?(Int64)
        y_int = y.is_a?(Int64)
        cmp = if x_int == y_int
                x_int ? (x.as(Int64) <=> y.as(Int64)) : (x.as(String) <=> y.as(String))
              else
                raise KrikriJinja::TemplateError.new(
                  "Version comparison failed: '<' not supported between instances of '#{x_int ? "int" : "str"}' and '#{y_int ? "int" : "str"}'", 0
                )
              end
        return cmp unless cmp == 0
      end
      0
    end

    def self.version_test(target : String, compare_to : String, operator : String) : Bool
      cmp = compare_versions(target, compare_to)
      case operator
      when "==", "=", "eq"  then cmp == 0
      when "!=", "<>", "ne" then cmp != 0
      when "<", "lt"        then cmp < 0
      when "<=", "le"       then cmp <= 0
      when ">", "gt"        then cmp > 0
      when ">=", "ge"       then cmp >= 0
      else                       false
      end
    end

    # A registered async/connection result's integer-or-bool flag.
    def self.async_field_truthy?(value : JSON::Any, field : String) : Bool
      case raw = value.as_h?.try(&.[field]?).try(&.raw)
      when Bool         then raw
      when Int64, Int32 then raw != 0
      else                   false
      end
    end

    def self.mountpoint?(path : String) : Bool
      Process.run("mountpoint", ["-q", path]).success?
    rescue
      false
    end

    URN_PATTERN = /^urn:[a-zA-Z0-9][a-zA-Z0-9-]{0,31}:[a-zA-Z0-9()+,\-.:=@;$_!*'%\/?#]+$/i
    URL_PATTERN = /\A[a-zA-Z][a-zA-Z0-9+.\-]*:\/\/\S+\z/

    # Ansible's own tests (ansible.builtin), which Jinja2 does not ship.
    def self.register_tests : Nil
      {"version", "version_compare"}.each do |test_name|
        KrikriJinja.register_default_json_test(test_name) do |value, args, kwargs|
          begin
            # A dict operand (the bare `ansible_version` magic var rather than
            # its `.full` field) is a templating error in Ansible, not a
            # digit scan over the dict's text (timorunge.pmm_client).
            if value.raw.is_a?(Hash)
              raise KrikriJinja::TemplateError.new(
                "Version comparison failed: unsupported operand type (dict, not a scalar version string)", 0
              )
            end
            # The same kwargs semantics as the `when:`-side evaluator
            # (conditional_evaluator.cr's evaluate_version_test, which owns
            # the full validation-order pinning against 2.19.11): trailing
            # strict=/version_type= kwargs select the comparison scheme,
            # positionals past the operator bind to strict/version_type in
            # signature order, and the same error wordings apply - kept in
            # sync here because a version test inside a template FILE takes
            # this path, not the conditional one.
            fail_test = ->(inner : String) {
              raise KrikriJinja::TemplateError.new(
                "The test plugin 'ansible.builtin.#{test_name}' failed: #{inner}", 0
              )
            }
            unknown = kwargs.keys.find { |k| !{"operator", "version", "strict", "version_type"}.includes?(k) }
            fail_test.call("version_compare() got an unexpected keyword argument '#{unknown}'") if unknown
            compare_to = args[0]? || kwargs["version"]?
            fail_test.call("version_compare() got multiple values for argument 'version'") if args[0]? && kwargs.has_key?("version")
            if compare_to.nil?
              fail_test.call("version_compare() missing 1 required positional argument: 'version'")
            end
            operator = args[1]? || kwargs["operator"]?
            fail_test.call("version_compare() got multiple values for argument 'operator'") if args[1]? && kwargs.has_key?("operator")
            strict = args[2]? || kwargs["strict"]?
            version_type = args[3]? || kwargs["version_type"]?
            if args.size > 4
              fail_test.call("version_compare() takes from 2 to 5 positional arguments but #{args.size + 1} were given")
            end
            strict_given = !strict.nil? && !strict.raw.nil?
            version_type_given = !version_type.nil? && !version_type.raw.nil?
            fail_test.call("Cannot specify both 'strict' and 'version_type'") if strict_given && version_type_given
            left = py_str(value)
            fail_test.call("Input version value cannot be empty") if left.empty?
            compare_text = py_str(compare_to)
            fail_test.call("Version parameter to compare against cannot be empty") if compare_text.empty?
            mode = "loose"
            if strict_given && (strict_val = strict) && py_truthy(strict_val)
              mode = "strict"
            elsif version_type_given && (version_type_val = version_type)
              case py_str(version_type_val)
              when "loose"
                mode = "loose"
              when "strict"
                mode = "strict"
              when "semver", "semantic"
                mode = "semver"
              when "pep440"
                mode = "pep440"
              else
                fail_test.call("Invalid version type (#{py_str(version_type_val)}). Must be one of 'loose', 'strict', 'semver', 'semantic', 'pep440'")
              end
            end
            op_map = {
              "==" => "eq", "=" => "eq", "eq" => "eq",
              "<" => "lt", "lt" => "lt",
              "<=" => "le", "le" => "le",
              ">" => "gt", "gt" => "gt",
              ">=" => "ge", "ge" => "ge",
              "!=" => "ne", "<>" => "ne", "ne" => "ne",
            }
            op_text = py_str(operator || JSON::Any.new("eq"))
            op = op_map[op_text]?
            unless op
              fail_test.call("Invalid operator type (#{op_text}). Must be one of '==', '=', 'eq', '<', 'lt', '<=', 'le', '>', 'gt', '>=', 'ge', '!=', '<>', 'ne'")
            end
            cmp = case mode
                  when "strict" then VariableSubstitutor::FilterCore.strict_version_cmp(left, compare_text)
                  when "semver" then VariableSubstitutor::FilterCore.semver_cmp(left, compare_text)
                  when "pep440" then VariableSubstitutor::FilterCore.pep440_cmp(left, compare_text)
                  else               VariableSubstitutor::FilterCore.loose_version_cmp(left, compare_text)
                  end
            case op
            when "eq" then cmp == 0
            when "ne" then cmp != 0
            when "lt" then cmp < 0
            when "le" then cmp <= 0
            when "gt" then cmp > 0
            else           cmp >= 0
            end
          rescue ex : VariableSubstitutor::FilterCore::VersionCompareError
            raise KrikriJinja::TemplateError.new(
              "The test plugin 'ansible.builtin.#{test_name}' failed: Version comparison failed: #{ex.message}", 0
            )
          end
        end
      end

      # `regex`/`search` match anywhere, `match` anchors at the start
      # (Python's re.search / re.match).
      {"regex", "search", "match"}.each do |test_name|
        KrikriJinja.register_default_json_test(test_name) do |value, args, kwargs|
          pattern = py_str(args[0]? || kwargs["pattern"]? || JSON::Any.new(""))
          options = Regex::Options::None
          options |= Regex::Options::IGNORE_CASE if (args[1]? || kwargs["ignorecase"]?).try { |flag| py_truthy(flag) }
          # Python's re.M (what Ansible's test kwargs build) only moves
          # ^/$ to line boundaries; `.` must NOT cross newlines. Crystal's
          # Regex::Options::MULTILINE maps to PCRE MULTILINE|DOTALL (Ruby
          # semantics), so MULTILINE_ONLY is the Python-equivalent here.
          options |= Regex::Options::MULTILINE_ONLY if (args[2]? || kwargs["multiline"]?).try { |flag| py_truthy(flag) }
          pattern = "^(?:#{pattern})" if test_name == "match"
          !!(py_str(value) =~ VariableSubstitutor::FilterEngine.cached_regex(pattern, options))
        end
      end

      KrikriJinja.register_default_json_test("any") { |value, _args, _kwargs| (value.as_a? || [] of JSON::Any).any? { |item| py_truthy(item) } }
      KrikriJinja.register_default_json_test("all") { |value, _args, _kwargs| (value.as_a? || [] of JSON::Any).all? { |item| py_truthy(item) } }
      KrikriJinja.register_default_json_test("truthy") { |value, _args, _kwargs| py_truthy(value) }
      KrikriJinja.register_default_json_test("falsy") { |value, _args, _kwargs| !py_truthy(value) }

      {"subset", "issubset"}.each do |test_name|
        KrikriJinja.register_default_json_test(test_name) do |value, args, _kwargs|
          other = args[0]?.try(&.as_a?) || [] of JSON::Any
          (value.as_a? || [] of JSON::Any).all? { |item| other.includes?(item) }
        end
      end
      {"superset", "issuperset"}.each do |test_name|
        KrikriJinja.register_default_json_test(test_name) do |value, args, _kwargs|
          target = value.as_a? || [] of JSON::Any
          (args[0]?.try(&.as_a?) || [] of JSON::Any).all? { |item| target.includes?(item) }
        end
      end

      # `contains(item)`: Python's `item in value` for the value's shape.
      KrikriJinja.register_default_json_test("contains") do |value, args, _kwargs|
        other = args[0]? || JSON::Any.new(nil)
        case raw = value.raw
        when Array  then raw.includes?(other)
        when Hash   then raw.has_key?(py_str(other))
        when String then raw.includes?(py_str(other))
        else             false
        end
      end

      # Path tests run against the controller's filesystem, like Ansible's
      # own os.path wrappers.
      KrikriJinja.register_default_json_test("exists") { |value, _args, _kwargs| File.exists?(py_str(value)) }
      {"file", "is_file"}.each { |name| KrikriJinja.register_default_json_test(name) { |value, _args, _kwargs| File.file?(py_str(value)) } }
      {"directory", "is_dir"}.each { |name| KrikriJinja.register_default_json_test(name) { |value, _args, _kwargs| Dir.exists?(py_str(value)) } }
      KrikriJinja.register_default_json_test("is_abs") { |value, _args, _kwargs| py_str(value).starts_with?("/") }
      {"link", "is_link"}.each { |name| KrikriJinja.register_default_json_test(name) { |value, _args, _kwargs| File.symlink?(py_str(value)) } }
      {"mount", "is_mount"}.each { |name| KrikriJinja.register_default_json_test(name) { |value, _args, _kwargs| mountpoint?(py_str(value)) } }
      KrikriJinja.register_default_json_test("link_exists") { |value, _args, _kwargs| !!File.info?(py_str(value), follow_symlinks: false) }
      {"same_file", "is_same_file"}.each do |test_name|
        KrikriJinja.register_default_json_test(test_name) do |value, args, _kwargs|
          path1 = py_str(value)
          path2 = py_str(args[0]? || JSON::Any.new(""))
          File.exists?(path1) && File.exists?(path2) && File.same?(path1, path2)
        end
      end

      KrikriJinja.register_default_json_test("vault_encrypted") { |value, _args, _kwargs| Krikri::Vault.encrypted?(py_str(value)) }
      KrikriJinja.register_default_json_test("vaulted_file") do |value, _args, _kwargs|
        content = File.read(py_str(value)) rescue nil
        content ? Krikri::Vault.encrypted?(content) : false
      end

      KrikriJinja.register_default_json_test("urn") { |value, _args, _kwargs| !!(py_str(value) =~ URN_PATTERN) }
      {"uri", "url"}.each { |name| KrikriJinja.register_default_json_test(name) { |value, _args, _kwargs| !!(py_str(value) =~ URL_PATTERN) } }

      {"started", "timedout", "unreachable"}.each do |test_name|
        KrikriJinja.register_default_json_test(test_name) { |value, _args, _kwargs| async_field_truthy?(value, test_name) }
      end
      KrikriJinja.register_default_json_test("reachable") { |value, _args, _kwargs| !async_field_truthy?(value, "unreachable") }

      # `abs` is Ansible's path test (os.path.isabs), not a number check:
      # live-verified, `'/etc/x' is abs` is True and `5 is abs` fails the
      # task ("expected str, bytes or os.PathLike object, not int").
      KrikriJinja.register_default_json_test("abs") do |value, _args, _kwargs|
        unless path = value.as_s?
          raise KrikriJinja::TemplateError.new(
            "expected str, bytes or os.PathLike object, not #{value.raw.is_a?(Int64) ? "int" : value.raw.class.name.downcase}", 0
          )
        end
        path.starts_with?("/")
      end
      {"isnan", "nan"}.each do |test_name|
        KrikriJinja.register_default_json_test(test_name) do |value, _args, _kwargs|
          raw = value.raw
          raw.is_a?(Float64) && raw.nan?
        end
      end
    end

    # Ansible's finalize for rendered output: None renders as an empty
    # string and tuples as lists (live-verified: `a{{ none }}b` is "ab",
    # `{{ d | dictsort }}` inside text is "[['a', 1]]").
    def self.ansible_finalize(value : KrikriJinja::AnyValue) : KrikriJinja::AnyValue
      case raw = value.raw
      when Nil                     then KrikriJinja::AnyValue.new("")
      when KrikriJinja::TupleValue then KrikriJinja::AnyValue.new(raw.items.map { |item| tuples_to_lists(item) })
      when Array, Hash             then tuples_to_lists(value)
      else                              value
      end
    end

    private def self.tuples_to_lists(value : KrikriJinja::AnyValue) : KrikriJinja::AnyValue
      case raw = value.raw
      when KrikriJinja::TupleValue then KrikriJinja::AnyValue.new(raw.items.map { |item| tuples_to_lists(item) })
      when Array                   then KrikriJinja::AnyValue.new(raw.map { |item| tuples_to_lists(item) })
      when Hash                    then KrikriJinja::AnyValue.new(raw.transform_values { |item| tuples_to_lists(item) })
      else                              value
      end
    end

    def self.register : Nil
      KrikriJinja.default_engine.finalize = ->(value : KrikriJinja::AnyValue) { ansible_finalize(value) }
      # ansible-core exposes `omit` as a Jinja GLOBAL in every templating
      # context (_jinja_bits.py passes `omit=Omit` into the Jinja globals),
      # so a `.j2` template file's `val != omit` / `x | default(omit)`
      # resolves - live-verified against 2.19.11. The expression and
      # task-param paths already resolve the name themselves
      # (JinjaVarResolver, ExpressionEvaluator, JinjaHostContext), but the
      # template ACTION plugin renders through `Engine#render_string` with
      # no resolver, so the name was simply undefined there:
      # "Failed to render template: line 0: 'omit' is undefined"
      # (Turgon37.sudoers' templates/_macros.j2, galaxyproject.slurm's
      # slurm.conf.j2/generic.conf.j2). Registered as the same sentinel
      # every other path compares against, so `val != omit` behaves the
      # same everywhere; derive_engine copies it into the template
      # plugin's own derived engine.
      KrikriJinja.default_engine.register_global("omit", Krikri::OMIT_SENTINEL)
      # ansible-core fails `{% for k, v in some_dict %}`, but roles that
      # pass on it in practice (jtyr.motd, jtyr.nsswitch) reach this form
      # with values Ansible keeps as pairs; keep it working.
      KrikriJinja.default_engine.dict_pair_unpacking = true
      KrikriJinja.register_default_json_filter("pytruthy") do |value, _args, _kwargs|
        JSON::Any.new(py_truthy(value))
      end

      KrikriJinja.register_default_json_filter("bool") do |value, _args, _kwargs|
        raw = value.raw
        JSON::Any.new(case raw
        when Bool   then raw
        when String then ["true", "yes", "1", "on"].includes?(raw.downcase)
        else             false
        end)
      end

      # ternary is a PASS-THROUGH filter in real Jinja2/Ansible: the filter
      # receives its arguments as Python objects and returns one of them
      # verbatim, so an argument that is a strict Undefined (a registered
      # skipped task's missing `.stdout`, say) flows through UNCONSUMED and
      # only raises if the selection actually lands on it - verified against
      # ansible-core 2.19.11: `{{ false | ternary(skipped.stdout, 'hello') }}`
      # renders "hello", `{{ true | ternary(skipped.stdout, 'hi') }}` fails
      # with "object of type 'dict' has no attribute 'stdout'" (the same
      # laziness the `X if COND else Y` expression already has). The JSON
      # wrapper raised the moment the undefined argument crossed into the
      # filter, failing the taken-branch case (adfinis-sygroup.motd's own
      # `{{ motd_cowsay | ternary(motd_cowsay_message.stdout, motd_message) }}`
      # with motd_cowsay false). Registered as a NATIVE filter so the
      # AnyValue arguments (undefined ones included) pass through untouched;
      # only the CONDITION is consumed, exactly like real's bool(value).
      KrikriJinja.register_default_filter("ternary") do |value, args, _kwargs, _ctx|
        if args.size < 2
          raise KrikriJinja::TemplateError.new(
            "ternary() missing #{2 - args.size} required positional " \
            "#{(2 - args.size) == 1 ? "argument" : "arguments"}", 0
          )
        end
        # A LENIENT undefined condition keeps the old JSON-wrapper behavior
        # (it crossed into the filter as JSON null: the none_val branch won
        # when one was given); a STRICT one raises right here, matching
        # real's bool(undefined) inside the filter.
        lenient_undefined = value.raw.is_a?(KrikriJinja::Undefined) &&
                            !value.raw.as(KrikriJinja::Undefined).strict?
        none_arg = args[2]?
        next none_arg if (value.raw.nil? || lenient_undefined) && none_arg
        KrikriJinja.truthy?(value) ? args[0] : args[1]
      end

      # Ansible's own `comment` filter: renders a shell/config comment block
      # into the rendered output, per the chosen style (os_hardening's
      # `{{ ansible_managed | comment }}` headers are the common case).
      KrikriJinja.register_default_json_filter("comment") do |value, args, kwargs|
        style = (args[0]? || kwargs["style"]? || JSON::Any.new("plain")).as_s
        beginning, decoration, ending = case style
                                        when "erlang" then {"", "% ", ""}
                                        when "c"      then {"", "// ", ""}
                                        when "cblock" then {"/*", " * ", " */"}
                                        when "xml"    then {"<!--", " - ", "-->"}
                                        else               {"", "# ", ""}
                                        end
        decoration = (kwargs["decoration"]? || JSON::Any.new(decoration)).as_s
        beginning = (kwargs["beginning"]? || JSON::Any.new(beginning)).as_s
        ending = (kwargs["end"]? || JSON::Any.new(ending)).as_s
        prefix = (kwargs["prefix"]? || JSON::Any.new(decoration.rstrip)).as_s
        postfix = (kwargs["postfix"]? || JSON::Any.new(decoration.rstrip)).as_s
        prefix_count = (kwargs["prefix_count"]? || JSON::Any.new(1)).as_i
        postfix_count = (kwargs["postfix_count"]? || JSON::Any.new(1)).as_i

        str_beginning = beginning.empty? ? "" : "#{beginning}\n"
        str_prefix = prefix.empty? ? "" : (["#{prefix}"] * prefix_count).join('\n') + "\n"
        lines = value.to_s.split('\n')
        str_text = lines.map { |line| line.empty? ? decoration.rstrip : "#{decoration}#{line}" }.join('\n')
        str_postfix = postfix_count > 0 ? ("\n" + (["#{postfix}"] * postfix_count).join('\n')) : ""
        str_end = ending.empty? ? "" : "\n#{ending}"
        JSON::Any.new("#{str_beginning}#{str_prefix}#{str_text}#{str_postfix}#{str_end}")
      end

      KrikriJinja.register_default_json_filter("to_nice_json") do |value, _args, kwargs|
        sort_keys = kwargs["sort_keys"]? ? py_truthy(kwargs["sort_keys"]) : true
        indent = kwargs["indent"]?.try(&.as_i?) || 4
        JSON::Any.new(Krikri::PyDump.json(value, indent, sort_keys))
      end

      # Second batch: pure string/collection shaping filters whose JSON-level
      # implementations already live in FilterCore.
      {
        "b64encode"       => ->(s : String) { VariableSubstitutor::FilterCore.b64encode(s) },
        "b64decode"       => ->(s : String) { VariableSubstitutor::FilterCore.b64decode(s) },
        "urldecode"       => ->(s : String) { VariableSubstitutor::FilterCore.urldecode(s) },
        "regex_escape"    => ->(s : String) { VariableSubstitutor::FilterCore.regex_escape(s) },
        "normpath"        => ->(s : String) { VariableSubstitutor::FilterCore.normpath(s) },
        "basename"        => ->(s : String) { VariableSubstitutor::FilterCore.basename(s) },
        "dirname"         => ->(s : String) { VariableSubstitutor::FilterCore.dirname(s) },
        "to_uuid"         => ->(s : String) { VariableSubstitutor::FilterCore.to_uuid(s) },
        "checksum"        => ->(s : String) { VariableSubstitutor::FilterCore.checksum(s) },
        "md5"             => ->(s : String) { VariableSubstitutor::FilterCore.md5(s) },
        "sha1"            => ->(s : String) { VariableSubstitutor::FilterCore.sha1(s) },
        "netmask_to_cidr" => ->(s : String) { VariableSubstitutor::FilterCore.netmask_to_cidr(s).to_s },
        "human_to_bytes"  => ->(s : String) { VariableSubstitutor::FilterCore.parse_human_to_bytes(s).to_s },
        "quote"           => ->(s : String) { Process.quote(s) },
      }.each do |name, handler|
        KrikriJinja.register_default_json_filter(name) do |value, _args, _kwargs|
          JSON::Any.new(handler.call(value.to_s))
        end
      end

      KrikriJinja.register_default_json_filter("expanduser") do |value, _args, _kwargs|
        JSON::Any.new(VariableSubstitutor::FilterCore.expanduser(value.to_s))
      end

      # to_uuid's namespace: positional or keyword (`to_uuid(x, ns)` /
      # `to_uuid(x, namespace=ns)` - real filter_plugin's plain second
      # parameter). Registered AFTER the batch above so this kwargs-aware
      # handler is the one the engine sees.
      KrikriJinja.register_default_json_filter("to_uuid") do |value, args, kwargs|
        namespace = kwargs["namespace"]? || args[0]? || JSON::Any.new("361E6D51-FAEC-444A-9079-341386DA8E2E")
        JSON::Any.new(VariableSubstitutor::FilterCore.to_uuid(value.to_s, namespace.to_s))
      end

      KrikriJinja.register_default_json_filter("human_readable") do |value, _args, kwargs|
        isbits = kwargs["isbits"]? ? py_truthy(kwargs["isbits"]) : false
        JSON::Any.new(VariableSubstitutor::FilterCore.format_human_readable(value.to_s.to_i64? || 0_i64, isbits))
      end

      KrikriJinja.register_default_json_filter("commonpath") do |value, _args, _kwargs|
        JSON::Any.new(VariableSubstitutor::FilterCore.commonpath(value.as_a.map(&.to_s)))
      end

      KrikriJinja.register_default_json_filter("splitext") do |value, _args, _kwargs|
        root, ext = VariableSubstitutor::FilterCore.splitext(value.to_s)
        JSON::Any.new([JSON::Any.new(root), JSON::Any.new(ext)])
      end

      # Third batch: collection filters plus Ansible's omit/mandatory/type_debug.
      KrikriJinja.register_default_json_filter("omit") do |value, args, _kwargs|
        drop = args.map(&.to_s)
        case raw = value.raw
        when Hash
          JSON::Any.new(raw.reject { |key, _| drop.includes?(key) })
        else
          value
        end
      end

      KrikriJinja.register_default_json_filter("mandatory") do |value, args, _kwargs|
        if value.raw.nil?
          message = args[0]?.try(&.as_s) || "Mandatory variable not defined."
          raise KrikriJinja::TemplateError.new(message, 0)
        end
        value
      end

      KrikriJinja.register_default_json_filter("type_debug") do |value, _args, _kwargs|
        JSON::Any.new(case value.raw
        when Nil     then "NoneType"
        when Bool    then "bool"
        when Int64   then "int"
        when Float64 then "float"
        when String  then "str"
        when Array   then "list"
        when Hash    then "dict"
        else              value.raw.class.name
        end)
      end

      # Set filters keep element types and first-seen order (Ansible's own
      # unique-preserving implementations), shared with FilterEngine.
      KrikriJinja.register_default_json_filter("union") do |value, args, _kwargs|
        JSON::Any.new(VariableSubstitutor::FilterCore.union(value.as_a? || [] of JSON::Any, args[0]?.try(&.as_a?) || [] of JSON::Any))
      end

      KrikriJinja.register_default_json_filter("intersect") do |value, args, _kwargs|
        JSON::Any.new(VariableSubstitutor::FilterCore.intersect(value.as_a? || [] of JSON::Any, args[0]?.try(&.as_a?) || [] of JSON::Any))
      end

      KrikriJinja.register_default_json_filter("difference") do |value, args, _kwargs|
        JSON::Any.new(VariableSubstitutor::FilterCore.difference(value.as_a? || [] of JSON::Any, args[0]?.try(&.as_a?) || [] of JSON::Any))
      end

      KrikriJinja.register_default_json_filter("symmetric_difference") do |value, args, _kwargs|
        JSON::Any.new(VariableSubstitutor::FilterCore.symmetric_difference(value.as_a? || [] of JSON::Any, args[0]?.try(&.as_a?) || [] of JSON::Any))
      end

      # path_join takes a list of components; an absolute one resets.
      KrikriJinja.register_default_json_filter("path_join") do |value, _args, _kwargs|
        parts = value.as_a?.try(&.map { |part| py_str(part) }) || [py_str(value)]
        JSON::Any.new(VariableSubstitutor::FilterCore.path_join(parts))
      end

      KrikriJinja.register_default_json_filter("split") do |value, args, _kwargs|
        text = value.to_s
        separator = args[0]?.try(&.as_s) || " "
        parts = if separator == " "
                  text.split(/[ \t\r\n]+/).reject(&.empty?)
                else
                  text.split(separator, remove_empty: false)
                end
        JSON::Any.new(any_list(parts))
      end

      # Fourth batch: the ansible.utils ipaddr family, jmespath, and the
      # YAML/JSON conversion filters, all of which already have JSON-level
      # implementations shared with the hand-rolled FilterEngine.

      # The remaining Ansible filters keep Krikri's own JSON-level
      # implementations (FilterEngine) as the single source of truth, reached
      # through the host context's variable scope so a registered filter and
      # a hand-rolled one can never drift apart.
      %w(
        fileglob flatten
        regex_replace regex_search regex_findall
        vault unvault splitlines
        expandvars hash
        map_format password_hash realpath strftime to_json
        urlsplit
      ).each do |filter_name|
        KrikriJinja.register_default_filter(filter_name) do |value, args, kwargs, ctx|
          host = ctx.host_context
          vars = host.is_a?(Krikri::JinjaHostContext) ? host.vars : {} of String => JSON::Any
          json_value = KrikriJinja.to_json_any(value)
          json_args = args.map { |arg| KrikriJinja.to_json_any(arg) }
          json_kwargs = kwargs.transform_values { |arg| KrikriJinja.to_json_any(arg) }
          parts = json_args.map(&.to_json)
          json_kwargs.each { |key, arg| parts << "#{key}=#{arg.to_json}" }
          result = VariableSubstitutor::FilterEngine.new(vars)
            .apply(json_value, "#{filter_name}(#{parts.join(", ")})")
          KrikriJinja.from_json_any(result)
        end
      end

      # Jinja2's `first`/`last` on an empty sequence produce an undefined
      # that fails the moment anything touches it ("No first item, sequence
      # was empty."); raising here gives the same task failure instead of a
      # silently undefined value (`ansible_mounts | selectattr(...) | first`
      # on no match, robertdebock.mount_options round 140).
      {"first", "last"}.each do |filter_name|
        builtin = KrikriJinja.default_engine.filters[filter_name]
        KrikriJinja.register_default_filter(filter_name) do |value, args, kwargs, ctx|
          empty = case raw = value.raw
                  when Array  then raw.empty?
                  when String then raw.empty?
                  when Hash   then raw.empty?
                  else             false
                  end
          raise KrikriJinja::TemplateError.new("No #{filter_name} item, sequence was empty.", 0) if empty
          builtin.call(value, args, kwargs, ctx)
        end
      end

      # `subelements(obj, 'key', skip_missing=false)`: [element, subelement]
      # pairs, the filter form of `with_subelements`. A list of field names
      # descends through nested elements; a missing key raises unless
      # skip_missing is set.
      KrikriJinja.register_default_json_filter("subelements") do |value, args, kwargs|
        field_spec = args[0]? || kwargs["subfields"]? || JSON::Any.new(nil)
        fields = if text = field_spec.as_s?
                   [text]
                 else
                   (field_spec.as_a? || [] of JSON::Any).map { |field| field.raw.as?(String) || field.to_s }
                 end
        skip_missing = py_truthy(args[1]? || kwargs["skip_missing"]? || JSON::Any.new(false))
        results = [] of JSON::Any
        subelements_walk(value.as_a? || [] of JSON::Any, fields, skip_missing, results)
        JSON::Any.new(results)
      end

      # `shuffle(seed=None)`: Python's `Random(seed).shuffle`, bit for bit, so
      # a seeded shuffle (os_hardening's per-host password alphabet) gives
      # the permutation Ansible does.
      KrikriJinja.register_default_json_filter("shuffle") do |value, args, kwargs|
        items = (value.as_a? || (value.as_s? || "").chars.map { |char| JSON::Any.new(char.to_s) }).dup
        seed = args[0]? || kwargs["seed"]?
        if seed && !seed.raw.nil?
          rng = (int_seed = seed.raw.as?(Int64)) ? PyRandom.new(int_seed) : PyRandom.new(py_str(seed))
          (items.size - 1).downto(1) do |i|
            j = rng.randbelow(i + 1)
            items[i], items[j] = items[j], items[i]
          end
          JSON::Any.new(items)
        else
          JSON::Any.new(items.shuffle)
        end
      end

      # Collection and dict filters with a single JSON-level implementation
      # in FilterCore, shared with the hand-rolled FilterEngine.
      KrikriJinja.register_default_json_filter("combine") do |value, args, kwargs|
        # Ansible flattens list arguments one level: combine([d1, d2]).
        others = args.flat_map { |arg| arg.as_a? || [arg] }
        VariableSubstitutor::FilterCore.combine(
          value, others, py_truthy(kwargs["recursive"]? || JSON::Any.new(false)),
          py_str(kwargs["list_merge"]? || JSON::Any.new("replace"))
        )
      end

      {"lists_mergeby", "list_mergeby"}.each do |filter_name|
        KrikriJinja.register_default_json_filter(filter_name) do |value, args, kwargs|
          raise KrikriJinja::TemplateError.new("lists_mergeby: missing merge key argument", 0) if args.empty?
          VariableSubstitutor::FilterCore.lists_mergeby(
            [value] + args[0..-2], py_str(args[-1]),
            py_truthy(kwargs["recursive"]? || JSON::Any.new(false)),
            py_str(kwargs["list_merge"]? || JSON::Any.new("replace"))
          )
        end
      end

      {"zip" => false, "zip_longest" => true}.each do |filter_name, longest|
        KrikriJinja.register_default_json_filter(filter_name) do |value, args, kwargs|
          VariableSubstitutor::FilterCore.zip([value] + args, longest, kwargs["fillvalue"]? || JSON::Any.new(nil))
        end
      end

      KrikriJinja.register_default_json_filter("product") do |value, args, _kwargs|
        VariableSubstitutor::FilterCore.product([value] + args)
      end

      KrikriJinja.register_default_json_filter("to_nice_yaml") do |value, _args, kwargs|
        sort_keys = kwargs["sort_keys"]?.try { |flag| py_truthy(flag) }
        indent = kwargs["indent"]?.try(&.as_i?) || 4
        JSON::Any.new(Krikri::PyDump.yaml(value, indent, false, sort_keys.nil? ? true : sort_keys))
      end

      KrikriJinja.register_default_json_filter("relpath") do |value, args, kwargs|
        JSON::Any.new(VariableSubstitutor::FilterCore.relpath(py_str(value), py_str(args[0]? || kwargs["start"]? || JSON::Any.new("."))))
      end

      KrikriJinja.register_default_json_filter("log") do |value, args, kwargs|
        JSON::Any.new(VariableSubstitutor::FilterCore.log(value, args[0]? || kwargs["base"]?))
      end

      KrikriJinja.register_default_json_filter("pow") do |value, args, kwargs|
        JSON::Any.new(VariableSubstitutor::FilterCore.pow(value, args[0]? || kwargs["x"]? || JSON::Any.new(0_i64)))
      end

      KrikriJinja.register_default_json_filter("combinations") do |value, args, kwargs|
        n = (args[0]? || kwargs["n"]?).try(&.as_i64?) || 2_i64
        JSON::Any.new(VariableSubstitutor::FilterCore.combinations(value.as_a? || [] of JSON::Any, n.to_i32)
          .map { |combo| JSON::Any.new(combo) })
      end

      KrikriJinja.register_default_json_filter("permutations") do |value, args, kwargs|
        items = value.as_a? || [] of JSON::Any
        n = (args[0]? || kwargs["n"]?).try(&.as_i64?) || items.size.to_i64
        JSON::Any.new(VariableSubstitutor::FilterCore.permutations(items, n.to_i32).map { |perm| JSON::Any.new(perm) })
      end

      KrikriJinja.register_default_json_filter("rekey_on_member") do |value, args, kwargs|
        VariableSubstitutor::FilterCore.rekey_on_member(
          value, py_str(args[0]? || kwargs["member"]? || JSON::Any.new("")),
          py_str(args[1]? || kwargs["duplicates"]? || JSON::Any.new("error"))
        )
      end

      KrikriJinja.register_default_json_filter("from_yaml_all") do |value, _args, _kwargs|
        VariableSubstitutor::FilterCore.from_yaml_all(py_str(value))
      end

      # `extract(container, morekeys=None)`. A miss inside `hostvars` reports
      # Ansible's own HostVarsVars wrapper type rather than a plain dict.
      KrikriJinja.register_default_filter("extract") do |value, args, kwargs, ctx|
        container = args[0]? || kwargs["container"]?
        raise KrikriJinja::TemplateError.new("extract() missing required argument 'container'", 0) unless container
        hostvars = ctx["hostvars"].raw
        label = (hostvars.is_a?(Hash) && container.raw.as?(Hash).try(&.same?(hostvars))) ? "HostVarsVars" : nil
        keys = [KrikriJinja.to_json_any(value)]
        if morekeys = (args[1]? || kwargs["morekeys"]?)
          json_morekeys = KrikriJinja.to_json_any(morekeys)
          unless json_morekeys.raw.nil?
            json_morekeys.as_a? ? keys.concat(json_morekeys.as_a) : keys << json_morekeys
          end
        end
        KrikriJinja.from_json_any(VariableSubstitutor::FilterCore.extract(KrikriJinja.to_json_any(container), keys, label))
      end

      # `root`: the filesystem-root prefix of a path, "/" or "".
      KrikriJinja.register_default_json_filter("root") do |value, _args, _kwargs|
        JSON::Any.new((value.raw.as?(String) || value.to_s).starts_with?("/") ? "/" : "")
      end

      # dict2items/items2dict are implemented here rather than delegated, so
      # they do not route back through the engine that called them.
      KrikriJinja.register_default_json_filter("dict2items") do |value, args, kwargs|
        hash = value.as_h?
        unless hash
          raise KrikriJinja::TemplateError.new("dict2items requires a dictionary, got <class '#{py_type_name(value)}'> instead.", 0)
        end
        key_name = (args[0]? || kwargs["key_name"]?).try(&.as_s?) || "key"
        value_name = (args[1]? || kwargs["value_name"]?).try(&.as_s?) || "value"
        items = hash.map do |key, item|
          JSON::Any.new({key_name => JSON::Any.new(key), value_name => item})
        end
        JSON::Any.new(items)
      end

      # items2dict: each entry's `key_name` field becomes the key and its
      # `value_name` field the value (live-verified against ansible-core:
      # `[{'k': 1, 'v': 'x'}] | items2dict(key_name='k', value_name='v')`
      # is `{1: 'x'}`).
      KrikriJinja.register_default_json_filter("items2dict") do |value, args, kwargs|
        key_name = (args[0]? || kwargs["key_name"]?).try(&.as_s?) || "key"
        value_name = (args[1]? || kwargs["value_name"]?).try(&.as_s?) || "value"
        unless items = value.as_a?
          raise KrikriJinja::TemplateError.new("items2dict requires a list, got <class '#{py_type_name(value)}'> instead.", 0)
        end
        result = {} of String => JSON::Any
        items.each do |entry|
          pair = entry.as_h?
          unless pair && (entry_key = pair[key_name]?) && (entry_value = pair[value_name]?)
            raise KrikriJinja::TemplateError.new(
              "items2dict requires each dictionary in the list to contain the keys '#{key_name}' and " \
              "'#{value_name}', got #{ResultDisplay.python_repr(value)} instead.", 0
            )
          end
          result[py_str(entry_key)] = entry_value
        end
        JSON::Any.new(result)
      end

      # Ansible's register-result tests (`{{ result_var is failed }}`): the
      # registered value lives in Krikri's variable scope, which reaches the
      # engine through the host context.
      {"failed" => "failed", "failure" => "failed", "succeeded" => "succeeded", "success" => "succeeded",
       "successful" => "succeeded", "changed" => "changed", "change" => "changed", "skipped" => "skipped",
       "skip" => "skipped", "omitted" => "omitted", "finished" => "finished"}.each do |registered_name, test_name|
        KrikriJinja.register_default_test(registered_name) do |value, args, _kwargs, ctx|
          host = ctx.host_context
          # Ansible's own signature is `failed(result)`, so the bare
          # `registered_var is failed` form passes the registered RESULT
          # itself; `is failed('name')` instead names the variable, which
          # resolves against Krikri's scope through the host context.
          result = if name = args[0]?.try(&.raw.as?(String))
                     host.is_a?(Krikri::JinjaHostContext) ? host.registered(name) : nil
                   else
                     value.raw.is_a?(KrikriJinja::Undefined) ? nil : KrikriJinja.to_json_any(value)
                   end
          next false unless result
          hash = result.as_h?
          next false unless hash
          case test_name
          when "succeeded"
            # Ansible's success tests are `not failed(result)`; a result has
            # no "succeeded" field of its own.
            !py_truthy(hash["failed"]? || JSON::Any.new(false))
          when "finished"
            async_field_truthy?(result, "finished")
          when "changed"
            # A looped result is changed when any of its items is.
            py_truthy(hash["changed"]? || JSON::Any.new(false)) ||
              (hash["results"]?.try(&.as_a?) || [] of JSON::Any).any? { |item| py_truthy(item.as_h?.try(&.["changed"]?) || JSON::Any.new(false)) }
          else
            py_truthy(hash[test_name]? || JSON::Any.new(false))
          end
        end
      end

      KrikriJinja.register_default_json_filter("ipaddr") do |value, args, _kwargs|
        IpAddrCore.ipaddr(value, args[0]?.try(&.as_s) || "")
      end

      KrikriJinja.register_default_json_filter("ipwrap") do |value, args, _kwargs|
        IpAddrCore.ipwrap(value, args[0]?.try(&.as_s) || "")
      end

      KrikriJinja.register_default_json_filter("ipv4") do |value, args, _kwargs|
        IpAddrCore.ipaddr(value, args[0]?.try(&.as_s) || "", 4, "ipv4")
      end

      KrikriJinja.register_default_json_filter("ipv6") do |value, args, _kwargs|
        IpAddrCore.ipaddr(value, args[0]?.try(&.as_s) || "", 6, "ipv6")
      end

      KrikriJinja.register_default_json_filter("ipsubnet") do |value, args, _kwargs|
        IpAddrCore.ipsubnet(value, args[0]?.try(&.as_s) || "", args[1]?.try(&.as_s))
      end

      KrikriJinja.register_default_json_filter("ipmath") do |value, args, _kwargs|
        amount = args[0]?.try(&.as_i?)
        raise KrikriJinja::TemplateError.new("You must pass an integer for arithmetic", 0) unless amount
        IpAddrCore.ipmath(value, amount)
      end

      KrikriJinja.register_default_json_filter("next_nth_usable") do |value, args, _kwargs|
        offset = args[0]?.try(&.as_i?)
        raise KrikriJinja::TemplateError.new("Must pass in an integer", 0) unless offset
        IpAddrCore.next_nth_usable(value, offset)
      end

      KrikriJinja.register_default_json_filter("previous_nth_usable") do |value, args, _kwargs|
        offset = args[0]?.try(&.as_i?)
        raise KrikriJinja::TemplateError.new("Must pass in an integer", 0) unless offset
        IpAddrCore.previous_nth_usable(value, offset)
      end

      KrikriJinja.register_default_json_filter("network_in_network") do |value, args, _kwargs|
        IpAddrCore.network_in_network(value, args[0]? || JSON::Any.new(nil))
      end

      KrikriJinja.register_default_json_filter("network_in_usable") do |value, args, _kwargs|
        IpAddrCore.network_in_usable(value, args[0]? || JSON::Any.new(nil))
      end

      KrikriJinja.register_default_json_filter("ip4_hex") do |value, args, _kwargs|
        IpAddrCore.ip4_hex(value, args[0]?.try(&.as_s) || "")
      end

      KrikriJinja.register_default_json_filter("json_query") do |value, args, _kwargs|
        expression = args[0]?.try(&.as_s) || ""
        Krikri::JMESPath.evaluate_json_query(expression, value)
      end

      KrikriJinja.register_default_json_filter("to_yaml") do |value, _args, _kwargs|
        JSON::Any.new(Krikri::PyDump.yaml(value, 2, nil))
      end

      KrikriJinja.register_default_json_filter("from_json") do |value, _args, _kwargs|
        JSON.parse(value.to_s)
      rescue ex : JSON::ParseException
        raise KrikriJinja::TemplateError.new(ex.message || "invalid JSON", 0)
      end

      KrikriJinja.register_default_json_filter("from_yaml") do |value, _args, _kwargs|
        # An already-structured value passes through unchanged.
        next value unless text = value.as_s?
        yaml_to_json(YAML.parse(text))
      end
    end
  end
end

Krikri::KrikriJinjaFilters.register
Krikri::KrikriJinjaFilters.register_tests
