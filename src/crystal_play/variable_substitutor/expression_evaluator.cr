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
      
      # Evaluate expression with filter
      # Example: myvar | default('value')
      private def evaluate_with_filter(expr : String) : String
        parts = expr.split("|", 2)
        var_expr = parts[0].strip
        filter_expr = parts[1].strip
        
        # Get the variable value (recursively evaluate if complex)
        value = if var_expr.includes?("[") || var_expr.includes?(".")
          evaluate(var_expr)
        else
          @lookup.simple(var_expr)
        end
        
        # Apply filter
        @filter.apply(value, filter_expr)
      end
    end
  end
end
