require "json"
require "krikri_jinja"
require "./variable_substitutor/filter_core"
require "./ipaddr_core"
require "./jmespath"
require "./python_lookup_runner"
require "./jinja_host_context"
require "./variable_substitutor/filter_engine"
require "./py_random"
require "./vault"
require "./task_executor/result_display"

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

    # Dotted-numeric version comparison for the `version` test: digit runs
    # compare component by component ("8.9p1" is [8, 9, 1]).
    def self.compare_versions(a : String, b : String) : Int32
      a_parts = a.scan(/\d+/).map(&.[0].to_i64)
      b_parts = b.scan(/\d+/).map(&.[0].to_i64)
      Math.max(a_parts.size, b_parts.size).times do |i|
        cmp = (a_parts[i]? || 0_i64) <=> (b_parts[i]? || 0_i64)
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
          # A dict operand (the bare `ansible_version` magic var rather than
          # its `.full` field) is a templating error in real Ansible, not a
          # digit scan over the dict's text (timorunge.pmm_client).
          if value.raw.is_a?(Hash)
            raise KrikriJinja::TemplateError.new(
              "Version comparison failed: unsupported operand type (dict, not a scalar version string)", 0
            )
          end
          compare_to = args[0]? || kwargs["version"]? || kwargs["compare_to"]? || JSON::Any.new("")
          operator = args[1]? || kwargs["operator"]? || JSON::Any.new("==")
          version_test(py_str(value), py_str(compare_to), py_str(operator))
        end
      end

      # `regex`/`search` match anywhere, `match` anchors at the start
      # (Python's re.search / re.match).
      {"regex", "search", "match"}.each do |test_name|
        KrikriJinja.register_default_json_test(test_name) do |value, args, kwargs|
          pattern = py_str(args[0]? || kwargs["pattern"]? || JSON::Any.new(""))
          options = Regex::Options::None
          options |= Regex::Options::IGNORE_CASE if (args[1]? || kwargs["ignorecase"]?).try { |flag| py_truthy(flag) }
          options |= Regex::Options::MULTILINE if (args[2]? || kwargs["multiline"]?).try { |flag| py_truthy(flag) }
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

    def self.register : Nil
      KrikriJinja.register_default_json_filter("pytruthy") do |value, _args, _kwargs|
        JSON::Any.new(py_truthy(value))
      end

      KrikriJinja.register_default_json_filter("bool") do |value, _args, _kwargs|
        JSON::Any.new(case raw = value.raw
        when Bool   then raw
        when String then ["true", "yes", "1", "on"].includes?(raw.downcase)
        else             false
        end)
      end

      KrikriJinja.register_default_json_filter("ternary") do |value, args, _kwargs|
        if args.size < 2
          raise KrikriJinja::TemplateError.new(
            "ternary() missing #{2 - args.size} required positional " \
            "#{(2 - args.size) == 1 ? "argument" : "arguments"}", 0
          )
        end
        none_arg = args[2]?
        if value.raw.nil? && none_arg
          none_arg
        else
          py_truthy(value) ? args[0] : args[1]
        end
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
        JSON::Any.new(JSON.parse(VariableSubstitutor::FilterCore.to_nice_json(value, sort_keys)).to_pretty_json(indent: "    "))
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

      KrikriJinja.register_default_json_filter("union") do |value, args, _kwargs|
        JSON::Any.new(any_list(([value] + args).flat_map { |item| item.as_a.map(&.to_s) }.uniq))
      end

      KrikriJinja.register_default_json_filter("intersect") do |value, args, _kwargs|
        common = value.as_a.map(&.to_s)
        args.each { |arg| common = common.select { |item| arg.as_a.map(&.to_s).includes?(item) } }
        JSON::Any.new(any_list(common.sort))
      end

      KrikriJinja.register_default_json_filter("difference") do |value, args, _kwargs|
        exclude = args.flat_map { |arg| arg.as_a.map(&.to_s) }
        JSON::Any.new(any_list(value.as_a.map(&.to_s).reject { |item| exclude.includes?(item) }))
      end

      KrikriJinja.register_default_json_filter("symmetric_difference") do |value, args, _kwargs|
        other = args.flat_map { |arg| arg.as_a.map(&.to_s) }
        left = value.as_a.map(&.to_s)
        JSON::Any.new(any_list((left.reject { |item| other.includes?(item) } +
                                other.reject { |item| left.includes?(item) }).sort))
      end

      KrikriJinja.register_default_json_filter("product") do |value, args, _kwargs|
        lists = [value] + args
        lists = lists.map { |list| list.as_a? || [list] }
        combos = [[] of JSON::Any]
        lists.each do |list|
          combos = combos.flat_map { |combo| list.map { |item| combo + [item] } }
        end
        JSON::Any.new(combos.map { |combo| JSON::Any.new(combo) })
      end

      KrikriJinja.register_default_json_filter("path_join") do |value, args, _kwargs|
        parts = [value] + args
        rendered = parts.map { |part| part.as_s? || part.to_s }
        JSON::Any.new(VariableSubstitutor::FilterCore.normpath(rendered.join("/")))
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
        fileglob flatten combine rekey_on_member extract
        regex_replace regex_search regex_findall log pow
        relpath vault unvault splitlines
        combinations permutations expandvars from_yaml_all hash lists_mergeby
        map_format password_hash realpath strftime to_datetime to_json
        to_nice_yaml urlsplit zip zip_longest
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

      # Real Jinja2's `first`/`last` on an empty sequence produce an undefined
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
      # the permutation real Ansible does.
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

      # `root`: the filesystem-root prefix of a path, "/" or "".
      KrikriJinja.register_default_json_filter("root") do |value, _args, _kwargs|
        JSON::Any.new((value.raw.as?(String) || value.to_s).starts_with?("/") ? "/" : "")
      end

      # dict2items/items2dict are implemented here rather than delegated, so
      # they do not route back through the engine that called them.
      KrikriJinja.register_default_json_filter("dict2items") do |value, args, kwargs|
        hash = value.as_h?
        next value unless hash
        key_name = (args[0]? || kwargs["key_name"]?).try(&.as_s?) || "key"
        value_name = (args[1]? || kwargs["value_name"]?).try(&.as_s?) || "value"
        JSON::Any.new(hash.map { |key, item|
          JSON::Any.new({key_name => JSON::Any.new(key), value_name => item})
        })
      end

      # items2dict: each entry's `key_name` field becomes the key and its
      # `value_name` field the value (live-verified against ansible-core:
      # `[{'k': 1, 'v': 'x'}] | items2dict(key_name='k', value_name='v')`
      # is `{1: 'x'}`).
      KrikriJinja.register_default_json_filter("items2dict") do |value, args, kwargs|
        key_name = (args[0]? || kwargs["key_name"]?).try(&.as_s?) || "key"
        value_name = (args[1]? || kwargs["value_name"]?).try(&.as_s?) || "value"
        result = {} of String => JSON::Any
        (value.as_a? || [] of JSON::Any).each do |entry|
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

      # `lookup()` / `query()` dispatch to the controller's own python3
      # wrapper, resolving a role-local `lookup_plugins/*.py` the same way the
      # hand-rolled evaluator does. wantlist/errors are Templar's generic
      # options, popped before the plugin sees them.
      ["lookup", "query"].each do |function_name|
        KrikriJinja.register_default_function(function_name) do |args, kwargs, ctx|
          host = ctx.host_context
          raise KrikriJinja::TemplateError.new("#{function_name}() requires a name", 0) unless host.is_a?(Krikri::JinjaHostContext)
          json_args = args.map { |arg| KrikriJinja.to_json_any(arg) }
          raise KrikriJinja::TemplateError.new("#{function_name}() requires a name", 0) if json_args.empty?
          name = json_args[0].as_s
          terms = json_args[1..]

          role_path = host.vars["role_path"]?.try(&.as_s?)
          playbook_dir = host.vars["playbook_dir"]?.try(&.as_s?)
          source = PythonLookupRunner.find_source(name, role_path, playbook_dir)
          raise KrikriJinja::TemplateError.new("#{name} is not a valid lookup plugin", 0) unless source

          options = {} of String => JSON::Any
          kwargs.each do |key, value|
            next if {"wantlist", "errors"}.includes?(key)
            options[key] = KrikriJinja.to_json_any(value)
          end

          result = PythonLookupRunner.call_lookup(
            name, source, terms, host.lookup_variables, options
          )
          KrikriJinja.from_json_any(result)
        end
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
                     value
                   end
          next false unless result
          case raw = result.raw
          when Hash then raw[test_name]?.try(&.raw) == true
          else           false
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
        JSON::Any.new(VariableSubstitutor::FilterCore.to_yaml(value))
      end

      KrikriJinja.register_default_json_filter("from_json") do |value, _args, _kwargs|
        JSON.parse(value.to_s)
      rescue ex : JSON::ParseException
        raise KrikriJinja::TemplateError.new(ex.message || "invalid JSON", 0)
      end

      KrikriJinja.register_default_json_filter("from_yaml") do |value, _args, _kwargs|
        yaml_to_json(YAML.parse(value.to_s))
      end
    end
  end
end

Krikri::KrikriJinjaFilters.register
Krikri::KrikriJinjaFilters.register_tests
