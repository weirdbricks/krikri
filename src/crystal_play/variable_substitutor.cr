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
      
      result = text.dup
      pattern = /\{\{([^}]+)\}\}/
      
      loop do
        match = result.match(pattern)
        break unless match
        
        full_match = match[0]
        expression = match[1].strip
        value = @evaluator.evaluate(expression)
        result = result.sub(full_match, value.strip)
      end
      
      result
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
