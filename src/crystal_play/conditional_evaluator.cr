require "json"
require "./variable_substitutor/filter_engine"

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
    # *condition[i..-1].starts_with?(operator)* allocated a full
    # substring of the remaining condition on every character, and
    # *current += char* reallocated the accumulator on every character -
    # together an O(n^2) scan. Bounded per-char operator comparison (no
    # allocation) plus a String::Builder accumulator, matching the shape
    # FilterEngine.split_chain already uses for the same kind of
    # depth/quote-aware scan.
    private def self.operator_at?(condition : String, index : Int32, operator : String) : Bool
      return false if index + operator.size > condition.size

      operator.each_char.with_index do |operator_char, offset|
        return false unless condition[index + offset] == operator_char
      end
      true
    end

    private def self.split_by_operator(condition : String, operator : String) : Array(String)
      parts = [] of String
      current = String::Builder.new
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
          if operator_at?(condition, i, operator)
            parts << current.to_s.strip
            current = String::Builder.new
            i += operator.size
            next
          end
        end

        current << char
        i += 1
      end

      final = current.to_s.strip
      parts << final unless final.empty?
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

      # Handle a filter chain (`mylist | length > 0`, or a bare
      # `when: mylist | length` truthiness check) - previously this
      # module had no concept of `|` at all, so any when:/assert: that:/
      # until:/changed_when:/failed_when: condition combining a filter
      # with a comparison (or used bare) always evaluated the filter
      # chain text itself as an undefined variable name. Reuses
      # FilterEngine.split_chain (respects `|` inside a quoted filter
      # argument or a parenthesized arg list) and the same filter
      # implementations {{ }} substitution already uses, rather than a
      # third reimplementation.
      if expr.includes?("|")
        segments = VariableSubstitutor::FilterEngine.split_chain(expr)
        head = resolve_json(segments[0], vars) || JSON::Any.new(nil)
        filter = VariableSubstitutor::FilterEngine.new
        result = segments[1..].reduce(head) { |acc, filter_expr| filter.apply(acc, filter_expr) }
        return json_any_to_value(result)
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

    # Resolves a simple or dotted expression (the head of a filter chain,
    # e.g. "mylist" or "result.stdout" in "result.stdout | trim") to its
    # raw JSON::Any value, reusing resolve_dotted below - an empty
    # remainder (a non-dotted expr) just returns the looked-up value
    # unchanged.
    private def self.resolve_json(expr : String, vars : Hash(String, JSON::Any)) : JSON::Any?
      expr = expr.strip
      parts = expr.split(".")
      return nil unless vars.has_key?(parts[0])
      resolve_dotted(vars[parts[0]], parts[1..])
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
