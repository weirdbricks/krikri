require "json"
require "./filter_engine"

module CrystalPlay
  module VariableSubstitutor
    # ComparisonEvaluator - Handles boolean comparison expressions
    # Supports: ==, !=, <, >, <=, >=
    class ComparisonEvaluator
      @vars : Hash(String, JSON::Any)
      @filter : FilterEngine

      def initialize(@vars : Hash(String, JSON::Any))
        @filter = FilterEngine.new(@vars)
      end

      # Audit pass (2026-08-11, following the ansible-vault/prometheus/
      # grafana rounds finding 5 independent copies of this exact bug):
      # re-renders *value* if it's still a String containing `{{` - real
      # Ansible's recursive re-templating applied to whatever a plain-
      # lookup fallback already resolved, rather than duplicating the
      # "strip one {{ }} layer and re-run through ExpressionEvaluator"
      # logic at each call site in this class.
      private def rerender_if_templated(value : JSON::Any) : JSON::Any
        return value unless (raw = value.raw).is_a?(String) && raw.includes?("{{")

        inner = raw.strip
        inner = inner[2..-3].strip if inner.starts_with?("{{") && inner.ends_with?("}}")
        rendered = VariableSubstitutor::ExpressionEvaluator.new(@vars).evaluate(inner)
        (JSON.parse(rendered) rescue nil) || JSON::Any.new(rendered)
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
              values_equal?(left, right)
            when "!="
              !values_equal?(left, right)
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

        # A filter chain or parenthesized sub-expression used as a
        # comparison operand (`mylist | length > 0`, `result.stdout |
        # trim == "ok"`, `(expiry.stdout | trim) == '7'` - dev-sec
        # os_hardening's own password-ageing verification, inside a {{ }}
        # rather than a bare when:/assert:) - `evaluate` above checks for
        # a comparison operator before ever checking `|`/`(`, so an
        # expression combining both always routed here with the operand
        # text still attached, which then failed as an ordinary (and
        # undefined) variable lookup. Delegates to a fresh
        # ExpressionEvaluator - the operand text here never contains a
        # comparison operator itself (evaluate already split those off),
        # so this can't recurse back into ComparisonEvaluator. The same
        # delegation ConditionalEvaluator uses for bare when:/assert:
        # conditions, needed here too since {{ }}-wrapped comparisons
        # reach this separate evaluator instead.
        # `~` (Jinja2 string concat) alongside the filter/paren cases
        # already delegated here - a comparison operand built with it
        # (`installed.stdout != vault_version~('+ent' if vault_enterprise)`
        # - ansible-community.ansible-vault's own version-check) has no
        # `|` and doesn't start with `(`, so it fell through everywhere
        # below to a plain variable lookup on the whole literal operand
        # text, always undefined/never equal.
        if expr.includes?("|") || expr.starts_with?('(') || expr.includes?("~")
          rendered = ExpressionEvaluator.new(@vars).evaluate(expr)
          parsed = (JSON.parse(rendered) rescue nil)
          return json_any_to_value(parsed || JSON::Any.new(rendered))
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
      
      # `==`/`!=`: a raw match first (handles Bool/Nil, and same-type
      # values that already match), then a numeric-string fallback - a
      # value that went through a filter chain/parenthesized
      # sub-expression (dev-sec os_hardening's own `(expiry_warndays.stdout
      # | trim) == '7'`) may come back as a real Int64 while the other
      # side is a quoted string literal (or vice versa) purely as an
      # artifact of this codebase's string-heavy evaluation pipeline, not
      # because the two values are actually different - "7" and 7 should
      # compare equal here the same way compare_values already treats
      # them for `<`/`>`/etc, just applied to `==`/`!=` too.
      private def values_equal?(left : String | Int64 | Bool | Nil, right : String | Int64 | Bool | Nil) : Bool
        return true if left == right

        left_num = numeric_or_nil(left)
        right_num = numeric_or_nil(right)
        !left_num.nil? && !right_num.nil? && left_num == right_num
      end

      private def numeric_or_nil(value : String | Int64 | Bool | Nil) : Float64?
        case value
        when Int64  then value.to_f64
        when String then value.to_f64?
        else nil
        end
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
          case raw = value.raw
          when String
            # Real Ansible's recursive re-templating: a variable whose
            # own raw value is itself unrendered Jinja (a role default
            # defined in terms of another default, e.g. ansible-
            # community.ansible-vault's own `vault_version: "{{
            # lookup('env', 'VAULT_VERSION') | default('2.0.3', true)
            # }}"`) must be rendered before being compared - otherwise
            # `installed_vault_version.stdout != vault_version` compared
            # the real installed version string against the raw,
            # unrendered template text itself (never equal to anything),
            # always concluding a reinstall was needed. `{{ vault_version
            # }}` alone rendered correctly (a different code path -
            # VarSubstitutor#substitute's own re-templating pass -
            # already handled it), but this plain-lookup fallback for a
            # bare comparison operand didn't.
            if raw.includes?("{{")
              inner = raw.strip
              inner = inner[2..-3].strip if inner.starts_with?("{{") && inner.ends_with?("}}")
              rendered = VariableSubstitutor::ExpressionEvaluator.new(@vars).evaluate(inner)
              return rendered.to_i64? || rendered
            end
            return raw.strip
          when Int64
            return value.as_i64
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
        
        rerender_if_templated(current).to_s
      end

      # Resolves a simple or dotted expression to its raw JSON::Any value
      # (nil if undefined) - the filter-chain head resolution above needs
      # real structure to hand FilterEngine (an array for `length`/`sort`,
      # not an already-stringified value), unlike lookup_simple_variable/
      # lookup_nested_variable above, which both collapse to a String.
      private def resolve_json(expr : String) : JSON::Any?
        expr = expr.strip
        parts = expr.split(".")
        current = @vars[parts[0]]?
        return nil unless current

        parts[1..].each do |part|
          return nil unless current.raw.is_a?(Hash)
          next_value = current[part]?
          return nil unless next_value
          current = next_value
        end

        rerender_if_templated(current)
      end

      # Converts a resolved JSON::Any (a filter chain's result) into this
      # evaluator's own value union, mirroring how lookup_simple_variable/
      # lookup_nested_variable already convert a plain lookup.
      private def json_any_to_value(value : JSON::Any) : String | Int64 | Bool | Nil
        case value.raw
        when String
          value.as_s
        when Int64, Int32
          value.as_i64
        when Float64
          value.as_f.to_s
        when Bool
          value.as_bool
        when Nil
          nil
        else
          value.to_s
        end
      end
    end
  end
end
