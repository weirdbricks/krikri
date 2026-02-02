require "json"

module CrystalPlay
  module VariableSubstitutor
    # ComparisonEvaluator - Handles boolean comparison expressions
    # Supports: ==, !=, <, >, <=, >=
    class ComparisonEvaluator
      @vars : Hash(String, JSON::Any)
      
      def initialize(@vars : Hash(String, JSON::Any))
      end
      
      # Evaluate a comparison expression
      # Example: ssl_check.rc == 0, count > 5
      def evaluate(expr : String) : String
        # Try operators in order (longest first to avoid false matches)
        operators = ["==", "!=", "<=", ">=", ">", "<"]
        
        operators.each do |op|
          if expr.includes?(op)
            parts = expr.split(op, 2)
            next if parts.size != 2
            
            left = evaluate_simple_value(parts[0].strip)
            right = evaluate_simple_value(parts[1].strip)
            
            result = case op
            when "=="
              left == right
            when "!="
              left != right
            when "<"
              compare_values(left, right) < 0
            when ">"
              compare_values(left, right) > 0
            when "<="
              compare_values(left, right) <= 0
            when ">="
              compare_values(left, right) >= 0
            else
              false
            end
            
            return result.to_s
          end
        end
        
        "false"
      end
      
      # Evaluate a simple value (literal or variable reference)
      def evaluate_simple_value(expr : String) : String | Int64 | Bool | Nil
        expr = expr.strip
        
        # Handle quoted strings
        if (expr.starts_with?('"') && expr.ends_with?('"')) || 
           (expr.starts_with?('\'') && expr.ends_with?('\''))
          return expr[1..-2]
        end
        
        # Handle booleans
        if expr == "true" || expr == "True"
          return true
        elsif expr == "false" || expr == "False"
          return false
        end
        
        # Handle numbers
        if int_val = expr.to_i64?
          return int_val
        end
        
        # Handle nested variable access (e.g., result.rc)
        if expr.includes?(".")
          value_str = lookup_nested_variable(expr)
          # Try to parse as number
          if int_val = value_str.to_i64?
            return int_val
          end
          return value_str
        end
        
        # Simple variable lookup
        lookup_simple_variable(expr)
      end
      
      # Compare two values intelligently
      private def compare_values(left : String | Int64 | Bool | Nil, 
                                  right : String | Int64 | Bool | Nil) : Int32
        # Try numeric comparison first
        if left.is_a?(Int64) && right.is_a?(Int64)
          return left <=> right
        end
        
        # Try to parse as integers
        if left_int = left.to_s.to_i64?
          if right_int = right.to_s.to_i64?
            return left_int <=> right_int
          end
        end
        
        # Try to parse as floats
        if left_float = left.to_s.to_f64?
          if right_float = right.to_s.to_f64?
            comparison = left_float <=> right_float
            return comparison if comparison
          end
        end
        
        # Fall back to string comparison
        left.to_s <=> right.to_s
      end
      
      # Look up a simple variable
      private def lookup_simple_variable(name : String) : String | Int64 | Bool | Nil
        name = name.strip
        
        if @vars.has_key?(name)
          value = @vars[name]
          case value.raw
          when String
            return value.as_s.strip
          when Int64
            return value.as_i
          when Bool
            return value.as_bool
          when Nil
            return nil
          else
            return value.to_s
          end
        end
        
        nil
      end
      
      # Look up a nested variable (e.g., result.rc)
      private def lookup_nested_variable(expr : String) : String
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
        
        current.to_s
      end
    end
  end
end
