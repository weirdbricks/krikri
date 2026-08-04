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
        STDERR.puts "\n=== ExpressionEvaluator.evaluate ==="
        STDERR.puts "Expression: '#{expr}'"
        
        # Check for comparison operators FIRST (before filters)
        if has_comparison?(expr)
          STDERR.puts "Path: comparison"
          return @comparison.evaluate(expr)
        end
        
        # Check for filters (|)
        if expr.includes?("|")
          STDERR.puts "Path: filter"
          return evaluate_with_filter(expr)
        end
        
        # FIXED: Check for array slicing [: or :] pattern specifically
        # This must come BEFORE the general [ check
        if expr.includes?("[:") || expr.includes?(":]")
          STDERR.puts "Path: array slicing (matched [: or :])"
          return @slicer.slice(expr)
        end
        
        # Check for dictionary/list access
        if expr.includes?("[")
          STDERR.puts "Path: indexed access"
          return @lookup.indexed(expr)
        end
        
        # Check for nested access (.)
        if expr.includes?(".")
          STDERR.puts "Path: nested lookup"
          return @lookup.nested(expr)
        end
        
        # Simple variable lookup
        STDERR.puts "Path: simple lookup"
        @lookup.simple(expr)
      end
      
      # Check if expression contains comparison operators
      private def has_comparison?(expr : String) : Bool
        expr.includes?("==") || expr.includes?("!=") || 
        expr.includes?("<=") || expr.includes?(">=") ||
        (expr.includes?(">") && !expr.includes?(">=")) ||
        (expr.includes?("<") && !expr.includes?("<="))
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

        value = if var_expr.includes?("[")
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
