require "json"
require "../unsafe_values"
require "./filter_engine"
require "./jinja_renderer"

module Krikri
  module VariableSubstitutor
    # Raised when an ordering comparison (`<`, `<=`, `>`, `>=`) gets
    # operands Jinja2/Python cannot compare - a container against
    # anything, nil/None against anything, any string against a number,
    # a boolean against a string. Python only ever orders int/float/bool
    # mutually and str mutually, so ansible-playbook fails the task on
    # `'10' >= 1` with "'>=' not supported between instances of
    # '_AnsibleTaggedStr' and 'int'" (live-verified, issue #219; a yaml
    # string carries a datatag, hence the name). This evaluator
    # historically stringified both operands and compared the texts,
    # silently answering where Ansible fails (found by
    # bin/differential_fuzz against the krikri-jinja engine, which already
    # raises exactly what Jinja2 3.1.6 raises).
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
      # re-renders *value* if it's still a String containing `{{` -
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
      # answered "False" where Jinja2 raises TypeError), and a
      # missing/None operand collapsed to a string too (`missing_var <
      # '17'` answered "True" where Jinja2 raises on the comparison
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

            # Jinja2's grammar allows `not` only as a unary prefix
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
      # #compare_values can raise exactly where Jinja2/Python raises
      # on incomparable operand classes.
      #
      # A missing dotted path or bare name resolves to JSON null - which
      # for an ORDERING comparison then raises like Jinja2 raises on
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
        # repeatedly" pattern this codebase's own AGENTS.md warns about.
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
          # Render-then-parse cannot tell a numeric-looking STRING result
          # from a real number ("7" off `expiry_warndays.stdout | trim`
          # re-parses as Int64 7, where real Jinja keeps a string-
          # producing filter's result a str) - recover the real type from
          # the structured (Crinja) path when it can resolve the same
          # chain and says String, keeping the re-typed value otherwise.
          if parsed.raw.is_a?(Int64) || parsed.raw.is_a?(Float64)
            structured = begin
              ExpressionEvaluator.new(@vars).evaluate_structured(expr)
            rescue
              nil
            end
            parsed = structured if structured && structured.raw.is_a?(String)
          end
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
              unless VarSubstitutor.unsafe_root?(@vars, name) || UnsafeValues.unsafe_text?(raw)
                # A pure `{{ other }}` indirection resolves straight to the
                # referenced variable's own typed value - render-then-reparse
                # here turned "3" into Int64 3 and broke `x == '3'` under
                # type-strict equality (see Rerender.bare_indirection_value).
                if typed = Rerender.bare_indirection_value(@vars, raw)
                  return typed
                end
              end
              rendered = render_raw_template_string(raw, name)
              return rendered_string_to_typed(rendered)
            end
            return JSON::Any.new(raw.strip)
          else
            # A container variable's own value may have leaves that are
            # still unrendered Jinja (`accounts: ["{{ myuser }}"]`):
            # Ansible's recursive re-templating renders every leaf before
            # the comparison sees it, so `accounts != ['root']` compares by
            # the RENDERED list. Returning the raw Array (String leaves
            # still literal `{{ }}` text) made the same comparison answer
            # True and, in real roles, ran the gated task instead of
            # skipping it - l3d.dotfiles, round 5250154.
            if raw.is_a?(Array) || raw.is_a?(Hash)
              unless VarSubstitutor.unsafe_root?(@vars, name)
                # defer_unresolved like the filter-chain head (round
                # 952484): a leaf bottoming out at an undefined name is
                # left raw so a comparison that never touches it still
                # answers the way Ansible's lazy templating does.
                return JinjaRenderer.rerender_nested_templates(
                  value, VarSubstitutor.new(vars: @vars), defer_unresolved: true)
              end
              return value
            end
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

      # `==`/`!=`: strict on operand type, matching real Python/Jinja2
      # (live-verified against ansible-playbook): `'9' == 9` and
      # `'a' == 7` are plain False, so only type-equal values compare
      # equal. The one cross-type equality Python does allow here is
      # Bool against int (True == 1, False == 0: bool is an int
      # subclass) - and int against float. The old numeric-string
      # fallback made `"9" == 9` answer True and ran tasks Ansible
      # skips; the filter-chain case that motivated it (dev-sec
      # os_hardening's own `(expiry_warndays.stdout | trim) == '7'`,
      # whose string result the render-then-parse round trip re-typed as
      # Int64) is fixed at that source instead - see the String recovery
      # in #evaluate_simple_value_typed's filter-chain branch, so that
      # comparison is now str-vs-str like Ansible's.
      private def values_equal?(left : JSON::Any, right : JSON::Any) : Bool
        return true if left.raw == right.raw

        left_num = equality_numeric_or_nil(left)
        right_num = equality_numeric_or_nil(right)
        !left_num.nil? && !right_num.nil? && left_num == right_num
      end

      # Only the operand classes Python cross-compares numerically - a
      # String is deliberately absent, because Python never treats a
      # string as a number: `'7' == 7` is False, and `'7' < 7` is a
      # TypeError. Numeric strings get parsed only in the two-raw-strings
      # ordering cascade (#numeric_or_nil), where Python's own
      # str-vs-str ordering already applies.
      private def equality_numeric_or_nil(value : JSON::Any) : Float64?
        case raw = value.raw
        when Int64   then raw.to_f64
        when Float64 then raw
        when Bool    then raw ? 1.0 : 0.0
        end
      end

      private def numeric_or_nil(value : JSON::Any) : Float64?
        case raw = value.raw
        when Int64   then raw.to_f64
        when Float64 then raw
        when String  then raw.to_f64?
        end
      end

      # Compare two values for an ORDERING comparison (`<`/`>`/`<=`/`>=`).
      #
      # Strict on operand class, matching Jinja2/Python, which raises
      # TypeError - and ansible-playbook fails the task - for any
      # ordering comparison between incomparable classes (dict vs float,
      # str vs int, None vs anything, list vs anything). The historical
      # behavior here stringified both operands and compared the texts,
      # silently answering every one of those (`dict <= 6.6` -> "False",
      # `missing_var < '17'` -> "True").
      #
      # Deliberately KEPT lenient (pre-existing, load-bearing for real
      # roles whose values are strings from module stdout): two raw
      # Strings compare as strings (int/float-parsable pairs numerically
      # first, exactly as before), matching Python's own lexicographic
      # str-vs-str ordering. But a String paired with a real number is
      # never parsed as a number: ansible fails `'10' >= 1` (a role
      # default compared to a numeric literal, issue #219) with "'>=' not
      # supported between instances of '_AnsibleTaggedStr' and 'int'".
      # A Bool orders numerically as its int-subclass value (True == 1 in
      # Python: `True > False` and `bool_var < 2` are valid Python).
      private def compare_values(left : JSON::Any, right : JSON::Any, op : String) : Int32
        # Two raw strings: keep the historical numeric-first cascade for
        # numeric-string pairs, lexicographic for anything else (Python's
        # own str-vs-str semantics).
        if left.raw.is_a?(String) && right.raw.is_a?(String)
          left_num = numeric_or_nil(left)
          right_num = numeric_or_nil(right)
          if left_num && right_num
            return (left_num <=> right_num) || 0
          end
          return left.as_s <=> right.as_s
        end

        # Cross-class path never parses a String as a number (ansible
        # refuses the comparison the way Python does, see above); Bool
        # already coerces to its int-subclass value in
        # #equality_numeric_or_nil.
        left_num = equality_numeric_or_nil(left)
        right_num = equality_numeric_or_nil(right)

        if left_num && right_num
          return (left_num <=> right_num) || 0
        end

        raise ComparisonTypeError.new(
          "'#{op}' not supported between instances of '#{python_type_name(left)}' and '#{python_type_name(right)}'")
      end

      # Python's own class name for a JSON::Any operand, for the
      # TypeError-style message above (real message: "'<=' not supported
      # between instances of 'dict' and 'float'"). Strings are named the
      # way ansible names them in that message, '_AnsibleTaggedStr' - its
      # yaml loader tags strings, so they are not plain 'str' (issue
      # #219).
      private def python_type_name(value : JSON::Any) : String
        case value.raw
        when String  then "_AnsibleTaggedStr"
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
