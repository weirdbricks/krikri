require "json"

module CrystalPlay
  # ConditionalEvaluator - Evaluates Ansible when: conditions
  # Supports:
  # - Equality: ==, !=
  # - Comparison: <, >, <=, >=
  # - Boolean: and, or, not
  # - Membership: in
  # - Existence: is defined, is not defined
  # - Truthiness: bare variable names
  
  module ConditionalEvaluator
    # Evaluate a when: condition against a variable context
    # Returns true if condition passes, false otherwise
    def self.evaluate(condition : String, vars : Hash(String, JSON::Any)) : Bool
      # Strip whitespace
      condition = condition.strip
      
      # Handle 'not' at the beginning
      if condition.starts_with?("not ")
        return !evaluate(condition[4..-1].strip, vars)
      end
      
      # Handle 'and' operator (split and evaluate all parts)
      if condition.includes?(" and ")
        parts = split_by_operator(condition, " and ")
        return parts.all? { |part| evaluate(part.strip, vars) }
      end
      
      # Handle 'or' operator (split and evaluate any part)
      if condition.includes?(" or ")
        parts = split_by_operator(condition, " or ")
        return parts.any? { |part| evaluate(part.strip, vars) }
      end
      
      # Handle comparison operators
      if condition.includes?("==")
        return evaluate_comparison(condition, "==", vars)
      elsif condition.includes?("!=")
        return evaluate_comparison(condition, "!=", vars)
      elsif condition.includes?("<=")
        return evaluate_comparison(condition, "<=", vars)
      elsif condition.includes?(">=")
        return evaluate_comparison(condition, ">=", vars)
      elsif condition.includes?("<")
        return evaluate_comparison(condition, "<", vars)
      elsif condition.includes?(">")
        return evaluate_comparison(condition, ">", vars)
      end
      
      # Handle 'in' operator
      if condition.includes?(" in ")
        return evaluate_in(condition, vars)
      end
      
      # Handle 'is defined' / 'is not defined'
      if condition.includes?(" is defined")
        var_name = condition.gsub(" is defined", "").strip
        return vars.has_key?(var_name)
      elsif condition.includes?(" is not defined")
        var_name = condition.gsub(" is not defined", "").strip
        return !vars.has_key?(var_name)
      end
      
      # Handle bare variable (truthiness check)
      return evaluate_truthiness(condition, vars)
    end
    
    # Split condition by operator, respecting parentheses and quotes
    private def self.split_by_operator(condition : String, operator : String) : Array(String)
      parts = [] of String
      current = ""
      paren_depth = 0
      in_quotes = false
      quote_char = ' '
      i = 0
      
      while i < condition.size
        char = condition[i]
        
        # Track quotes
        if (char == '"' || char == '\'') && (i == 0 || condition[i-1] != '\\')
          if in_quotes && char == quote_char
            in_quotes = false
          elsif !in_quotes
            in_quotes = true
            quote_char = char
          end
        end
        
        # Track parentheses
        if !in_quotes
          if char == '('
            paren_depth += 1
          elsif char == ')'
            paren_depth -= 1
          end
        end
        
        # Check for operator
        if !in_quotes && paren_depth == 0
          if condition[i..-1].starts_with?(operator)
            parts << current.strip
            current = ""
            i += operator.size
            next
          end
        end
        
        current += char
        i += 1
      end
      
      parts << current.strip unless current.empty?
      parts
    end
    
    # Evaluate comparison operators
    private def self.evaluate_comparison(condition : String, operator : String, vars : Hash(String, JSON::Any)) : Bool
      parts = condition.split(operator, 2)
      return false if parts.size != 2
      
      left = evaluate_value(parts[0].strip, vars)
      right = evaluate_value(parts[1].strip, vars)
      
      case operator
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
    end
    
    # Evaluate 'in' operator
    private def self.evaluate_in(condition : String, vars : Hash(String, JSON::Any)) : Bool
      parts = condition.split(" in ", 2)
      return false if parts.size != 2
      
      item = evaluate_value(parts[0].strip, vars)
      container = evaluate_value(parts[1].strip, vars)
      
      # Check if item is in container (string or array)
      if container.is_a?(String)
        container.includes?(item.to_s)
      elsif container.is_a?(Array)
        container.includes?(item)
      else
        false
      end
    end
    
    # Evaluate truthiness of a value
    private def self.evaluate_truthiness(condition : String, vars : Hash(String, JSON::Any)) : Bool
      value = evaluate_value(condition, vars)
      
      case value
      when Bool
        value
      when String
        !value.empty? && value != "false" && value != "False"
      when Int32, Int64
        value != 0
      when Nil
        false
      else
        true
      end
    end
    
    # Evaluate a value (variable lookup or literal)
    private def self.evaluate_value(expr : String, vars : Hash(String, JSON::Any)) : String | Int64 | Bool | Nil | Array(String)
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
      
      # Handle arrays (simple list syntax)
      if expr.starts_with?('[') && expr.ends_with?(']')
        items = expr[1..-2].split(',').map(&.strip)
        return items.map { |item| 
          val = evaluate_value(item, vars)
          val.is_a?(String) ? val : val.to_s
        }
      end
      
      # Variable lookup
      if vars.has_key?(expr)
        value = vars[expr]
        case value.raw
        when String
          return value.as_s
        when Int64
          return value.as_i.to_i64
        when Int32
          return value.as_i.to_i64
        when Bool
          return value.as_bool
        when Nil
          return nil
        when Array
          return value.as_a.map(&.to_s)
        else
          return value.to_s
        end
      else
        # Undefined variable - return nil
        return nil
      end
    end
    
    # Compare two values (for <, >, <=, >=)
    private def self.compare_values(left : String | Int64 | Bool | Nil | Array(String), 
                                    right : String | Int64 | Bool | Nil | Array(String)) : Int32
      # Try numeric comparison first
      if left.is_a?(Int64) && right.is_a?(Int64)
        return left <=> right
      end
      
      # Try to parse as numbers
      if left_num = left.to_s.to_i64?
        if right_num = right.to_s.to_i64?
          return left_num <=> right_num
        end
      end
      
      # Fall back to string comparison
      left.to_s <=> right.to_s
    end
  end
end
