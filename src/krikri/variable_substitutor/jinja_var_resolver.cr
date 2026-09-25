require "json"
require "krikri_jinja"
require "./crinja_renderer"

module Krikri
  module VariableSubstitutor
    # Supplies a renderer's variable scope to krikri-jinja one name at a
    # time, preparing each value (recursive re-templating, undefined
    # detection) only when an expression actually reads it. Scopes run into
    # the thousands of entries on a real hardening role while an expression
    # reads a handful, so converting eagerly would dominate evaluation.
    #
    # Precedence matches the Crinja context this replaces: the `vars` magic
    # dict wins over a real variable named "vars"; a real variable wins over
    # the `omit` sentinel; anything else is left to the engine's globals and
    # then its undefined value.
    class JinjaVarResolver < KrikriJinja::VariableResolver
      @cache = {} of String => KrikriJinja::AnyValue

      def initialize(@raw_vars : Hash(String, JSON::Any), @substitutor : VarSubstitutor)
      end

      def resolve(name : String) : KrikriJinja::AnyValue?
        if cached = @cache[name]?
          return cached
        end
        value = if name == "vars"
                  build_vars_dict
                elsif @raw_vars.has_key?(name)
                  convert(name)
                elsif name == "omit"
                  KrikriJinja::AnyValue.new(Krikri::OMIT_SENTINEL)
                end
        @cache[name] = value if value
        value
      end

      private def convert(name : String) : KrikriJinja::AnyValue
        raw = @raw_vars[name]
        prepared = if name == "hostvars"
                     CrinjaRenderer.prepare_hostvars(raw, @substitutor)
                   else
                     CrinjaRenderer.prepare_var(raw, @substitutor, name)
                   end
        return KrikriJinja::AnyValue.new(KrikriJinja::Undefined.new(name)) unless prepared
        KrikriJinja.from_json_any(prepared)
      end

      # Real Ansible's `vars` magic variable: the whole current scope as a
      # dict, for dynamically computed names (`vars['prefix_' + suffix]`).
      # It never contains itself, matching `'vars' in vars` being False.
      private def build_vars_dict : KrikriJinja::AnyValue
        dict = {} of String => KrikriJinja::AnyValue
        @raw_vars.each_key do |key|
          next if key == "vars"
          value = resolve(key)
          dict[key] = value if value && !value.raw.is_a?(KrikriJinja::Undefined)
        end
        KrikriJinja::AnyValue.new(dict)
      end
    end
  end
end
