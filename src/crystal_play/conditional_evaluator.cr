require "json"
require "./variable_substitutor/filter_engine"
require "./variable_substitutor/variable_lookup"
require "./variable_substitutor/expression_evaluator"

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
      # Strip whitespace, then unwrap a fully-parenthesized expression.
      # condition_to_string wraps each list-`when:` clause in parens
      # (`(a != 'x') and (b != 'y')`), and the recursion here hands each
      # `(...)` clause back to evaluate - so a bare `where os_family !=
      # 'Suse'` must be evaluated with its outer parens removed, or the
      # `(` breaks lookup/split (left operand becomes "(os_family "). Only
      # strip when the parens enclose the *entire* remaining expression.
      condition = condition.strip
      condition = unwrap_outer_parens(condition)

      # Handle 'not' at the beginning
      if condition.starts_with?("not ")
        return !evaluate(condition[4..-1].strip, vars)
      end

      # Handle 'and' operator (split and evaluate all parts).
      #
      # The `split_progressed?` guard is load-bearing, not defensive
      # tidiness: `includes?` sees an operator anywhere in the string,
      # but split_by_operator only splits on one at paren depth 0 outside
      # quotes. A condition whose only " and " sits inside quotes -
      # `["a", "b and c"]` - therefore came back as a single part
      # identical to the input, and this line recursed on that same
      # string until the stack blew (observed at ~104k frames deep, on a
      # real playbook). Falling through instead lets the rest of
      # evaluate/evaluate_truthiness deal with it, which terminates.
      if condition.includes?(" and ")
        parts = split_by_operator(condition, " and ")
        return parts.all? { |part| evaluate(part.strip, vars) } if split_progressed?(parts, condition)
      end

      # Handle 'or' operator (split and evaluate any part)
      if condition.includes?(" or ")
        parts = split_by_operator(condition, " or ")
        return parts.any? { |part| evaluate(part.strip, vars) } if split_progressed?(parts, condition)
      end

      # Handle 'is version(comparison_version, operator)' - Ansible's own
      # test (ansible.builtin.version), not standard Jinja2. Must be
      # checked before the comparison-operator checks just below: the
      # operator argument itself is very often a quoted `'>='`/`'<='`
      # literal (ssh_hardening's own crypto_hostkeys.yml gates 3
      # different set_fact: tasks on `when: sshd_version is version(
      # '5.3', '>=')`-shaped conditions), and `condition.includes?(">=")`
      # would otherwise fire first, splitting the *entire* "X is
      # version('5.3', '>=')" string on that substring as if it were a
      # top-level comparison - a nonsensical parse. Previously entirely
      # unimplemented here (only Crinja, the separate evaluator backing
      # real template files, had a `version` test) - every one of those
      # three when: conditions evaluated false via the generic fallback,
      # so the version-appropriate host key list was never set, leaving
      # a `loop:` over a genuinely undefined variable three tasks later
      # (surfacing as `item` = the literal string "undefined").
      if version_test = condition.match(/\A(.+?)\s+is\s+version\(\s*(.+?)\s*,\s*(.+?)\s*\)\z/)
        return evaluate_version_test(version_test[1], version_test[2], version_test[3], vars)
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

      # Handle 'in' / 'not in' operator. `'x' not in list` must be checked
      # as its own token (a leading `not ` followed by ` in `), since the
      # generic `in` splitter would otherwise leave the `not` glued to the
      # left operand (`'x' not` / ` in list`) and never match. dev-sec
      # os_hardening gates tasks on `'"change_user" not in
      # os_security_users_allow'`.
      if condition.includes?(" not in ")
        return !evaluate_in(condition.gsub(" not in ", " in "), vars)
      end

      # Handle 'in' operator
      if condition.includes?(" in ")
        return evaluate_in(condition, vars)
      end

      # Handle 'is defined' / 'is not defined' / 'is undefined' / 'is not
      # undefined' - real Jinja2 provides both spellings (`undefined` is
      # simply `defined`'s own negation, not a distinct concept), and
      # real playbooks use both (ssh_hardening's own crypto_ciphers.yml/
      # crypto_macs.yml/crypto_kex.yml default-setting tasks are all
      # gated on `when: ssh_ciphers is undefined`, never `is not
      # defined`). Previously only "is defined"/"is not defined" were
      # recognized - an unrecognized "is undefined" fell through to the
      # generic #evaluate_truthiness path below, which doesn't
      # understand `is` tests at all and evaluated it as always falsy -
      # the task setting the real default value was silently skipped on
      # every run, leaving the variable genuinely undefined by the time
      # a template referenced it (a crash three tasks later, nowhere
      # near this one).
      if condition.includes?(" is not undefined")
        var_name = condition.gsub(" is not undefined", "").strip
        return vars.has_key?(var_name)
      elsif condition.includes?(" is undefined")
        var_name = condition.gsub(" is undefined", "").strip
        return !vars.has_key?(var_name)
      elsif condition.includes?(" is defined")
        var_name = condition.gsub(" is defined", "").strip
        return vars.has_key?(var_name)
      elsif condition.includes?(" is not defined")
        var_name = condition.gsub(" is not defined", "").strip
        return !vars.has_key?(var_name)
      end

      # Handle 'is failed' / 'is succeeded' / 'is success' / 'is changed'
      # / 'is skipped' (plus each "is not ..." negation) - real Ansible's
      # own tests on a registered task result, reading the corresponding
      # boolean field out of its result dict. Entirely unimplemented
      # before (fell through to #evaluate_truthiness, which has no
      # notion of `is` tests at all and treated the whole "X is failed"
      # text as an undefined variable lookup - always falsy). Found via
      # ansible-community.ansible-vault's own `when: not vault_installation
      # is failed` (gating "Get installed Vault version" on the previous
      # task's own success) - always evaluated true (the `not` of a
      # falsy fallback), running the version-check command even on a
      # completely fresh host where "Check Vault installation" had
      # genuinely failed and left `.stdout` empty, producing a bogus
      # "-version" command with no vault binary in it at all.
      # "succeeded"/"success" are the same test - real Ansible provides
      # both spellings.
      {"failed", "succeeded", "success", "changed", "skipped"}.each do |test_name|
        if condition.includes?(" is not #{test_name}")
          var_name = condition.gsub(" is not #{test_name}", "").strip
          return !result_field(vars, var_name, test_name)
        elsif condition.includes?(" is #{test_name}")
          var_name = condition.gsub(" is #{test_name}", "").strip
          return result_field(vars, var_name, test_name)
        end
      end

      # Handle bare variable (truthiness check)
      return evaluate_truthiness(condition, vars)
    end

    # If *expr* is entirely wrapped in one matching pair of outer parens
    # (`(a and b)` or `(x == 1)`), return the inner expression with the
    # parens removed; otherwise return it unchanged. Quotes and inner
    # parens (e.g. `is version('1.4.0', '<')`) are balanced correctly, so
    # only a paren at the very start matched by one at the very end (with
    # depth returning to 0 only at the end) is stripped.
    private def self.unwrap_outer_parens(expr : String) : String
      return expr unless expr.starts_with?("(")

      depth = 0
      in_quotes = false
      quote_char = ' '
      expr.each_char_with_index do |char, idx|
        if (char == '"' || char == '\'') && (idx == 0 || expr[idx - 1] != '\\')
          if in_quotes && char == quote_char
            in_quotes = false
          elsif !in_quotes
            in_quotes = true
            quote_char = char
          end
        end

        next if in_quotes

        if char == '('
          depth += 1
        elsif char == ')'
          depth -= 1
          # If depth returns to 0 before the final char, the paren at the
          # start is not a full-wrap (the expression has trailing content),
          # so don't unwrap.
          return expr if depth == 0 && idx < expr.size - 1
        end
      end

      # Depth 1 after the loop means the whole expr was `(...)` - unwrap.
      expr[1..-2].strip
    end

    # Whether splitting actually broke the condition down. A single part
    # equal to the original means no real split happened, so recursing on
    # it would not terminate.
    private def self.split_progressed?(parts : Array(String), condition : String) : Bool
      parts.size > 1 || (parts.size == 1 && parts[0].strip != condition.strip)
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
    end

    # Evaluate 'in' operator
    # Resolves *left_expr* (a variable/dotted/filter-chain expression, the
    # same grammar #evaluate_value already handles) and compares it
    # against the quoted-literal *compare_to_expr* using *operator_expr*
    # (also a quoted literal, e.g. `'>='`) - see the call site above for
    # why this needs to run before the generic comparison-operator
    # checks.
    # Reads *test_name* ("failed"/"changed"/"skipped"/"succeeded"/
    # "success") off a registered task result. "succeeded"/"success"
    # aren't real result-dict keys - Ansible doesn't store a positive
    # "it worked" flag, only "failed" - so both spellings are the
    # inverse of "failed" instead. A field genuinely absent (a var that
    # isn't a registered result at all, or a task type whose result
    # never sets "skipped") defaults to false, matching real Ansible's
    # own tests never raising for a missing field.
    private def self.result_field(vars : Hash(String, JSON::Any), var_name : String, test_name : String) : Bool
      result = vars[var_name]?
      return false unless result

      failed = result["failed"]?.try(&.as_bool?) || false
      case test_name
      when "succeeded", "success"
        !failed
      else
        result[test_name]?.try(&.as_bool?) || false
      end
    end

    private def self.evaluate_version_test(left_expr : String, compare_to_expr : String, operator_expr : String, vars : Hash(String, JSON::Any)) : Bool
      left = evaluate_value(left_expr.strip, vars).to_s
      compare_to = unquote_literal(compare_to_expr.strip)
      operator = unquote_literal(operator_expr.strip)
      cmp = compare_versions(left, compare_to)

      case operator
      when "==", "="
        cmp == 0
      when "!="
        cmp != 0
      when "<", "lt"
        cmp < 0
      when "<=", "le"
        cmp <= 0
      when ">", "gt"
        cmp > 0
      when ">=", "ge"
        cmp >= 0
      else
        false
      end
    end

    private def self.unquote_literal(expr : String) : String
      if (expr.starts_with?('\'') && expr.ends_with?('\'')) || (expr.starts_with?('"') && expr.ends_with?('"'))
        expr[1..-2]
      else
        expr
      end
    end

    # Splits a version string into its numeric components (`"8.9p1"` ->
    # `[8, 9, 1]`, ignoring the non-digit "p" separator) and compares two
    # such lists lexicographically, treating a missing trailing
    # component as 0. Duplicated (not shared) from JinjaFilters.
    # compare_versions in jinja_filters.cr - that file requires "crinja"
    # for its own Value/filter registration machinery, too heavy a
    # dependency to pull into this evaluator (used by every `when:`
    # regardless of whether any template rendering is even involved) for
    # ten lines of arithmetic.
    private def self.compare_versions(a : String, b : String) : Int32
      a_parts = a.scan(/\d+/).map(&.[0].to_i)
      b_parts = b.scan(/\d+/).map(&.[0].to_i)
      [a_parts.size, b_parts.size].max.times do |i|
        a_val = a_parts[i]? || 0
        b_val = b_parts[i]? || 0
        cmp = a_val <=> b_val
        return cmp unless cmp == 0
      end
      0
    end

    private def self.evaluate_in(condition : String, vars : Hash(String, JSON::Any)) : Bool
      parts = condition.split(" in ", 2)
      return false if parts.size != 2

      item = evaluate_value(parts[0].strip, vars)
      container = evaluate_value(parts[1].strip, vars)

      # Check if item is in container (string or array). Every array
      # value this evaluator ever produces - whether from a literal
      # `[0, 3, 4]` or a real variable - is Array(String), since
      # evaluate_value/json_any_to_value both stringify every element
      # (Array(String) is the only array shape this method's own return
      # type allows). `item` itself, though, keeps its real type (an
      # Int64 for something like a registered command's `.rc`) - so
      # comparing it against the container unstringified
      # (`container.includes?(item)`) compared an Int64 against String
      # elements, which Crystal's `==` never treats as equal, so
      # membership always came back false. `failed_when: result.rc not
      # in [0, 3, 4]` (openstack.ansible-hardening's own kdump-service
      # check, "not in" is `!evaluate_in`) therefore always evaluated
      # true regardless of the real rc, hard-failing a task real
      # Ansible treats as a legitimate rc=3/4 success and halting the
      # rest of the play for that host.
      if container.is_a?(String)
        container.includes?(item.to_s)
      elsif container.is_a?(Array)
        container.includes?(item.to_s)
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

      # A filter chain (`mylist | length > 0`, or a bare `when: mylist |
      # length` truthiness check), a parenthesized sub-expression
      # (possibly with trailing dotted/indexed access - dev-sec
      # os_hardening's own password-ageing assert: `( expiry_date.stdout |
      # trim | to_datetime(...) - ansible_facts.date_time.date |
      # to_datetime(...) ).days == 60`), or a top-level `-` subtraction -
      # delegates to ExpressionEvaluator, the same evaluator {{ }}
      # substitution uses and the only one of the two that understands
      # nested filter calls inside a parenthesized operand, datetime
      # subtraction, and dotted access on a sub-expression's *result*
      # (not just on a plain variable). Previously this module had its
      # own separate, far less capable filter-chain-only handling here,
      # which - among other gaps - had no concept of `|` nested inside an
      # unclosed paren at all, so a condition shaped like the one above
      # always evaluated to undefined.
      if expr.includes?("|") || expr.starts_with?('(') || expr.includes?(" - ")
        evaluator = VariableSubstitutor::ExpressionEvaluator.new(vars)
        rendered = evaluator.evaluate(expr)
        parsed = (JSON.parse(rendered) rescue nil)
        return json_any_to_value(parsed || JSON::Any.new(rendered))
      end

      # Handle arrays (simple list syntax)
      if expr.starts_with?('[') && expr.ends_with?(']')
        items = expr[1..-2].split(',').map(&.strip)
        return items.map { |item|
          val = evaluate_value(item, vars)
          val.is_a?(String) ? val : val.to_s
        }
      end

      # Dotted and/or indexed variable access (e.g. result.rc,
      # stat_result.stat.exists, ansible_facts.getent_passwd[item][1] -
      # dev-sec os_hardening's own way of pulling a getent entry's UID
      # field, gating every account-management task in that role) -
      # previously only the {{ }}-wrapped ComparisonEvaluator path
      # supported this at all, and even the dotted-only case here never
      # understood a trailing `[...]` (treating "getent_passwd[item][1]"
      # as one literal, nonexistent hash key). Delegates to
      # VariableLookup#resolve, the same chained dotted+indexed resolver
      # {{ }} substitution uses. Guarded against float literals ("1.5")
      # also containing a "." - those aren't variable paths, and the
      # first segment of a real one ("result") won't itself parse as a
      # float.
      if (expr.includes?(".") || expr.includes?("[")) && !expr.to_f64?
        parts = expr.split(/[.\[]/)
        if !parts.empty? && vars.has_key?(parts[0])
          resolved = VariableSubstitutor::VariableLookup.new(vars).resolve(expr)
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

    # Resolves a simple, dotted, and/or indexed expression (the head of a
    # filter chain, e.g. "mylist", "result.stdout" in "result.stdout |
    # trim", or "ansible_facts.getent_passwd[item][1]" in "...|int") to
    # its raw JSON::Any value - delegates to VariableLookup#resolve, the
    # same chained dotted+indexed resolver {{ }} substitution uses.
    private def self.resolve_json(expr : String, vars : Hash(String, JSON::Any)) : JSON::Any?
      VariableSubstitutor::VariableLookup.new(vars).resolve(expr.strip)
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
    # `==`/`!=`: a raw match first, then a numeric-string fallback - see
    # ComparisonEvaluator#values_equal? (the {{ }}-side counterpart to
    # this bare when:/assert:-condition evaluator) for why: a value that
    # went through a filter chain/parenthesized sub-expression may come
    # back as a real Int64 while the other side is a quoted string
    # literal (or vice versa) purely as an artifact of this codebase's
    # string-heavy evaluation pipeline, not because the two values are
    # actually different.
    private def self.values_equal?(left : String | Int64 | Bool | Nil | Array(String), right : String | Int64 | Bool | Nil | Array(String)) : Bool
      return true if left == right

      left_num = numeric_or_nil(left)
      right_num = numeric_or_nil(right)
      !left_num.nil? && !right_num.nil? && left_num == right_num
    end

    private def self.numeric_or_nil(value : String | Int64 | Bool | Nil | Array(String)) : Float64?
      case value
      when Int64  then value.to_f64
      when String then value.to_f64?
      else nil
      end
    end

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
