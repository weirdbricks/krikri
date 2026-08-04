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

      private def resolve_simple(name : String) : JSON::Any?
        @vars[name.strip]?
      end

      private def resolve_nested(expr : String) : JSON::Any?
        parts = expr.split(".")
        current = @vars[parts[0]]?
        return nil unless current

        parts[1..-1].each do |part|
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

      private def resolve_indexed(expr : String) : JSON::Any?
        match = expr.match(/^([^\[]+)\[([^\]]+)\]/)
        return nil unless match

        var_name = match[1].strip
        index_expr = match[2].strip

        var_value = @vars[var_name]?
        return nil unless var_value

        index = if index_expr.starts_with?("'") || index_expr.starts_with?('"')
                  index_expr[1..-2]
                else
                  index_expr.to_i? || index_expr
                end

        case var_value.raw
        when Array
          index.is_a?(Int32) ? var_value[index]? : nil
        when Hash
          var_value[index.to_s]?
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
