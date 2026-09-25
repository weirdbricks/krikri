require "json"
require "krikri_jinja"
require "./variable_substitutor/filter_core"

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
    end
  end
end

Krikri::KrikriJinjaFilters.register
