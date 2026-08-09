require "json"
require "time"
require "./variable_lookup"

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
      # Optional variable context, needed only to resolve a `default(...)`
      # filter's argument when it's itself a variable reference rather
      # than a literal (see the "default" case in #apply below) - every
      # other filter here is a pure JSON::Any -> JSON::Any transform with
      # no variable lookups of its own.
      def initialize(@vars : Hash(String, JSON::Any)? = nil)
      end

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
          undefined?(value) ? resolve_default_arg(filter_args) : value
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
        when "selectattr"
          # selectattr('mount', 'equalto', mount.path) - dev-sec
          # os_hardening's own way of picking a single ansible_facts.mounts
          # entry out by its `mount` field, then chained into `| list |
          # first`. Only equalto/eq/ne/defined/undefined are implemented -
          # every test this codebase's roles/specs actually use - an
          # unrecognized test name falls back to a `defined` check rather
          # than silently passing every item through unfiltered.
          apply_selectattr(value, filter_args)
        when "to_datetime"
          # to_datetime('%b %d, %Y') - dev-sec os_hardening's own
          # password-ageing verification parses `chage -l`'s date output
          # this way, then subtracts two of them for a day-count assert.
          # Real Ansible's default format (no argument) is
          # '%Y-%m-%d %H:%M:%S'. Represented as a tagged JSON object
          # (epoch seconds) rather than a native type FilterEngine has no
          # concept of - ExpressionEvaluator's `-` operator (ARC:
          # combine_minus) knows to recognize and subtract two of these
          # into a timedelta, itself tagged the same way so `.days`
          # dotted access on the result works via the ordinary Hash-key
          # path.
          parse_to_datetime(value, filter_args.strip.empty? ? "%Y-%m-%d %H:%M:%S" : parse_filter_arg(filter_args))
        when "combine"
          # combine(other1, other2, ...) - shallow dict merge, later
          # arguments win on key collisions. dev-sec os_hardening chains
          # several of these (`sysctl_config | combine(sysctl_custom_config
          # | default({})) | combine(...)`) to layer per-OS overrides on
          # top of role defaults; was previously entirely unimplemented
          # (fell through to the `else` passthrough below), silently
          # discarding every merge-in argument.
          split_top_level_args(filter_args).reduce(value) { |acc, arg_expr| combine_hash(acc, resolve_expression(arg_expr)) }
        else
          # Unknown filter - return value as-is (matches prior behavior)
          value
        end
      end

      DATETIME_TAG    = "__crystal_datetime__"
      TIMEDELTA_TAG   = "__crystal_timedelta__"

      private def parse_to_datetime(value : JSON::Any, format : String) : JSON::Any
        time = Time.parse(as_string(value), format, Time::Location::UTC) rescue nil
        return JSON::Any.new(nil) unless time
        JSON::Any.new({DATETIME_TAG => JSON::Any.new(time.to_unix.to_i64)})
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

      # `default(fallback)` or `default(fallback, boolean)` - real Jinja2's
      # second (boolean) form, used by dev-sec os_hardening's own
      # `mount.src | default(mountinfo.device, true)` to also treat an
      # empty string as needing the default (undefined? below already does
      # that unconditionally, so the boolean itself doesn't need reading -
      # its only job here is making sure it isn't swallowed into the first
      # argument's own text). Splits on the top-level comma first, THEN
      # resolves just the first argument - previously the whole
      # "mountinfo.device, true" string (comma and all) was handed
      # straight to parse_filter_arg, which had no notion of a second
      # argument and returned that entire literal text as the "default"
      # value instead of resolving `mountinfo.device` as the variable
      # reference it is.
      private def resolve_default_arg(args : String) : JSON::Any
        first_arg = split_top_level_args(args).first? || ""

        # `default(omit)` - real Ansible's magic variable that drops the
        # *parameter itself* from the module call rather than substituting
        # any real value (konstruktoid-hardening's "Allow outgoing
        # specified ports" task uses `proto: "{{ item.proto | default(omit)
        # }}"` to skip proto for loop items that don't specify one). `omit`
        # is a bare, unquoted identifier here - not a variable lookup - so
        # it's special-cased before falling into #resolve_expression, which
        # would otherwise treat it as an ordinary (undefined) variable
        # reference. See CrystalPlay::OMIT_SENTINEL for where this value is
        # consumed (#substitute_task_params strips the whole param).
        return JSON::Any.new(OMIT_SENTINEL) if first_arg.strip == "omit"

        resolve_expression(first_arg)
      end

      private def apply_selectattr(value : JSON::Any, args : String) : JSON::Any
        parts = split_top_level_args(args)
        attr = parts[0]?.try { |part| resolve_default_expression(part) }.try(&.as_s?)
        return value unless attr

        test = parts[1]?.try { |part| resolve_default_expression(part) }.try(&.as_s?) || "defined"
        compare_value = parts[2]?.try { |part| resolve_default_expression(part) }

        filtered = as_array(value).select { |item| selectattr_matches?(item, attr, test, compare_value) }
        JSON::Any.new(filtered)
      end

      private def selectattr_matches?(item : JSON::Any, attr : String, test : String, compare_value : JSON::Any?) : Bool
        attr_value = item.raw.is_a?(Hash) ? item[attr]? : nil

        case test
        when "equalto", "eq", "=="
          attr_value == compare_value
        when "ne", "!="
          attr_value != compare_value
        when "undefined"
          attr_value.nil?
        else
          !attr_value.nil?
        end
      end

      # A quoted string stays a string; `None` (Jinja/Python's null
      # literal, e.g. the "mountinfo" vars: default in the same task)
      # becomes JSON null; a purely-numeric argument is parsed as a number
      # so `x | default(0)` doesn't stringify to `"0"` for what should
      # stay numeric downstream (e.g. a following `+`-style comparison);
      # anything else is a variable reference (possibly dotted/indexed),
      # resolved against @vars the same way {{ }} substitution would -
      # falling back to the literal text only when no @vars context was
      # given at all (a caller that never needs this, e.g. a filter chain
      # evaluated with no variable scope) or the reference doesn't resolve.
      private def resolve_default_expression(expr : String) : JSON::Any
        expr = expr.strip

        # Jinja2's inline conditional expression (`'1' if COND else '0'`) -
        # dev-sec os_hardening's own dump:/passno: computation
        # (`default('1' if mount.fstype | default(mountinfo.fstype, true)
        # in ['ext3', 'ext4'] else '0', true)`) is written exactly this
        # way. Checked before the quoted-literal check below, which would
        # otherwise misparse the whole ternary as one big quoted string
        # (it starts with `'1'` and the false-branch ends with `'0'`, so
        # naive starts/ends-with-quote matching sees one string spanning
        # both).
        if ternary = split_ternary(expr)
          true_expr, condition, false_expr = ternary
          condition_true = ConditionalEvaluator.evaluate(condition, @vars || Hash(String, JSON::Any).new)
          return resolve_default_expression(condition_true ? true_expr : false_expr)
        end

        return JSON::Any.new(expr[1..-2]) if quoted_literal?(expr)
        return JSON::Any.new(nil) if expr == "None"

        if int_val = expr.to_i64?
          return JSON::Any.new(int_val)
        elsif float_val = expr.to_f64?
          return JSON::Any.new(float_val)
        end

        if (vars = @vars) && !expr.empty?
          VariableLookup.new(vars).resolve(expr) || JSON::Any.new(expr)
        else
          JSON::Any.new(expr)
        end
      end

      # Shallow dict merge for the `combine` filter: keys from *other* win
      # over *base* on collision, keys present in only one side pass
      # through unchanged. Non-Hash operands (a `combine` argument that
      # didn't resolve to a dict) are ignored rather than raising, since a
      # stray `default({})` fallback already guarantees an empty Hash in
      # the common case.
      private def combine_hash(base : JSON::Any, other : JSON::Any) : JSON::Any
        base_h = base.raw.is_a?(Hash) ? base.as_h : nil
        other_h = other.raw.is_a?(Hash) ? other.as_h : nil
        return base unless base_h
        return base unless other_h
        merged = base_h.dup
        other_h.each { |key, val| merged[key] = val }
        JSON::Any.new(merged)
      end

      # General single-expression resolver: unlike #resolve_default_expression
      # (which only ever sees a bare variable reference, quoted literal, or
      # ternary - `default`'s own argument grammar), this also understands
      # a `|`-chained filter pipeline and a `{...}` dict literal, both of
      # which show up as `combine`'s own arguments (`combine(sysctl_overwrite
      # | default({}))`).
      #
      # The ternary check MUST run before chain-splitting on the whole
      # expression: dev-sec os_hardening's own `dump:`/`passno:` computation
      # nests a filter chain inside the ternary's own condition (`'1' if
      # mount.fstype | default(mountinfo.fstype, true) in [...] else '0'`),
      # so that top-level `|` belongs to the condition, not to a pipeline
      # applied to the whole ternary. #split_chain has no notion of ternary
      # syntax and would otherwise cut the expression in half right at that
      # pipe, turning "'1' if mount.fstype" into a nonsense base expression
      # and silently discarding the "in [...] else '0'" tail - which is
      # exactly what happened when this used to split_chain first and only
      # checked for ternary inside #resolve_base_expression (too late to
      # matter, since the mis-split had already happened).
      private def resolve_expression(expr : String) : JSON::Any
        expr = expr.strip

        if ternary = split_ternary(expr)
          true_expr, condition, false_expr = ternary
          condition_true = ConditionalEvaluator.evaluate(condition, @vars || Hash(String, JSON::Any).new)
          return resolve_expression(condition_true ? true_expr : false_expr)
        end

        parts = self.class.split_chain(expr)
        return JSON::Any.new(nil) if parts.empty?
        parts[1..].reduce(resolve_base_expression(parts[0])) { |acc, filter_expr| apply(acc, filter_expr) }
      end

      private def resolve_base_expression(expr : String) : JSON::Any
        expr = expr.strip

        return JSON::Any.new(expr[1..-2]) if quoted_literal?(expr)
        return JSON::Any.new(nil) if expr == "None"
        return parse_dict_literal(expr) if expr.starts_with?('{') && expr.ends_with?('}')

        if int_val = expr.to_i64?
          return JSON::Any.new(int_val)
        elsif float_val = expr.to_f64?
          return JSON::Any.new(float_val)
        end

        if (vars = @vars) && !expr.empty?
          VariableLookup.new(vars).resolve(expr) || JSON::Any.new(nil)
        else
          JSON::Any.new(nil)
        end
      end

      # Parses a `{...}` dict literal (as seen in `default({})`/`combine({a:
      # 1})` arguments, not a real value already carried as JSON::Any) -
      # unquoted keys and single-quoted string values are both real Jinja2
      # dict-literal syntax that plain `JSON.parse` would reject.
      private def parse_dict_literal(expr : String) : JSON::Any
        inner = expr[1..-2].strip
        return JSON::Any.new({} of String => JSON::Any) if inner.empty?

        h = {} of String => JSON::Any
        split_top_level_args(inner).each do |pair|
          key_part, sep, val_part = pair.partition(':')
          next if sep.empty?
          key = key_part.strip.strip("'\"")
          h[key] = resolve_expression(val_part.strip)
        end
        JSON::Any.new(h)
      end

      private def quoted_literal?(expr : String) : Bool
        (expr.starts_with?("'") && expr.ends_with?("'")) ||
          (expr.starts_with?('"') && expr.ends_with?('"'))
      end

      # Finds a top-level (outside quotes/brackets) " if " ... " else "
      # pair and splits *expr* into {true_branch, condition, false_branch}
      # - nil if this isn't a ternary at all.
      private def split_ternary(expr : String) : {String, String, String}?
        depth = 0
        quote : Char? = nil
        if_pos = nil
        else_pos = nil

        i = 0
        while i < expr.size
          char = expr[i]
          if q = quote
            quote = nil if char == q
          elsif char == '\'' || char == '"'
            quote = char
          elsif char == '(' || char == '[' || char == '{'
            depth += 1
          elsif char == ')' || char == ']' || char == '}'
            depth -= 1
          elsif depth == 0
            if if_pos.nil? && expr[i..].starts_with?(" if ")
              if_pos = i
            elsif if_pos && else_pos.nil? && expr[i..].starts_with?(" else ")
              else_pos = i
            end
          end
          i += 1
        end

        return nil unless (start = if_pos) && (finish = else_pos)

        {expr[0...start].strip, expr[(start + 4)...finish].strip, expr[(finish + 6)..].strip}
      end

      # Splits a filter/test's parenthesized argument list on its
      # top-level commas (outside quotes and outside any nested
      # parens/brackets) WITHOUT stripping quotes from each segment - the
      # quoting itself is significant to callers like
      # resolve_default_expression (`'literal'` vs `variable_reference`),
      # unlike parse_filter_args' consumers, which want the quotes already
      # gone. Needed wherever a filter's own argument can itself contain a
      # nested filter call with its own comma
      # (`default('1' if x | default(y, true) in [...] else '0', true)` -
      # dev-sec os_hardening's dump:/passno: computation - the inner
      # `default(y, true)`'s comma must not split the outer call's args).
      private def split_top_level_args(args : String) : Array(String)
        parts = [] of String
        current = String::Builder.new
        depth = 0
        quote : Char? = nil

        args.each_char do |char|
          if q = quote
            current << char
            quote = nil if char == q
          elsif char == '\'' || char == '"'
            quote = char
            current << char
          elsif char == '(' || char == '[' || char == '{'
            depth += 1
            current << char
          elsif char == ')' || char == ']' || char == '}'
            depth -= 1
            current << char
          elsif char == ',' && depth == 0
            parts << current.to_s.strip
            current = String::Builder.new
          else
            current << char
          end
        end

        last = current.to_s
        parts << last.strip unless last.empty?
        parts
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
