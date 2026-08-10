require "json"
require "../conditional_evaluator"
module CrystalPlay
  module VariableSubstitutor
    # ExpressionEvaluator - Orchestrates evaluation of all expression types
    # Delegates to specialized evaluators based on expression type
    class ExpressionEvaluator
      @vars : Hash(String, JSON::Any)
      @comparison : ComparisonEvaluator
      @filter : FilterEngine
      @slicer : ArraySlicer
      @lookup : VariableLookup
      
      def initialize(@vars : Hash(String, JSON::Any))
        @comparison = ComparisonEvaluator.new(@vars)
        @filter = FilterEngine.new(@vars)
        @slicer = ArraySlicer.new(@vars)
        @lookup = VariableLookup.new(@vars)
      end
      
      # Evaluate any expression and return string result. A thin guard in
      # front of #evaluate_expr for the inline ternary `TRUTHY if COND else
      # FALSY` (real Jinja2/Ansible syntax, used directly in default vars
      # like konstruktoid-hardening's `sysctl_conf_dir: "{{
      # '/usr/lib/sysctl.d' if usr_lib_sysctl_d_dir else '/etc/sysctl.d'
      # }}"`) - split out from the main body (rather than added as another
      # branch in it) purely to keep that method's already-high cyclomatic
      # complexity from tipping over ameba's threshold. Checked before any
      # of #evaluate_expr's own checks since COND itself commonly contains
      # a comparison - splitting first keeps that comparison scoped to COND
      # instead of being (wrongly) evaluated against the whole expression.
      def evaluate(expr : String) : String
        if ternary = split_ternary(expr)
          evaluate_ternary(ternary)
        else
          evaluate_expr(expr)
        end
      end

      private def evaluate_expr(expr : String) : String
        # Check for comparison operators FIRST (before filters)
        if has_comparison?(expr)
          return @comparison.evaluate(expr)
        end

        # A leading parenthesized sub-expression, optionally followed by
        # dotted/indexed access on its result (`( a | to_datetime(...) -
        # b | to_datetime(...) ).days` - dev-sec os_hardening's own
        # password-ageing day-count assert). Recurses into the inner
        # expression (which may itself contain `-`/`+`/filters/anything
        # else `evaluate` understands) and, once resolved, walks any
        # trailing `.attr`/`[index]` suffix against the *result* rather
        # than against @vars - VariableLookup#walk exists for exactly
        # this (a base value that didn't come from a plain variable
        # lookup). Checked before `+`/`-` below: those are correctly
        # depth-aware and would already skip content inside the leading
        # paren, but a bare `(x)` or `(x).attr` with no top-level
        # operator at all still needs unwrapping here or it falls through
        # to a lookup on the literal text "(x)".
        if paren = split_leading_paren(expr)
          return evaluate_leading_paren(paren)
        end

        # Check for top-level `-` subtraction - specifically datetime
        # subtraction (dev-sec os_hardening's own `to_datetime(...) -
        # to_datetime(...)`, producing a timedelta `.days` can then read)
        # and plain numeric subtraction. Requires spaces around the `-`
        # (unlike `+`, a bare hyphen is common inside ordinary
        # identifiers/text, so only the unambiguous "a - b" spacing is
        # treated as the operator) and, like `+`, must come before the
        # filter check: `|` binds tighter than `-`, so each side may
        # still carry its own filter chain evaluated independently.
        if minus = split_top_level_minus(expr)
          left_expr, right_expr = minus
          return evaluate_minus(left_expr, right_expr)
        end

        # Check for top-level `+` concatenation (list/string/number), e.g.
        # `mountpoints_list + ['/dev', '/dev/shm', '/run', '/tmp']`, or
        # `acc | default([]) + [item]` (dev-sec os_hardening's own
        # account-list accumulator pattern) - a common Jinja2 idiom for a
        # self-referential set_fact appending literal entries onto a
        # list. Must come before both the filter check below (Jinja
        # binds `|` tightly to its immediate left operand only - `acc |
        # default([]) + [item]` is `(acc | default([])) + [item]`, not
        # `acc | (default([]) + [item])`, so `+` is the outer, lower-
        # precedence split here) and the generic "[" check further down,
        # which would otherwise misparse the whole expression as
        # `var[key]` off a literal array operand's own brackets.
        if segments = split_top_level_plus(expr)
          return evaluate_plus(segments)
        end

        # Check for filters (|)
        if expr.includes?("|")
          return evaluate_with_filter(expr)
        end

        # A literal Jinja array (`[]`, `['x']`, `[item]`) standing alone -
        # `resolve_plus_operand` already special-cases this for a `+`
        # operand via parse_literal_array, but the general dispatch here
        # had no equivalent, so the same literal used anywhere else (a
        # ternary branch: linux-system-roles/logging's rsyslog subrole
        # `__rsyslog_tls_packages if (...) else []`) fell through to the
        # generic `[` dict/list-access check below, which treats the
        # bracketed text as *indexing syntax* on the (empty, since there's
        # no variable name before the bracket) prefix - always failing and
        # resolving to "undefined" instead of an empty/literal list. Only
        # an expr that *starts* with `[` can be this case; `list[0]`/
        # `list[0:2]` always start with the variable name instead, so this
        # can't misfire on real indexing/slicing.
        if expr.includes?("[")
          return evaluate_bracket_expr(expr)
        end

        # Check for nested access (.)
        if expr.includes?(".")
          return @lookup.nested(expr)
        end

        # Simple variable lookup
        @lookup.simple(expr)
      end

      # Dispatches every `[`-bearing expr that isn't already a top-level
      # +/-/filter/paren case (those are checked before this in
      # evaluate_expr). A literal Jinja array (`[]`, `['x']`, `[item]`)
      # standing alone must be checked first: `resolve_plus_operand`
      # already special-cases this for a `+` operand via
      # parse_literal_array, but a ternary branch (linux-system-roles/
      # logging's rsyslog subrole: `__rsyslog_tls_packages if (...) else
      # []`) reaches this general dispatch instead - without this check it
      # fell through to the indexed-access branch, which treats the
      # bracketed text as *indexing syntax* on the (empty, since there's
      # no variable name before the bracket) prefix, always failing and
      # resolving to "undefined" instead of an empty/literal list. Only an
      # expr that *starts* with `[` can be this case; `list[0]`/
      # `list[0:2]` always start with the variable name instead, so this
      # can't misfire on real indexing/slicing.
      private def evaluate_bracket_expr(expr : String) : String
        return @lookup.format_value(parse_literal_array(expr)) if literal_array_expr?(expr)
        return @slicer.slice(expr) if expr.includes?("[:") || expr.includes?(":]")
        @lookup.indexed(expr)
      end

      private def literal_array_expr?(expr : String) : Bool
        expr.starts_with?('[') && expr.ends_with?(']')
      end

      # Resolves the branch selected by a ternary's condition. A branch
      # that's a plain quoted string literal (the common case - both
      # branches of `X if C else Y` are usually literals) is unquoted
      # directly rather than handed to `evaluate`, which has no top-level
      # "bare quoted literal" case of its own and would otherwise try
      # (and fail) to look it up as a variable name, quotes included.
      private def evaluate_ternary(ternary : {String, String, String}) : String
        truthy_expr, cond_expr, falsy_expr = ternary
        chosen = ConditionalEvaluator.evaluate(cond_expr, @vars) ? truthy_expr : falsy_expr
        quoted_string_literal(chosen).try(&.as_s) || evaluate(chosen)
      end

      # Splits *expr* on a top-level ` if ` ... ` else ` (outside
      # quotes/brackets), returning {truthy, condition, falsy} or nil if
      # the expression isn't a ternary at all. Only the first top-level
      # ` if ` and the last top-level ` else ` are used as delimiters, so
      # a condition that itself contains " if "/" else " inside quotes or
      # nested parens/brackets is left intact.
      private def split_ternary(expr : String) : {String, String, String}?
        if_idx = top_level_keyword_index(expr, " if ")
        return nil unless if_idx

        else_idx = top_level_keyword_index(expr, " else ", if_idx + 4)
        return nil unless else_idx

        truthy = expr[0...if_idx].strip
        cond = expr[(if_idx + 4)...else_idx].strip
        falsy = expr[(else_idx + 6)..].strip
        return nil if truthy.empty? || cond.empty? || falsy.empty?

        {truthy, cond, falsy}
      end

      # Finds the index of *keyword* at bracket/quote depth 0, starting the
      # scan at *from*.
      private def top_level_keyword_index(expr : String, keyword : String, from : Int32 = 0) : Int32?
        depth = 0
        quote = nil.as(Char?)
        i = from
        while i < expr.size
          char = expr[i]
          if q = quote
            quote = nil if char == q
          elsif char == '\'' || char == '"'
            quote = char
          elsif "[({".includes?(char)
            depth += 1
          elsif "])}".includes?(char)
            depth -= 1
          elsif depth == 0 && expr[i, keyword.size]? == keyword
            return i
          end
          i += 1
        end
        nil
      end

      # Check if expression contains a comparison operator *at the top
      # level* - depth/quote-aware, like top_level_keyword_index and the
      # +/- splitters below, rather than a plain substring search. A naive
      # substring check fires on an operator nested inside a paren'd sub-
      # expression too (linux-system-roles/logging's own rsyslog subrole:
      # `a + (b if (cond_len > 0) else []) + (c | flatten)`, where the `>`
      # belongs to the ternary's own condition, not a top-level comparison
      # of the whole plus-expression) - routing the *entire* expression
      # into ComparisonEvaluator in that case makes it split on the nested
      # operator using its own naive text split, producing a garbage
      # operand with an unbalanced trailing `)`. That operand, fed back
      # into the evaluator, permanently unbalances every depth-tracking
      # scanner downstream (split_top_level_plus, FilterEngine.split_chain)
      # - each returns the *unchanged* input as "the whole thing to
      # evaluate again" once it can never find its target token at depth
      # 0, and evaluate_expr/evaluate_with_filter call each other with
      # that identical string forever: a stack overflow, not just a wrong
      # answer.
      private def has_comparison?(expr : String) : Bool
        depth = 0
        quote = nil.as(Char?)
        i = 0
        while i < expr.size
          char = expr[i]
          if q = quote
            quote = nil if char == q
          elsif char == '\'' || char == '"'
            quote = char
          elsif "[({".includes?(char)
            depth += 1
          elsif "])}".includes?(char)
            depth -= 1
          elsif depth == 0 && top_level_comparison_char?(expr, i, char)
            return true
          end
          i += 1
        end
        false
      end

      private def top_level_comparison_char?(expr : String, i : Int32, char : Char) : Bool
        two = expr[i, 2]?
        two == "==" || two == "!=" || two == "<=" || two == ">=" || char == '>' || char == '<'
      end

      # Splits *expr* on every top-level `+` (outside quotes/brackets),
      # returning nil (not a two-part array) when there's no top-level `+`
      # at all so the caller's normal routing is untouched.
      private def split_top_level_plus(expr : String) : Array(String)?
        state = PlusSplitState.new
        expr.each_char { |char| split_top_level_plus_step(state, char) }
        state.parts << state.current.to_s.strip
        state.found? ? state.parts : nil
      end

      private class PlusSplitState
        property parts = [] of String
        property current = String::Builder.new
        property depth = 0
        property quote : Char? = nil
        property? found = false
      end

      private def split_top_level_plus_step(state : PlusSplitState, char : Char)
        if quote = state.quote
          state.current << char
          state.quote = nil if char == quote
          return
        end

        return split_top_level_plus_delimiter(state, char) if "'\"[](){}".includes?(char)

        if char == '+' && state.depth == 0
          state.parts << state.current.to_s.strip
          state.current = String::Builder.new
          state.found = true
        else
          state.current << char
        end
      end

      private def split_top_level_plus_delimiter(state : PlusSplitState, char : Char)
        case char
        when '\'', '"'
          state.quote = char
        when '[', '(', '{'
          state.depth += 1
        when ']', ')', '}'
          state.depth -= 1
        end
        state.current << char
      end

      # Resolves and concatenates/adds every operand of a top-level `+`
      # expression, left to right - array+array concatenates, string+string
      # concatenates, number+number adds; anything else falls back to
      # string concatenation of both sides' rendered form rather than
      # erroring.
      private def evaluate_plus(segments : Array(String)) : String
        values = segments.map { |seg| resolve_plus_operand(seg) }
        result = values.reduce { |acc, val| combine_plus(acc, val) }
        @lookup.format_value(result)
      end

      private def resolve_plus_operand(expr : String) : JSON::Any
        expr = expr.strip
        literal = quoted_string_literal(expr) || numeric_literal(expr)
        return literal if literal

        return parse_literal_array(expr) if expr.starts_with?('[') && expr.ends_with?(']')

        # A filter chain or parenthesized sub-expression operand (`acc |
        # default([])` in `acc | default([]) + [item]`) needs the full
        # recursive evaluator, not the plain variable lookup below, which
        # only ever resolves a bare/dotted/indexed name.
        if expr.includes?('|') || (expr.starts_with?('(') && expr.ends_with?(')'))
          rendered = evaluate(expr)
          return JSON.parse(rendered) rescue JSON::Any.new(rendered)
        end

        @lookup.resolve(expr) || JSON::Any.new(nil)
      end

      private def quoted_string_literal(expr : String) : JSON::Any?
        return nil if expr.size < 2
        return nil unless expr[0] == expr[-1] && (expr[0] == '\'' || expr[0] == '"')
        JSON::Any.new(expr[1..-2])
      end

      private def numeric_literal(expr : String) : JSON::Any?
        if int_val = expr.to_i64?
          JSON::Any.new(int_val)
        elsif float_val = expr.to_f64?
          JSON::Any.new(float_val)
        end
      end

      # A literal Jinja list (`['/dev', '/dev/shm']`) is valid Python/Jinja
      # syntax but not valid JSON on account of the single quotes - swapped
      # for double quotes before parsing, which is good enough for the
      # common case of a literal list of unquoted or simply-quoted string
      # items (this codebase's only real use of `+ [...]`).
      # A literal Jinja list (`['/dev', '/dev/shm']`, or `[item]` - a
      # single-element array wrapping a *variable* reference, dev-sec
      # os_hardening's own `acc | default([]) + [item]` accumulator
      # pattern) - each element is resolved the same way any other `+`
      # operand is (literal, or a variable/dotted/indexed lookup),
      # rather than requiring the whole thing to already be valid JSON
      # (which a bare identifier element like `item` never is).
      private def parse_literal_array(expr : String) : JSON::Any
        inner = expr[1..-2].strip
        return JSON::Any.new([] of JSON::Any) if inner.empty?

        elements = split_top_level_commas(inner).map { |elem| resolve_plus_operand(elem) }
        JSON::Any.new(elements)
      end

      private def split_top_level_commas(expr : String) : Array(String)
        state = PlusSplitState.new
        expr.each_char { |char| split_top_level_commas_step(state, char) }
        state.parts << state.current.to_s.strip
        state.parts
      end

      private def split_top_level_commas_step(state : PlusSplitState, char : Char)
        if quote = state.quote
          state.current << char
          state.quote = nil if char == quote
          return
        end

        return split_top_level_plus_delimiter(state, char) if "'\"[](){}".includes?(char)

        if char == ',' && state.depth == 0
          state.parts << state.current.to_s.strip
          state.current = String::Builder.new
        else
          state.current << char
        end
      end

      private def combine_plus(a : JSON::Any, b : JSON::Any) : JSON::Any
        case {a.raw, b.raw}
        when {Array, Array}
          JSON::Any.new(a.as_a + b.as_a)
        when {String, String}
          JSON::Any.new(a.as_s + b.as_s)
        when {Int64, Int64}
          JSON::Any.new(a.as_i64 + b.as_i64)
        when {Float64, Float64}
          JSON::Any.new(a.as_f + b.as_f)
        else
          JSON::Any.new(@lookup.format_value(a) + @lookup.format_value(b))
        end
      end

      # Finds the first top-level " - " (spaces required - see the
      # `evaluate` call site for why), outside quotes/brackets/parens,
      # and splits *expr* around it. nil if there's no such split point at
      # all (not a subtraction expression).
      private class QuoteDepthTracker
        property depth = 0
        property quote : Char? = nil

        def advance(char : Char)
          if q = quote
            self.quote = nil if char == q
            return
          end
          advance_unquoted(char)
        end

        private def advance_unquoted(char : Char)
          case char
          when '\'', '"'           then self.quote = char
          when '(', '[', '{'       then self.depth += 1
          when ')', ']', '}'       then self.depth -= 1
          end
        end

        def top_level? : Bool
          quote.nil? && depth == 0
        end
      end

      private def split_top_level_minus(expr : String) : {String, String}?
        tracker = QuoteDepthTracker.new
        expr.each_char.with_index do |char, i|
          tracker.advance(char)
          return {expr[0...i].strip, expr[(i + 1)..].strip} if tracker.top_level? && spaced_minus_at?(expr, i)
        end
        nil
      end

      private def spaced_minus_at?(expr : String, i : Int32) : Bool
        return false unless expr[i] == '-'
        i > 0 && expr[i - 1] == ' ' && i + 1 < expr.size && expr[i + 1] == ' '
      end

      # Resolves each side (same operand resolution `+` uses - a literal,
      # a variable, or a whole sub-expression with its own filter chain)
      # and subtracts them: two `to_datetime(...)`-tagged values produce a
      # timedelta, two numbers subtract normally, anything else is
      # undefined (unlike `+`, there's no sensible generic fallback for
      # `-`).
      private def evaluate_leading_paren(paren : {String, String}) : String
        inner, suffix = paren
        rendered = evaluate(inner.strip)
        return rendered if suffix.empty?

        parsed = JSON.parse(rendered) rescue JSON::Any.new(rendered)
        walk_part, filter_part = split_suffix_walk_and_filters(suffix)

        value = if walk_part.strip.empty?
                  parsed
                else
                  walked = @lookup.walk(parsed, walk_part)
                  return "undefined" unless walked
                  walked
                end

        return @lookup.format_value(value) if filter_part.strip.empty?

        segments = FilterEngine.split_chain(filter_part.strip)
        result = segments.reduce(value) { |acc, filter_expr| @filter.apply(acc, filter_expr) }
        @lookup.format_value(result)
      end

      # A leading-paren suffix (`(expr).foo[0] | bar(...)`) can carry a
      # dotted/indexed access portion, a `|`-chained filter pipeline, or
      # both - `@lookup.walk` only understands the former, so a suffix
      # that's a pure filter chain (dev-sec os_hardening's own
      # `((sysctl_config | combine(...)) | combine(...)) | combine(...)`,
      # where the leading-paren's own suffix is another `| combine(...)`)
      # previously went straight into `walk`, which had no `.attr`/`[idx]`
      # to find and returned nil, collapsing the whole expression to
      # "undefined". Splits at the first top-level `|` (respecting quotes/
      # bracket depth, same approach as FilterEngine.split_chain) so the
      # walk-able prefix and the filter-chain remainder are handled
      # separately.
      private def split_suffix_walk_and_filters(suffix : String) : {String, String}
        tracker = QuoteDepthTracker.new
        suffix.each_char.with_index do |char, i|
          tracker.advance(char)
          return {suffix[0...i], suffix[(i + 1)..]} if char == '|' && tracker.top_level?
        end
        {suffix, ""}
      end

      private def evaluate_minus(left_expr : String, right_expr : String) : String
        left = resolve_plus_operand(left_expr)
        right = resolve_plus_operand(right_expr)
        @lookup.format_value(combine_minus(left, right))
      end

      private def combine_minus(a : JSON::Any, b : JSON::Any) : JSON::Any
        if (a_epoch = datetime_epoch(a)) && (b_epoch = datetime_epoch(b))
          return timedelta(a_epoch - b_epoch)
        end

        case {a.raw, b.raw}
        when {Int64, Int64}
          JSON::Any.new(a.as_i64 - b.as_i64)
        when {Float64, Float64}
          JSON::Any.new(a.as_f - b.as_f)
        when {Int64, Float64}
          JSON::Any.new(a.as_i64.to_f64 - b.as_f)
        when {Float64, Int64}
          JSON::Any.new(a.as_f - b.as_i64.to_f64)
        else
          JSON::Any.new(nil)
        end
      end

      private def datetime_epoch(value : JSON::Any) : Int64?
        return nil unless value.raw.is_a?(Hash)
        value[FilterEngine::DATETIME_TAG]?.try(&.as_i64?)
      end

      # Python's real timedelta normalizes days/seconds/microseconds from
      # a raw second count; only `days` and `seconds` are modeled here (no
      # caller needs microseconds), and only for a non-negative delta -
      # every real use of this codebase's own `-` support subtracts an
      # earlier date from a later one.
      private def timedelta(diff_seconds : Int64) : JSON::Any
        JSON::Any.new({
          FilterEngine::TIMEDELTA_TAG => JSON::Any.new(true),
          "days"                      => JSON::Any.new(diff_seconds // 86400),
          "seconds"                   => JSON::Any.new(diff_seconds % 86400),
        })
      end

      # Finds the matching close paren for a leading "(" and splits
      # *expr* into {inner_without_parens, trailing_suffix} - nil if
      # *expr* doesn't start with "(" at all, or the leading "(" never
      # closes (malformed).
      private def split_leading_paren(expr : String) : {String, String}?
        return nil unless expr.starts_with?('(')

        depth = 0
        quote : Char? = nil

        expr.each_char.with_index do |char, i|
          if q = quote
            quote = nil if char == q
          elsif char == '\'' || char == '"'
            quote = char
          elsif char == '('
            depth += 1
          elsif char == ')'
            depth -= 1
            return {expr[1...i], expr[(i + 1)..]} if depth == 0
          end
        end

        nil
      end

      # Evaluate expression with a (possibly chained) filter pipeline.
      # Example: myvar | default('value'), or items | sort | join(',')
      #
      # Splits on *every* top-level `|` (not just the first), and resolves
      # the head expression to a real JSON::Any (an array/hash, not a
      # pre-stringified String) so FilterEngine can carry actual structure
      # from one filter to the next - `sort`'s real array output feeding
      # into `join`, not a JSON-encoded string `sort` had no choice but to
      # return before.
      private def evaluate_with_filter(expr : String) : String
        segments = FilterEngine.split_chain(expr)
        var_expr = segments[0]

        value = if var_expr.starts_with?('(') && var_expr.ends_with?(')')
                  # A parenthesized sub-expression as the chain's head -
                  # dev-sec os_hardening's sysctl merge nests filter chains
                  # this way: `((sysctl_config | combine(...)) |
                  # combine(...)) | combine(...)`. Recursing (stripping the
                  # outer pair) resolves each layer instead of treating the
                  # whole parenthesized text as a literal variable name -
                  # which always failed the lookup and silently collapsed
                  # the entire with_dict: source to nothing.
                  rendered = evaluate(var_expr[1..-2].strip)
                  JSON.parse(rendered) rescue JSON::Any.new(rendered)
                elsif var_expr.includes?("[")
                  # Array slicing (`list[0:2]`) and plain indexing
                  # (`list[0]`) aren't resolved to JSON::Any directly here
                  # (ArraySlicer/VariableLookup#indexed both still only
                  # return pre-formatted Strings) - fall back to the
                  # existing String-returning path and re-parse it, rather
                  # than duplicating that logic. "undefined" isn't valid
                  # JSON, so it maps to a real JSON null.
                  rendered = evaluate(var_expr)
                  JSON.parse(rendered) rescue JSON::Any.new(rendered)
                else
                  @lookup.resolve(var_expr) || JSON::Any.new(nil)
                end

        result = segments[1..].reduce(value) { |acc, filter_expr| @filter.apply(acc, filter_expr) }
        @lookup.format_value(result)
      end
    end
  end
end
