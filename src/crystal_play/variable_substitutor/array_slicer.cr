require "json"

module CrystalPlay
  module VariableSubstitutor
    # ArraySlicer - Handles Python-style array slicing
    # Supports: array[:5], array[2:], array[1:3], array[-3:], array[:-2]
    # NOW SUPPORTS NESTED VARIABLES: result.stdout_lines[:5]
    class ArraySlicer
      @vars : Hash(String, JSON::Any)
      
      def initialize(@vars : Hash(String, JSON::Any))
      end
      
      # Evaluate array slicing expression
      # Example: numbers.stdout_lines[:5]
      def slice(expr : String) : String
        STDERR.puts "\n=== ArraySlicer.slice called ==="
        STDERR.puts "Expression: #{expr}"
        STDERR.puts "Available vars: #{@vars.keys.join(", ")}"
        
        # Match pattern: variable[start:end]
        if match = expr.match(/^([^\[]+)\[([^:]*):([^\]]*)\]/)
          var_name = match[1].strip
          start_str = match[2].strip
          end_str = match[3].strip
          
          STDERR.puts "Parsed: var_name='#{var_name}', start='#{start_str}', end='#{end_str}'"
          
          # Look up the variable (handle nested access like result.stdout_lines)
          var_value = if var_name.includes?(".")
            STDERR.puts "Using nested lookup for '#{var_name}'"
            lookup_nested_variable(var_name)
          else
            STDERR.puts "Using simple lookup for '#{var_name}'"
            @vars[var_name]?
          end
          
          if var_value.nil?
            STDERR.puts "ERROR: Variable not found!"
            STDERR.puts "=== End ArraySlicer.slice ===\n"
            return "undefined"
          end
          
          STDERR.puts "Found variable, type: #{var_value.raw.class}"
          
          # Must be an array
          unless var_value.as_a?
            STDERR.puts "ERROR: Variable is not an array!"
            STDERR.puts "=== End ArraySlicer.slice ===\n"
            return "undefined"
          end
          
          array = var_value.as_a
          array_size = array.size
          
          STDERR.puts "Array size: #{array_size}"
          
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
          
          STDERR.puts "Slice range: [#{start_idx}...#{end_idx}]"
          
          # Make sure start <= end
          if start_idx >= end_idx || start_idx >= array_size
            STDERR.puts "ERROR: Invalid slice range"
            STDERR.puts "=== End ArraySlicer.slice ===\n"
            return "[]"
          end
          
          # Slice the array
          sliced = array[start_idx...end_idx]
          
          STDERR.puts "Sliced #{sliced.size} elements"
          
          # Format as JSON array
          sliced_strings = sliced.map { |item| 
            case item.raw
            when String
              item.as_s
            else
              item.to_s
            end
          }
          
          result = sliced_strings.to_json
          STDERR.puts "Result: #{result}"
          STDERR.puts "=== End ArraySlicer.slice ===\n"
          
          # Return as JSON array
          result
        else
          STDERR.puts "ERROR: Pattern did not match!"
          STDERR.puts "=== End ArraySlicer.slice ===\n"
          "undefined"
        end
      end
      
      # Look up a nested variable (e.g., result.stdout_lines)
      private def lookup_nested_variable(expr : String) : JSON::Any?
        parts = expr.split(".")
        STDERR.puts "  Looking up nested: #{parts.inspect}"
        
        current = @vars[parts[0]]?
        
        unless current
          STDERR.puts "  First part '#{parts[0]}' not found"
          return nil
        end
        
        STDERR.puts "  Found first part, navigating..."
        
        # Navigate through nested structure
        parts[1..-1].each do |part|
          STDERR.puts "  Looking for '#{part}' in #{current.raw.class}"
          case current.raw
          when Hash
            current = current[part]?
            unless current
              STDERR.puts "  Part '#{part}' not found in hash"
              return nil
            end
          else
            STDERR.puts "  Current is not a hash, cannot navigate"
            return nil
          end
        end
        
        STDERR.puts "  Successfully navigated to final value"
        current
      end
    end
  end
end
