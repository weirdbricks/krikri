require "json"

module CrystalPlay
  module VariableSubstitutor
    # ArraySlicer - Handles Python-style array slicing
    # Supports: array[:5], array[2:], array[1:3], array[-3:], array[:-2]
    # NOW SUPPORTS NESTED VARIABLES: result.stdout_lines[:5]
    class ArraySlicer
      REGEX_SLICE = /^([^\[]+)\[([^:]*):([^\]]*)\]/

      @vars : Hash(String, JSON::Any)

      def initialize(@vars : Hash(String, JSON::Any))
      end

      # Evaluate array slicing expression
      # Example: numbers.stdout_lines[:5]
      def slice(expr : String) : String
        # Match pattern: variable[start:end]
        if match = expr.match(REGEX_SLICE)
          var_name = match[1].strip
          start_str = match[2].strip
          end_str = match[3].strip

          # Look up the variable (handle nested access like result.stdout_lines)
          var_value = if var_name.includes?(".")
                        lookup_nested_variable(var_name)
                      else
                        @vars[var_name]?
                      end

          if var_value.nil?
            return "undefined"
          end

          # Must be an array
          unless var_value.as_a?
            return "undefined"
          end

          array = var_value.as_a
          array_size = array.size

          # Parse start index (empty means 0)
          start_idx = if start_str.empty?
                        0
                      else
                        start_str.to_i? || 0
                      end

          # Handle negative indices
          start_idx = array_size + start_idx if start_idx < 0
          start_idx = 0 if start_idx < 0

          # Parse end index (empty means array.size)
          end_idx = if end_str.empty?
                      array_size
                    else
                      end_str.to_i? || array_size
                    end

          # Handle negative indices
          end_idx = array_size + end_idx if end_idx < 0
          end_idx = array_size if end_idx > array_size

          # Make sure start <= end
          if start_idx >= end_idx || start_idx >= array_size
            return "[]"
          end

          # Slice the array
          sliced = array[start_idx...end_idx]

          # Format as JSON array
          sliced_strings = sliced.map { |item|
            case item.raw
            when String
              item.as_s
            else
              item.to_s
            end
          }

          # Return as JSON array
          sliced_strings.to_json
        else
          "undefined"
        end
      end

      # Look up a nested variable (e.g., result.stdout_lines)
      private def lookup_nested_variable(expr : String) : JSON::Any?
        parts = expr.split(".")

        current = @vars[parts[0]]?

        unless current
          return nil
        end

        # Navigate through nested structure
        parts[1..-1].each do |part|
          case current.raw
          when Hash
            current = current[part]?
            unless current
              return nil
            end
          else
            return nil
          end
        end

        current
      end
    end
  end
end
