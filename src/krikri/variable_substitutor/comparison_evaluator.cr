require "json"
require "../unsafe_values"
require "./filter_engine"
require "./jinja_renderer"

module Krikri
  module VariableSubstitutor
    # Raised when an ordering comparison (`<`, `<=`, `>`, `>=`) gets
    # operands real Jinja2/Python cannot compare - a container against
    # anything, nil/None against anything, a non-numeric string against a
    # number, a boolean against a non-numeric string. Real Jinja2 raises
    # TypeError ("'<=' not supported between instances of 'dict' and
    # 'float'") and real ansible-playbook fails the task; this evaluator
    # historically stringified both operands and compared the texts,
    # silently answering where real Ansible fails (found by
    # bin/differential_fuzz against the krikri-jinja engine, which already
    # raises exactly what real Jinja2 3.1.6 raises).
    class ComparisonTypeError < Exception
    end

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
      # lookup fallback already resolved. Now a thin delegate to the ONE
      # shared implementation (VariableSubstitutor::Rerender) - the
      # multi-span and block-tag fixes this copy used to re-discover
      # independently land there once for every caller.
      private def rerender_if_templated(value : JSON::Any, source_expr : String? = nil) : JSON::Any
        Rerender.if_templated(@vars, value, source_expr) || value
      end

      private def render_raw_template_string(raw : String, source_expr : String? = nil) : String
        Rerender.render_raw(@vars, raw, source_expr)
      end

      # Evaluate a comparison expression
      # Example: ssl_check.rc == 0, count > 5
      #
      # Operands are resolved STRUCTURED (JSON::Any, not pre-stringified)
      # so the ordering comparisons below can see real operand classes:
      # the old String-typed operands collapsed a container operand to its
      # JSON text and then silently string-compared it (`dict <= 6.6`
      # answered "False" where real Jinja2 raises TypeError), and a
      # missing/None operand collapsed to a string too (`missing_var <
      # '17'` answered "True" where real Jinja2 raises on the comparison
      # against Undefined/None).
      def evaluate(expr : String) : String
        # Try operators in order (longest first to avoid false matches)
        operators = ["==", "!=", "<=", ">=", ">", "<"]

        operators.each do |op|
          # Quote-aware split: an operator inside a quoted operand
          # (`msg != "x == y"`) must not be treated as the comparison -
          # the old `expr.includes?(op)` + `split(op, 2)` split inside
          # the quotes and compared garbage.
          if parts = split_outside_quotes(expr, op)
            left_text = parts[0].strip
            right_text = parts[1].strip

            # Real Jinja2's grammar allows `not` only as a unary prefix
            # over a whole comparison (`not a == b`), never as the RIGHT
            # operand of one (`a == not b` is a syntax error). The
            # heuristic operand resolver below treated such an operand as
            # an (always-undefined) variable name and silently compared
            # garbage; raise instead. Only the right side is guarded: a
            # LEFT operand starting with `not` is the legitimate prefix-
            # negation spelling this split-on-operator-first evaluator
            # sees for `not x == y` (real parse: `not (x == y)`).
            guard_boolean_keyword_operand(right_text)

            left = evaluate_simple_value_typed(left_text)
            right = evaluate_simple_value_typed(right_text)

            result = case op
                     when "=="
                       values_equal?(left, right)
                     when "!="
                       !values_equal?(left, right)
                     when "<"
                       compare_values(left, right, op) < 0
                     when ">"
                       compare_values(left, right, op) > 0
                     when "<="
                       compare_values(left, right, op) <= 0
                     when ">="
                       compare_values(left, right, op) >= 0
                     else
                       false
                     end

            return result.to_s
          end
        end

        "false"
      end

      # A comparison operand whose (unquoted) text starts with a boolean
      # keyword is a real-Jinja syntax error, not a value - raise instead
      # of silently resolving it as an always-undefined variable name.
      private def guard_boolean_keyword_operand(text : String) : Nil
        stripped = text.strip
        return if stripped.empty? || stripped.starts_with?('\'') || stripped.starts_with?('"')
        keyword = stripped.match(/\A(not|and|or|is)\b/).try(&.[1])
        return unless keyword
        raise ComparisonTypeError.new("unexpected token '#{keyword}' after expression")
      end

      # Splits *expr* on the first occurrence of *op* outside single/
      # double quotes, or nil if there is none. Byte-level scan: quotes
      # and every operator character are ASCII, so multibyte characters
      # can never alias a quote or operator byte.
      private def split_outside_quotes(expr : String, op : String) : {String, String}?
        bytes = expr.bytes
        op_bytes = op.bytes
        in_single = false
        in_double = false
        i = 0
        while i + op_bytes.size <= bytes.size
          case bytes[i]
          when 0x22 # double quote
            in_double = !in_double unless in_single
          when 0x27 # single quote
            in_single = !in_single unless in_double
          else
            if !in_single && !in_double && op_bytes.each_with_index.all? { |op_byte, j| bytes[i + j] == op_byte }
              return {expr[0...i], expr[(i + op_bytes.size)..]}
            end
          end
          i += 1
        end
        nil
      end

      # Legacy String-typed form of #evaluate_simple_value_typed, kept for
      # API compatibility - every internal consumer now uses the typed
      # resolver directly.
      def evaluate_simple_value(expr : String) : String | Int64 | Bool | Nil
        json_any_to_value(evaluate_simple_value_typed(expr))
      end

      # Structured (JSON::Any) resolution of a single comparison operand -
      # the same resolution order the legacy String-typed version used
      # (quoted literal, boolean literal, numeric literal, filter-chain/
      # paren/`~`/bracket delegation to a fresh ExpressionEvaluator,
      # dotted-path walk, bare-name lookup with re-templating), but
      # PRESERVING the operand's real type instead of collapsing
      # containers to their JSON text and numbers to strings, so
      # #compare_values can raise exactly where real Jinja2/Python raises
      # on incomparable operand classes.
      #
      # A missing dotted path or bare name resolves to JSON null - which
      # for an ORDERING comparison then raises like real Jinja2 raises on
      # both a None operand and an Undefined one (a defined-null `None <
      # 3` and a missing var are indistinguishable at this layer, and
      # real Python raises TypeError on both).
      private def evaluate_simple_value_typed(expr : String) : JSON::Any
        expr = expr.strip

        # Handle quoted strings
        if (expr.starts_with?('"') && expr.ends_with?('"')) ||
           (expr.starts_with?('\'') && expr.ends_with?('\''))
          return JSON::Any.new(expr[1..-2])
        end

        # Handle booleans
        if expr == "true" || expr == "True"
          return JSON::Any.new(true)
        elsif expr == "false" || expr == "False"
          return JSON::Any.new(false)
        end

        # Handle numbers - including FLOAT literals, which the legacy
        # String-typed resolver never recognized: "6.6" contains a ".", so
        # it fell into the dotted-lookup branch below, looked up a variable
        # literally named "6" and compared against the "undefined" sentinel
        # text (`dict <= 6.6` answered "False" for the wrong reason; a real
        # `count > 1.5` comparison answered against undefined too).
        if int_val = expr.to_i64?
          return JSON::Any.new(int_val)
        end
        if float_val = expr.to_f64?
          return JSON::Any.new(float_val)
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
        # `[` - a bracket-indexed comparison operand (`checksums[some_
        # var]`, prometheus.prometheus._common's own checksum-
        # verification assert) - this class has its own completely
        # separate operand-resolution logic (lookup_simple_variable/
        # lookup_nested_variable below), which had no concept of `[...]`
        # indexing at all: an expr like `checksums[basename]` has no
        # `.`, so it fell all the way through to lookup_simple_variable,
        # which looked for a variable LITERALLY NAMED
        # "checksums[basename]" (via `@vars.has_key?`) - never present,
        # so the comparison silently treated a real value as nil/
        # undefined. Delegates to the SAME ExpressionEvaluator already
        # used for `|`/`(`/`~` above rather than duplicating VariableLookup#
        # resolve_indexed's bracket-parsing (and its own re-templating
        # guard for a still-templated index-key variable) a fourth time.
        # Real bug found live-verifying prometheus.prometheus.
        # node_exporter: every download's checksum verification failed
        # this way even after VariableLookup's own copy of the bug (a
        # bare `{{ }}` `dict[var]` lookup) was fixed - this is a
        # THIRD independent evaluator with its own copy of the same
        # root cause, exactly the "found and fixed independently,
        # repeatedly" pattern this codebase's own CLAUDE.md warns about.
        if expr.includes?("|") || expr.starts_with?('(') || expr.includes?("~") || expr.includes?("[")
          rendered = ExpressionEvaluator.new(@vars).evaluate(expr)
          parsed = Krikri.parse_json_or_python_literal(rendered)
          # A delegated sub-expression that bottomed out at an undefined
          # reference renders the "undefined" SENTINEL text here - as a
          # comparison operand that must be a real miss (JSON null), not a
          # string that then silently string-compares
          # (`(int_neg[0] <= 'hello world')` answered "False" where real
          # Jinja2 raises on the comparison against Undefined).
          return JSON::Any.new(nil) if parsed.raw == "undefined"
          return parsed
        end

        # Handle nested variable access (e.g., result.rc)
        if expr.includes?(".")
          return resolve_json(expr) || JSON::Any.new(nil)
        end

        # Simple variable lookup
        lookup_simple_variable_typed(expr)
      end

      # Structured form of #lookup_simple_variable: same re-templating
      # guards (a variable whose own raw value is still unrendered Jinja is
      # rendered before being compared - the ansible-community.ansible-vault
      # `vault_version` case), but preserving the value's real JSON type
      # instead of collapsing containers to `to_s` text.
      private def lookup_simple_variable_typed(name : String) : JSON::Any
        name = name.strip

        if @vars.has_key?(name)
          value = @vars[name]
          case raw = value.raw
          when String
            if raw.includes?("{%") || raw.includes?("{#")
              unless VarSubstitutor.unsafe_root?(@vars, name) || UnsafeValues.unsafe_text?(raw)
                rendered = JinjaRenderer.new(@vars).render(raw)
                return rendered_string_to_typed(rendered)
              end
              return JSON::Any.new(raw.strip)
            end
            if raw.includes?("{{")
              rendered = render_raw_template_string(raw, name)
              return rendered_string_to_typed(rendered)
            end
            return JSON::Any.new(raw.strip)
          else
            return value
          end
        end

        JSON::Any.new(nil)
      end

      # A re-templated bare operand's rendered text, typed the way the
      # legacy lookup_simple_variable typed it (integer when the whole
      # render parses as one, string otherwise).
      private def rendered_string_to_typed(rendered : String) : JSON::Any
        if int_val = rendered.to_i64?
          return JSON::Any.new(int_val)
        end
        JSON::Any.new(rendered)
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
      #
      # Equality stays type-lenient on purpose: real Python answers False
      # (never an error) for `{} == 6`, `'a' == 7`, `None == 0` - only the
      # ORDERING comparisons below are class-strict.
      private def values_equal?(left : JSON::Any, right : JSON::Any) : Bool
        return true if left.raw == right.raw

        left_num = numeric_or_nil(left)
        right_num = numeric_or_nil(right)
        !left_num.nil? && !right_num.nil? && left_num == right_num
      end

      private def numeric_or_nil(value : JSON::Any) : Float64?
        case raw = value.raw
        when Int64  then raw.to_f64
        when Float64 then raw
        when String then raw.to_f64?
        end
      end

      # Compare two values for an ORDERING comparison (`<`/`>`/`<=`/`>=`).
      #
      # Strict on operand class, matching real Jinja2/Python, which raises
      # TypeError - and real ansible-playbook fails the task - for any
      # ordering comparison between incomparable classes (dict vs float,
      # str vs int, None vs anything, list vs anything). The historical
      # behavior here stringified both operands and compared the texts,
      # silently answering every one of those (`dict <= 6.6` -> "False",
      # `missing_var < '17'` -> "True").
      #
      # Deliberately KEPT lenient (pre-existing, load-bearing for real
      # roles whose values are strings from module stdout):
      # - two raw Strings compare as strings (int/float-parsable pairs
      #   numerically first, exactly as before), matching Python's own
      #   lexicographic str-vs-str ordering;
      # - a numeric string against a real number compares numerically
      #   ("7" < 10).
      # A Bool orders numerically as its int-subclass value (True == 1 in
      # Python: `True > False` and `bool_var < 2` are valid Python).
      private def compare_values(left : JSON::Any, right : JSON::Any, op : String) : Int32
        left_num = numeric_or_nil(left)
        right_num = numeric_or_nil(right)

        # Two raw strings: keep the historical numeric-first cascade for
        # numeric-string pairs, lexicographic for anything else (Python's
        # own str-vs-str semantics).
        if left.raw.is_a?(String) && right.raw.is_a?(String)
          if left_num && right_num
            return (left_num <=> right_num) || 0
          end
          return left.as_s <=> right.as_s
        end

        # Bool coerces to its Python int-subclass value for ordering.
        # (A nil-check, not an `if raw = ...` truthiness test: False is a
        # valid Bool operand and would skip the branch.)
        if (left_bool = left.raw.as?(Bool)).is_a?(Bool)
          left_num = left_bool ? 1.0 : 0.0
        end
        if (right_bool = right.raw.as?(Bool)).is_a?(Bool)
          right_num = right_bool ? 1.0 : 0.0
        end

        if left_num && right_num
          return (left_num <=> right_num) || 0
        end

        raise ComparisonTypeError.new(
          "'#{op}' not supported between instances of '#{python_type_name(left)}' and '#{python_type_name(right)}'")
      end

      # Python's own class name for a JSON::Any operand, for the
      # TypeError-style message above (real message: "'<=' not supported
      # between instances of 'dict' and 'float'").
      private def python_type_name(value : JSON::Any) : String
        case value.raw
        when String  then "str"
        when Int64   then "int"
        when Float64 then "float"
        when Bool    then "bool"
        when Nil     then "NoneType"
        when Array   then "list"
        when Hash    then "dict"
        else              "object"
        end
      end

      # Resolves a simple or dotted expression to its raw JSON::Any value
      # (nil if undefined) - the filter-chain head resolution above needs
      # real structure to hand FilterEngine (an array for `length`/`sort`,
      # not an already-stringified value), unlike lookup_simple_variable/
      # lookup_nested_variable above, which both collapse to a String.
      private def resolve_json(expr : String) : JSON::Any?
        expr = expr.strip
        parts = expr.split(".")
        base = @vars[parts[0]]?
        return nil unless base

        current = VariableSubstitutor.walk_dotted_path(base, parts[1..])
        return nil unless current

        rerender_if_templated(current, expr)
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
