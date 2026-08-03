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
        name = name.strip

        # Check if variable exists
        if @vars.has_key?(name)
          format_value(@vars[name])
        else
          # Return undefined marker (will be handled by filters)
          "undefined"
        end
      end

      # Nested variable access
      # Example: user.name, config.database.host
      def nested(expr : String) : String
        parts = expr.split(".")
        current = @vars[parts[0]]?

        return "undefined" unless current

        # Navigate through nested structure
        parts[1..-1].each do |part|
          case current.raw
          when Hash
            current = current[part]?
            return "undefined" unless current
          else
            return "undefined"
          end
        end

        format_value(current)
      end

      # Indexed access (array or hash)
      # Example: mylist[0], mydict['key']
      def indexed(expr : String) : String
        # Match pattern: varname[index]
        if match = expr.match(/^([^\[]+)\[([^\]]+)\]/)
          var_name = match[1].strip
          index_expr = match[2].strip

          # Look up the variable
          var_value = @vars[var_name]?
          return "undefined" unless var_value

          # Parse index (could be number or string)
          index = if index_expr.starts_with?("'") || index_expr.starts_with?('"')
                    # Remove quotes
                    index_expr[1..-2]
                  else
                    index_expr.to_i? || index_expr
                  end

          # Access the value
          case var_value.raw
          when Array
            var_value[index.as(Int32)]?.try { |v| format_value(v) } || "undefined"
          when Hash
            var_value[index.to_s]?.try { |v| format_value(v) } || "undefined"
          else
            "undefined"
          end
        else
          "undefined"
        end
      end

      # Renders a variable's value the way Ansible/Jinja2 does when it's
      # interpolated directly into template text - notably, Python's
      # capitalized True/False for booleans, not Crystal's lowercase
      # true/false (verified against real ansible-playbook: a `{{ boolvar }}`
      # in a copy/template content string renders "True"/"False").
      private def format_value(value : JSON::Any) : String
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
