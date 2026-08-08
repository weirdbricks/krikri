require "json"
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
        @filter = FilterEngine.new
        @slicer = ArraySlicer.new(@vars)
        @lookup = VariableLookup.new(@vars)
      end
      
      # Evaluate any expression and return string result
      def evaluate(expr : String) : String
        # Check for comparison operators FIRST (before filters)
        if has_comparison?(expr)
          return @comparison.evaluate(expr)
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

        # FIXED: Check for array slicing [: or :] pattern specifically
        # This must come BEFORE the general [ check
        if expr.includes?("[:") || expr.includes?(":]")
          return @slicer.slice(expr)
        end

        # Check for dictionary/list access
        if expr.includes?("[")
          return @lookup.indexed(expr)
        end

        # Check for nested access (.)
        if expr.includes?(".")
          return @lookup.nested(expr)
        end

        # Simple variable lookup
        @lookup.simple(expr)
      end
      
      # Check if expression contains comparison operators
      private def has_comparison?(expr : String) : Bool
        expr.includes?("==") || expr.includes?("!=") || 
        expr.includes?("<=") || expr.includes?(">=") ||
        (expr.includes?(">") && !expr.includes?(">=")) ||
        (expr.includes?("<") && !expr.includes?("<="))
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
