require "json"
require "crinja"

module CrystalPlay
  module VariableSubstitutor
    # CrinjaRenderer - Handles full Jinja2 template rendering using Crinja
    # This includes {% if %}, {% for %}, {% set %}, etc.
    class CrinjaRenderer
      @vars : Hash(String, JSON::Any)
      
      def initialize(@vars : Hash(String, JSON::Any))
      end
      
      # Render a template containing Jinja2 control structures
      def render(text : String) : String
        env = Crinja.new

        # Configure Crinja
        env.config.trim_blocks = true
        env.config.lstrip_blocks = false

        # Prepare template variables for Crinja
        template_vars = prepare_crinja_vars

        # Render with Crinja
        template = env.from_string(text)
        template.render(template_vars)
      rescue
        # Return original text on failure
        text
      end

      # Prepare variables for Crinja rendering
      private def prepare_crinja_vars : Hash(String, Crinja::Value)
        vars = Hash(String, Crinja::Value).new

        @vars.each do |key, value|
          vars[key] = json_any_to_crinja_value(value)
        end

        vars
      end
      
      # Convert JSON::Any to Crinja::Value
      private def json_any_to_crinja_value(json : JSON::Any) : Crinja::Value
        case json.raw
        when String
          Crinja::Value.new(json.as_s)
        when Int64
          Crinja::Value.new(json.as_i)
        when Float64
          Crinja::Value.new(json.as_f)
        when Bool
          Crinja::Value.new(json.as_bool)
        when Nil
          Crinja::Value.new(nil)
        when Hash
          hash = Hash(String, Crinja::Value).new
          json.as_h.each do |key, value|
            hash[key] = json_any_to_crinja_value(value)
          end
          Crinja::Value.new(hash)
        when Array
          array = json.as_a.map { |item| json_any_to_crinja_value(item) }
          Crinja::Value.new(array)
        else
          Crinja::Value.new(json.to_s)
        end
      end
    end
  end
end
