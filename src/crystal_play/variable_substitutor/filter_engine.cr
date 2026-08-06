require "json"

module CrystalPlay
  module VariableSubstitutor
    # FilterEngine - Applies Ansible/Jinja2-style filters to values.
    #
    # Operates on JSON::Any rather than String so a filter chain
    # (`{{ x | sort | join(',') }}`) can carry real array/hash structure
    # from one filter to the next - only the *final* result of the whole
    # chain gets stringified for template interpolation (by the caller, via
    # VariableLookup#format_value). Before this, the pipeline collapsed to a
    # String after every single filter and only ever split on the *first*
    # `|`, so `sort`'s own string-only output (`"[\"b\",\"a\"]"` as a JSON
    # string, not a real array) fed straight into `join`, which had no
    # array to actually join - chained filters were silently broken.
    class FilterEngine
      # Splits a `|`-joined filter chain into its individual filter
      # expressions, ignoring any `|` inside a quoted string or a
      # parenthesized argument list - `replace('a|b', 'c')` is one filter,
      # not two split on the `|` inside its own argument.
      def self.split_chain(expr : String) : Array(String)
        parts = [] of String
        current = String::Builder.new
        depth = 0
        quote : Char? = nil

        expr.each_char do |char|
          if q = quote
            current << char
            quote = nil if char == q
          elsif char == '\'' || char == '"'
            quote = char
            current << char
          elsif char == '('
            depth += 1
            current << char
          elsif char == ')'
            depth -= 1
            current << char
          elsif char == '|' && depth == 0
            parts << current.to_s.strip
            current = String::Builder.new
          else
            current << char
          end
        end
        parts << current.to_s.strip
        parts.reject(&.empty?)
      end

      # Applies a `|`-joined chain of filters to *value* in order.
      def apply_chain(value : JSON::Any, chain : String) : JSON::Any
        self.class.split_chain(chain).reduce(value) { |acc, filter_expr| apply(acc, filter_expr) }
      end

      # Apply a single filter to a value.
      # Example: myvar | default('value')
      def apply(value : JSON::Any, filter_expr : String) : JSON::Any
        if match = filter_expr.match(/^(\w+)\s*\((.*)\)$/m)
          filter_name = match[1]
          filter_args = match[2]
        else
          filter_name = filter_expr
          filter_args = ""
        end

        case filter_name
        when "default"
          undefined?(value) ? parse_default_arg(filter_args) : value
        when "upper"
          transform_string(value, &.upcase)
        when "lower"
          transform_string(value, &.downcase)
        when "capitalize"
          transform_string(value, &.capitalize)
        when "title"
          transform_string(value) { |text| text.split.map(&.capitalize).join(" ") }
        when "trim", "strip"
          transform_string(value, &.strip)
        when "length", "count"
          JSON::Any.new(length_of(value).to_i64)
        when "replace"
          args = parse_filter_args(filter_args)
          transform_string(value) { |text| args.size >= 2 ? text.gsub(args[0], args[1]) : text }
        when "split"
          delimiter = parse_filter_arg(filter_args)
          parts = as_string(value).split(delimiter).map { |part| JSON::Any.new(part) }
          JSON::Any.new(parts)
        when "sort"
          JSON::Any.new(sort_json(as_array(value)))
        when "unique"
          seen = Set(String).new
          JSON::Any.new(as_array(value).select { |item| seen.add?(item.to_json) })
        when "reverse"
          case value.raw
          when Array
            JSON::Any.new(value.as_a.reverse)
          when String
            JSON::Any.new(value.as_s.reverse)
          else
            value
          end
        when "join"
          sep = filter_args.strip.empty? ? "" : parse_filter_arg(filter_args)
          JSON::Any.new(as_array(value).map { |v| as_string(v) }.join(sep))
        when "list"
          value
        when "first"
          as_array(value).first? || JSON::Any.new(nil)
        when "last"
          as_array(value).last? || JSON::Any.new(nil)
        when "min"
          as_array(value).min_by? { |v| numeric(v) } || JSON::Any.new(nil)
        when "max"
          as_array(value).max_by? { |v| numeric(v) } || JSON::Any.new(nil)
        when "int"
          JSON::Any.new(as_string(value).to_i64? || 0_i64)
        when "float"
          JSON::Any.new(as_string(value).to_f64? || 0.0)
        when "string"
          JSON::Any.new(as_string(value))
        when "bool"
          JSON::Any.new(truthy?(value))
        when "abs"
          JSON::Any.new(numeric(value).abs)
        when "map"
          # map(attribute='x') - real Jinja2's map() also has a
          # filter-name form (`list | map('upper')`); only the attribute=
          # form is implemented, since that's the one real playbooks
          # combine with stat:/find:'s own dict-list output (real Ansible
          # docs: "see stat module for full output of each dictionary").
          if attr = parse_kwarg(filter_args, "attribute")
            JSON::Any.new(as_array(value).map { |item| item.raw.is_a?(Hash) ? (item[attr]? || JSON::Any.new(nil)) : JSON::Any.new(nil) })
          else
            value
          end
        else
          # Unknown filter - return value as-is (matches prior behavior)
          value
        end
      end

      private def undefined?(value : JSON::Any) : Bool
        case value.raw
        when Nil
          true
        when String
          value.as_s.empty?
        else
          false
        end
      end

      # `default('fallback')`'s argument: a quoted string stays a string;
      # an unquoted, purely-numeric argument is parsed as a number so
      # `x | default(0)` doesn't stringify to `"0"` for what should stay
      # numeric downstream (e.g. a following `+`-style comparison).
      private def parse_default_arg(args : String) : JSON::Any
        raw = parse_filter_arg(args)
        was_quoted = args.strip.starts_with?("'") || args.strip.starts_with?('"')
        return JSON::Any.new(raw) if was_quoted

        if int_val = raw.to_i64?
          JSON::Any.new(int_val)
        elsif float_val = raw.to_f64?
          JSON::Any.new(float_val)
        else
          JSON::Any.new(raw)
        end
      end

      private def transform_string(value : JSON::Any, & : String -> String) : JSON::Any
        JSON::Any.new(yield as_string(value))
      end

      private def length_of(value : JSON::Any) : Int32
        case value.raw
        when Array
          value.as_a.size
        when Hash
          value.as_h.size
        when String
          value.as_s.size
        when Nil
          0
        else
          as_string(value).size
        end
      end

      private def as_array(value : JSON::Any) : Array(JSON::Any)
        value.as_a? || [] of JSON::Any
      end

      # Stringifies a JSON::Any the way Ansible/Jinja2 would when a filter
      # needs to treat it as text (e.g. join's own elements, replace's own
      # input) - booleans render capitalized (`True`/`False`), matching
      # VariableLookup#format_value's own convention for template
      # interpolation, since a filter's own string output ultimately feeds
      # back into the same template text either way.
      private def as_string(value : JSON::Any) : String
        case value.raw
        when String
          value.as_s
        when Int64, Int32
          value.as_i64.to_s
        when Float64
          value.as_f.to_s
        when Bool
          value.as_bool ? "True" : "False"
        when Nil
          ""
        when Array, Hash
          value.to_json
        else
          value.to_s
        end
      end

      private def numeric(value : JSON::Any) : Float64
        case value.raw
        when Int64, Int32
          value.as_i64.to_f64
        when Float64
          value.as_f
        else
          as_string(value).to_f64? || 0.0
        end
      end

      private def truthy?(value : JSON::Any) : Bool
        case value.raw
        when Nil
          false
        when Bool
          value.as_bool
        when String
          !value.as_s.empty? && value.as_s != "0" && value.as_s.downcase != "false"
        when Int64, Int32
          value.as_i64 != 0
        when Float64
          value.as_f != 0.0
        when Array
          !value.as_a.empty?
        when Hash
          !value.as_h.empty?
        else
          true
        end
      end

      # Decorate-sort-undecorate. This replaced a `sort { compare_json(l,
      # r) }` whose comparator stringified *and* attempted a Float64 parse
      # of both operands on every comparison, so an n-element list did
      # O(n log n) of both over the same values; computing each element's
      # key once makes that O(n).
      #
      # The numeric-vs-lexicographic decision is now made once for the
      # whole list rather than per pair. For a homogeneous list - every
      # element numeric, or none - that is exactly the old ordering. It
      # differs only for a *mixed* list, where the old per-pair rule
      # compared some pairs numerically and others lexicographically:
      # an intransitive comparator whose result was already arbitrary.
      private def sort_json(items : Array(JSON::Any)) : Array(JSON::Any)
        keys = items.map { |item| as_string(item) }

        if keys.all?(&.to_f64?)
          items.map_with_index { |item, index| {keys[index].to_f64, item} }
            .sort! { |left, right| left[0] <=> right[0] }
            .map { |pair| pair[1] }
        else
          items.map_with_index { |item, index| {keys[index], item} }
            .sort! { |left, right| left[0] <=> right[0] }
            .map { |pair| pair[1] }
        end
      end

      # Parses `name='value'`/`name="value"` out of a filter's argument
      # list - only what `map(attribute=...)` needs, not general keyword
      # argument parsing.
      private def parse_kwarg(args : String, name : String) : String?
        if match = args.match(/#{name}\s*=\s*(['"])(.*?)\1/)
          match[2]
        end
      end

      # Parse a single filter argument (remove quotes)
      private def parse_filter_arg(arg : String) : String
        arg = arg.strip
        if arg.starts_with?("'") && arg.ends_with?("'")
          arg[1..-2]
        elsif arg.starts_with?('"') && arg.ends_with?('"')
          arg[1..-2]
        else
          arg
        end
      end

      # Parse multiple filter arguments
      private def parse_filter_args(args : String) : Array(String)
        # Simple parser - split by comma, handle quotes
        result = [] of String
        # String::Builder rather than `current += char`, which allocates a
        # whole new String per character (O(n^2) in the argument length) -
        # the same accumulator fix already applied to
        # ConditionalEvaluator.split_by_operator, and the same shape
        # #split_chain above already uses.
        current = String::Builder.new
        in_quotes = false
        quote_char = ' '

        args.each_char do |char|
          case char
          when '\'', '"'
            if in_quotes && char == quote_char
              in_quotes = false
            elsif !in_quotes
              in_quotes = true
              quote_char = char
            else
              current << char
            end
          when ','
            if in_quotes
              current << char
            else
              result << current.to_s.strip
              current = String::Builder.new
            end
          else
            current << char
          end
        end

        # Emptiness is tested on the *unstripped* accumulator, as before:
        # a trailing whitespace-only segment still contributes an empty
        # argument rather than being dropped.
        last = current.to_s
        result << last.strip unless last.empty?
        result.map { |arg| parse_filter_arg(arg) }
      end
    end
  end
end
