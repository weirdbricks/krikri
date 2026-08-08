require "json"

module CrystalPlay
  module VariableSubstitutor
    # VariableLookup - Handles all forms of variable access
    # - Simple: {{ myvar }}
    # - Nested: {{ user.name.first }}
    # - Indexed: {{ array[0] }}, {{ dict['key'] }}
    class VariableLookup
      @vars : Hash(String, JSON::Any)

      def initialize(@vars : Hash(String, JSON::Any))
      end

      # Simple variable lookup
      def simple(name : String) : String
        resolve_simple(name).try { |v| format_value(v) } || "undefined"
      end

      # Nested variable access
      # Example: user.name, config.database.host
      def nested(expr : String) : String
        resolve_nested(expr).try { |v| format_value(v) } || "undefined"
      end

      # Indexed access (array or hash)
      # Example: mylist[0], mydict['key']
      def indexed(expr : String) : String
        resolve_indexed(expr).try { |v| format_value(v) } || "undefined"
      end

      # Resolves any of the three access forms above to its raw JSON::Any
      # value (nil if undefined) rather than a pre-stringified String - used
      # by FilterEngine so a filter chain (`{{ x | sort | join(',') }}`) can
      # carry real array/hash structure from one filter to the next instead
      # of collapsing to a string after every single filter.
      def resolve(expr : String) : JSON::Any?
        expr = expr.strip
        if expr.includes?("[")
          resolve_indexed(expr)
        elsif expr.includes?(".")
          resolve_nested(expr)
        else
          resolve_simple(expr)
        end
      end

      # Walks a dotted/indexed suffix (`.stat.exists`, "[0].name",
      # ".days") against an already-resolved value, for a caller that
      # computed the base value itself (ExpressionEvaluator's
      # parenthesized-sub-expression handling: `( a - b ).days` needs to
      # look `.days` up on the *result* of `a - b`, not on some variable
      # named "( a - b )") rather than looking it up from @vars the way
      # resolve/resolve_indexed/resolve_nested always do. An empty suffix
      # returns *start* unchanged.
      def walk(start : JSON::Any, suffix : String) : JSON::Any?
        current = start
        pos = 0

        while pos < suffix.size
          return nil unless current

          case suffix[pos]
          when '.'
            pos += 1
            dot_start = pos
            while pos < suffix.size && suffix[pos] != '.' && suffix[pos] != '['
              pos += 1
            end
            part = suffix[dot_start...pos]
            current = hash_method_call(current, part) || (current.raw.is_a?(Hash) ? current[part]? : nil)
          when '['
            close = suffix.index(']', pos)
            return nil unless close
            current = index_into(current, resolve_index_key(suffix[(pos + 1)...close]))
            pos = close + 1
          else
            return nil
          end
        end

        current
      end

      private def resolve_simple(name : String) : JSON::Any?
        @vars[name.strip]?
      end

      private def resolve_nested(expr : String) : JSON::Any?
        parts = expr.split(".")
        current = @vars[parts[0]]?
        return nil unless current

        parts[1..-1].each do |part|
          dict_method = hash_method_call(current, part)
          if dict_method
            current = dict_method
            next
          end

          case current.raw
          when Hash
            current = current[part]?
            return nil unless current
          else
            return nil
          end
        end

        current
      end

      # Jinja2/Python dict method-call syntax (`.keys()`, `.values()`,
      # `.items()`) on a Hash - dev-sec os_hardening's own
      # `ansible_facts.getent_passwd.keys() | list` (building the
      # system/regular/root account lists every user-management task in
      # that role loops over) is written exactly this way. Previously
      # unrecognized as anything other than a literal (nonexistent) hash
      # key "keys()", silently resolving to undefined and turning that
      # loop into a single bogus iteration.
      private def hash_method_call(current : JSON::Any, part : String) : JSON::Any?
        return nil unless current.raw.is_a?(Hash)
        hash = current.as_h

        case part
        when "keys()"
          JSON::Any.new(hash.keys.map { |key| JSON::Any.new(key) })
        when "values()"
          JSON::Any.new(hash.values)
        when "items()"
          JSON::Any.new(hash.map { |key, value| JSON::Any.new([JSON::Any.new(key), value]) })
        end
      end

      # Handles a base expression (a bare name or a dotted path) followed
      # by one or more `[...]` index accessors, chained left to right -
      # `mylist[0]`, `mydict['key']`, and also `ansible_facts.getent_passwd
      # [item][4]` (a dotted base, indexed by a *variable's* value, itself
      # further indexed into the resulting list) - a shape dev-sec
      # os_hardening's own user-account tasks use to pull a getent_passwd
      # entry's home-dir field. Previously only a single bracket directly
      # on a bare name was supported, and even then the index itself was
      # never resolved as a variable reference (`list[item]` looked up the
      # literal key "item", not item's value).
      private def resolve_indexed(expr : String) : JSON::Any?
        base_end = expr.index('[')
        return nil unless base_end

        base_expr = expr[0...base_end].strip
        return nil if base_expr.empty?

        current = base_expr.includes?('.') ? resolve_nested(base_expr) : resolve_simple(base_expr)

        expr[base_end..].scan(/\[([^\]]+)\]/) do |match|
          return nil unless current
          current = index_into(current, resolve_index_key(match[1].strip))
        end

        current
      end

      # A `[...]` index's inner text: a quoted string literal, an integer
      # literal, or a bare identifier - the last resolved as a variable
      # reference (`list[item]`) rather than used as a literal key, since
      # that's how every real playbook writes a variable-indexed lookup.
      private def resolve_index_key(index_expr : String) : String | Int32
        if (index_expr.starts_with?('\'') && index_expr.ends_with?('\'')) ||
           (index_expr.starts_with?('"') && index_expr.ends_with?('"'))
          return index_expr[1..-2]
        end
        return index_expr.to_i if index_expr.to_i?

        resolved = resolve_simple(index_expr) || resolve_nested(index_expr)
        case raw = resolved.try(&.raw)
        when String      then raw
        when Int64, Int32 then raw.to_i
        else                   index_expr
        end
      end

      private def index_into(current : JSON::Any, key : String | Int32) : JSON::Any?
        case current.raw
        when Array
          idx = key.is_a?(Int32) ? key : key.to_i?
          idx ? current[idx]? : nil
        when Hash
          current[key.to_s]?
        else
          nil
        end
      end

      # Renders a variable's value the way Ansible/Jinja2 does when it's
      # interpolated directly into template text - notably, Python's
      # capitalized True/False for booleans, not Crystal's lowercase
      # true/false (verified against real ansible-playbook: a `{{ boolvar }}`
      # in a copy/template content string renders "True"/"False"). Public
      # (not just used internally) so FilterEngine's caller can render a
      # filter chain's final JSON::Any result the same way a plain variable
      # lookup would be.
      def format_value(value : JSON::Any) : String
        case value.raw
        when String
          # Strip whitespace from string values (matches Ansible behavior)
          # This prevents issues with trailing newlines from command output
          value.as_s.strip
        when Int64, Int32
          value.as_i.to_s
        when Float64
          value.as_f.to_s
        when Bool
          value.as_bool ? "True" : "False"
        when Array
          value.to_json
        when Hash
          value.to_json
        when Nil
          ""
        else
          value.to_s
        end
      end
    end
  end
end
