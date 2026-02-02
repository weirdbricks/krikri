require "json"
require "crinja"

module CrystalPlay
  module VariableSubstitutor
    # CrinjaRenderer - Handles full Jinja2 template rendering using Crinja
    # This includes {% if %}, {% for %}, {% set %}, etc.
    # FIXED: Enhanced debugging to diagnose rendering issues
    class CrinjaRenderer
      @vars : Hash(String, JSON::Any)
      
      def initialize(@vars : Hash(String, JSON::Any))
      end
      
      # Render a template containing Jinja2 control structures
      def render(text : String) : String
        # DEBUG: Show that we're rendering
        STDERR.puts "\n=== CrinjaRenderer.render called ==="
        STDERR.puts "Text length: #{text.size}"
        STDERR.puts "Contains {%: #{text.includes?("{%")}"
        STDERR.puts "First 150 chars: #{text[0...150]}"
        
        begin
          env = Crinja.new
          
          # Configure Crinja
          env.config.trim_blocks = true
          env.config.lstrip_blocks = false
          
          # Prepare template variables for Crinja
          template_vars = prepare_crinja_vars
          
          STDERR.puts "Prepared #{template_vars.size} variables for Crinja"
          
          # Render with Crinja
          template = env.from_string(text)
          rendered = template.render(template_vars)
          
          STDERR.puts "Rendering succeeded!"
          STDERR.puts "Output length: #{rendered.size}"
          STDERR.puts "First 150 chars: #{rendered[0...150]}"
          STDERR.puts "=== End CrinjaRenderer.render ===\n"
          
          return rendered
        rescue ex
          # Enhanced error reporting
          STDERR.puts "\n!!! ERROR: Crinja rendering failed !!!"
          STDERR.puts "Error: #{ex.message}"
          STDERR.puts "Error class: #{ex.class}"
          STDERR.puts "Template text (first 200 chars): #{text[0...200]}"
          STDERR.puts "Backtrace:"
          ex.backtrace.first(5).each do |line|
            STDERR.puts "  #{line}"
          end
          STDERR.puts "=== End CrinjaRenderer.render (FAILED) ===\n"
          
          # Return original text on failure
          return text
        end
      end
      
      # Prepare variables for Crinja rendering
      private def prepare_crinja_vars : Hash(String, Crinja::Value)
        vars = Hash(String, Crinja::Value).new
        
        STDERR.puts "\n--- Preparing Crinja variables ---"
        STDERR.puts "Total variables: #{@vars.size}"
        
        @vars.each do |key, value|
          # Show what we're adding (truncate long values)
          value_preview = value.to_s[0...50]
          STDERR.puts "  #{key}: #{value_preview}#{value.to_s.size > 50 ? "..." : ""}"
          
          vars[key] = json_any_to_crinja_value(value)
        end
        
        STDERR.puts "--- End variable preparation ---\n"
        
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
