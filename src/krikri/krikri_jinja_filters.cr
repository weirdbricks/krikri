require "json"
require "krikri_jinja"
require "./variable_substitutor/filter_core"
require "./ipaddr_core"
require "./jmespath"

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
      when Nil        then false
      when Bool       then raw
      when Int64, Int32 then raw != 0
      when Float64    then raw != 0.0
      when String     then !raw.empty?
      when Array      then !raw.empty?
      when Hash       then !raw.empty?
      else                 true
      end
    end

    def self.any_list(items : Array(String)) : Array(JSON::Any)
      items.map { |item| JSON::Any.new(item) }
    end

    # YAML documents carry no JSON typing, so convert structurally rather
    # than round-tripping through JSON text.
    def self.yaml_to_json(node : YAML::Any) : JSON::Any
      case raw = node.raw
      when Nil        then JSON::Any.new(nil)
      when Bool       then JSON::Any.new(raw)
      when Int64      then JSON::Any.new(raw)
      when Float64    then JSON::Any.new(raw)
      when String     then JSON::Any.new(raw)
      when Array      then JSON::Any.new(raw.map { |item| yaml_to_json(item) })
      when Hash       then JSON::Any.new(raw.to_h { |key, item| {key.to_s, yaml_to_json(item)} })
      else                  JSON::Any.new(node.to_s)
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
        "b64encode"    => ->(s : String) { VariableSubstitutor::FilterCore.b64encode(s) },
        "b64decode"    => ->(s : String) { VariableSubstitutor::FilterCore.b64decode(s) },
        "urldecode"    => ->(s : String) { VariableSubstitutor::FilterCore.urldecode(s) },
        "regex_escape" => ->(s : String) { VariableSubstitutor::FilterCore.regex_escape(s) },
        "normpath"     => ->(s : String) { VariableSubstitutor::FilterCore.normpath(s) },
        "basename"     => ->(s : String) { VariableSubstitutor::FilterCore.basename(s) },
        "dirname"      => ->(s : String) { VariableSubstitutor::FilterCore.dirname(s) },
        "to_uuid"      => ->(s : String) { VariableSubstitutor::FilterCore.to_uuid(s) },
        "checksum"     => ->(s : String) { VariableSubstitutor::FilterCore.checksum(s) },
        "md5"          => ->(s : String) { VariableSubstitutor::FilterCore.md5(s) },
        "sha1"         => ->(s : String) { VariableSubstitutor::FilterCore.sha1(s) },
        "netmask_to_cidr" => ->(s : String) { VariableSubstitutor::FilterCore.netmask_to_cidr(s).to_s },
        "human_to_bytes"  => ->(s : String) { VariableSubstitutor::FilterCore.parse_human_to_bytes(s).to_s },
        "quote"        => ->(s : String) { Process.quote(s) },
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
                     when Nil        then "NoneType"
                     when Bool       then "bool"
                     when Int64      then "int"
                     when Float64    then "float"
                     when String     then "str"
                     when Array      then "list"
                     when Hash       then "dict"
                     else                 value.raw.class.name
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
