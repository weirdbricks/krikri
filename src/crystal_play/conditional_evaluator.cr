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
        if (char == '"' || char == '\'') && (i == 0 || condition[i - 1] != '\\')
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

      # Dotted variable access (e.g. result.rc, stat_result.stat.exists) -
      # previously only the {{ }}-wrapped ComparisonEvaluator path
      # supported this; a bare when:/until:/changed_when:/failed_when:
      # condition referencing a dotted result field silently evaluated to
      # undefined (nil) instead of the real value. Guarded against float
      # literals ("1.5") also containing a "." - those aren't variable
      # paths, and the first segment of a real one ("result") won't itself
      # parse as a float.
      if expr.includes?(".") && !expr.to_f64?
        parts = expr.split(".")
        if vars.has_key?(parts[0])
          resolved = resolve_dotted(vars[parts[0]], parts[1..])
          return resolved ? json_any_to_value(resolved) : nil
        end
      end

      # Variable lookup
      if vars.has_key?(expr)
        json_any_to_value(vars[expr])
      else
        # Undefined variable - return nil
        nil
      end
    end

    # Navigates a dotted path through a JSON::Any Hash structure (e.g.
    # ["stat", "exists"] against {"stat" => {"exists" => true}}). Returns
    # nil if any segment is missing or the value at that point isn't a
    # Hash (arrays aren't indexed by name, so a dotted path into one is
    # always undefined here - array indexing uses [n], a separate,
    # already-supported path).
    private def self.resolve_dotted(current : JSON::Any, parts : Array(String)) : JSON::Any?
      parts.each do |part|
        return nil unless current.raw.is_a?(Hash)
        next_value = current[part]?
        return nil unless next_value
        current = next_value
      end
      current
    end

    # Converts a resolved JSON::Any into the same union evaluate_value
    # already returns for a bare variable lookup.
    private def self.json_any_to_value(value : JSON::Any) : String | Int64 | Bool | Nil | Array(String)
      case value.raw
      when String
        value.as_s
      when Int64, Int32
        value.as_i.to_i64
      when Float64
        value.as_f.to_s
      when Bool
        value.as_bool
      when Nil
        nil
      when Array
        value.as_a.map(&.to_s)
      else
        value.to_s
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
