require "json"
require "crinja"

module CrystalPlay
  module VariableSubstitutor
    # CrinjaRenderer - Handles full Jinja2 template rendering using Crinja
    # This includes {% if %}, {% for %}, {% set %}, etc.
    class CrinjaRenderer
      @vars : Hash(String, JSON::Any)
      @template_vars : Hash(String, Crinja::Value)?

      def initialize(@vars : Hash(String, JSON::Any))
      end

      # One Crinja environment for the whole process, built on first use.
      # The configuration applied to it is two hardcoded literals that
      # never vary, yet `Crinja.new` was previously paid on *every*
      # `{% %}` render - roughly half the cost of the most expensive
      # thing the substitutor does.
      #
      # Reusing one environment across renders is safe because
      # `Template#render` calls `env.with_scope(bindings)`, which pushes a
      # *child* Context, merges only that render's bindings into it, and
      # restores the former context in an `ensure` - so no variable, and
      # no top-level `{% set %}`, leaks from one render into the next.
      #
      # The invariant this does rely on: rendering never yields the
      # fiber. Crinja's parse/render path is pure CPU with no I/O, and
      # under Crystal's cooperative scheduling only one fiber runs at any
      # instant, so concurrent hosts (--forks) can never interleave two
      # renders and swap each other's context out mid-flight. If a filter
      # or function that performs I/O is ever added, this must become
      # per-fiber (see OutputRouting for that pattern) rather than global.
      @@env : Crinja?

      private def shared_env : Crinja
        if existing = @@env
          return existing
        end

        env = Crinja.new
        env.config.trim_blocks = true
        env.config.lstrip_blocks = false
        @@env = env
      end

      # Render a template containing Jinja2 control structures
      def render(text : String) : String
        # @vars is fixed for the lifetime of a renderer (VarSubstitutor
        # #set_variable constructs a new renderer rather than mutating),
        # so the recursive JSON::Any -> Crinja::Value conversion of the
        # entire variable context is done once per renderer instead of
        # once per render - a task with several templated params renders
        # more than once.
        template_vars = (@template_vars ||= prepare_crinja_vars)

        template = shared_env.from_string(text)
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
      
      private def json_any_to_crinja_value(json : JSON::Any) : Crinja::Value
        CrinjaRenderer.json_any_to_crinja_value(json)
      end

      # Convert JSON::Any to Crinja::Value.
      #
      # Exposed as a class method because TemplateActionPlugin needs the
      # exact same coercion and used to carry a verbatim copy of it.
      # (Only the *converter* is shared: that plugin's Crinja environment
      # genuinely must stay separate, since its trim_blocks/lstrip_blocks
      # come from the task's own template: params and therefore vary per
      # task - unlike this class's, whose config is invariant and so can
      # be one process-wide instance.)
      def self.json_any_to_crinja_value(json : JSON::Any) : Crinja::Value
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
