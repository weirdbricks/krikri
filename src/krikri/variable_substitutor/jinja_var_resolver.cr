require "json"
require "krikri-jinja/krikri_jinja"
require "./jinja_renderer"

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

      # *strict*: the probe-style engine evaluations (evaluate_structured
      # with strict: true) need a demoted unresolvable value to reach the
      # engine as a STRICT Undefined, so consuming it (`~` concat,
      # arithmetic) raises there the way real Jinja's strict undefined
      # does - the lenient render path must keep stringifying to "",
      # and `default()`-tolerated shapes must stay tolerated
      # (live-verified vs 2.19.11: `badvar: "{{ undefined_deep }}"`
      # fails `"{{ 'a' ~ badvar ~ 'b' }}"` arg finalization but renders
      # `"{{ badvar | default('x') }}"` fine). Without the flag the probe
      # evaluation silently stringified the demoted value and the chain
      # failure never surfaced.
      def initialize(@raw_vars : Hash(String, JSON::Any), @substitutor : VarSubstitutor, @strict : Bool = false)
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
                     JinjaRenderer.prepare_hostvars(raw, @substitutor)
                   else
                     JinjaRenderer.prepare_var(raw, @substitutor, name)
                   end
        if @strict
          return KrikriJinja::AnyValue.new(KrikriJinja::StrictUndefined.new(name, chainable: true)) unless prepared
        else
          return KrikriJinja::AnyValue.new(KrikriJinja::Undefined.new(name)) unless prepared
        end
        KrikriJinja.from_json_any(prepared)
      end

      # Ansible's `vars` magic variable: the whole current scope as a
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
