require "json"
require "./variable_substitutor/expression_evaluator"
require "./variable_substitutor/comparison_evaluator"
require "./variable_substitutor/filter_engine"
require "./variable_substitutor/array_slicer"
require "./variable_substitutor/variable_lookup"
require "./variable_substitutor/crinja_renderer"

module CrystalPlay
  # VariableSubstitutor - Main class for variable substitution
  # Uses modular components from variable_substitutor/ directory
  class VarSubstitutor
    @vars : Hash(String, JSON::Any)
    @host_name : String
    @evaluator : VariableSubstitutor::ExpressionEvaluator
    @renderer : VariableSubstitutor::CrinjaRenderer
    
    def initialize(vars : Hash(String, String | JSON::Any) = {} of String => String | JSON::Any, 
                   host_name : String = "localhost",
                   facts : Hash(String, JSON::Any) = {} of String => JSON::Any)
      @host_name = host_name
      
      # Convert all vars to JSON::Any
      @vars = Hash(String, JSON::Any).new
      vars.each do |key, value|
        @vars[key] = case value
        when JSON::Any
          value
        when String
          JSON::Any.new(value)
        else
          JSON.parse(value.to_json)
        end
      end
      
      # Add magic variables
      add_magic_variables(facts)
      
      # Initialize modular components
      @evaluator = VariableSubstitutor::ExpressionEvaluator.new(@vars)
      @renderer = VariableSubstitutor::CrinjaRenderer.new(@vars)
    end
    
    private def add_magic_variables(facts : Hash(String, JSON::Any))
      @vars["inventory_hostname"] = JSON::Any.new(@host_name)
      @vars["ansible_hostname"] = JSON::Any.new(@host_name)
      @vars["ansible_host"] = JSON::Any.new(@host_name)
      
      facts.each do |key, value|
        @vars["ansible_#{key}"] = value
      end
    end
    
    def substitute(text : String) : String
      return text unless text.includes?("{{")
      
      if text.includes?("{%") || text.includes?("{#")
        return @renderer.render(text)
      end
      
      pattern = /\{\{([^}]+)\}\}/

      # A single gsub pass instead of a loop of match+sub (which rescans
      # the *substituted* result from index 0 on every iteration - O(k*n)
      # for k placeholders, and would loop forever if a variable's own
      # value happened to contain "{{"). No existing behavior depends on
      # that recursive re-scan (grepped specs/compat playbooks for
      # nested {{ {{ - none), so this is a straight one-pass replacement.
      text.gsub(pattern) { |_, match| @evaluator.evaluate(match[1].strip).strip }
    end
    
    def substitute_hash(hash : Hash(String, String)) : Hash(String, String)
      result = Hash(String, String).new
      hash.each { |k, v| result[substitute(k)] = substitute(v) }
      result
    end
    
    def substitute_array(array : Array(String)) : Array(String)
      array.map { |item| substitute(item) }
    end
    
    def set_variable(name : String, value : String | JSON::Any)
      @vars[name] = value.is_a?(JSON::Any) ? value : JSON::Any.new(value)
      @evaluator = VariableSubstitutor::ExpressionEvaluator.new(@vars)
      @renderer = VariableSubstitutor::CrinjaRenderer.new(@vars)
    end
    
    def get_vars : Hash(String, JSON::Any)
      @vars
    end
    
    def has_variable?(name : String) : Bool
      @vars.has_key?(name)
    end
  end
end
