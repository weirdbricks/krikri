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

      # Depth of the whole-`vars`-dict materialization in progress (see
      # build_vars_dict): that pass resolves EVERY name whether the
      # template reads it or not, and ansible's top-level-fact
      # deprecation only fires for names a template actually reads, so
      # materialization must stay silent (otherwise any `vars`-using
      # template would deprecate every gathered fact at once). Keyed per
      # FIBER and a depth rather than one flag: a sibling host's genuine
      # read must keep warning while another host's template materializes
      # the dict, and preparing a var's own templated value during the
      # pass constructs further resolvers that can nest another
      # materialization, which must not clear its parent's guard on the
      # way out.
      @@materializing_vars = {} of Fiber => Int32

      def self.materializing_vars? : Bool
        (@@materializing_vars[Fiber.current]? || 0) > 0
      end

      def self.note_materializing_vars(delta : Int32) : Nil
        depth = (@@materializing_vars[Fiber.current]? || 0) + delta
        if depth > 0
          @@materializing_vars[Fiber.current] = depth
        else
          @@materializing_vars.delete(Fiber.current)
        end
      end

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
                  # ansible-core 2.21's internal-`vars`-dict deprecation
                  # (vars/manager.py's _DEPRECATE_VARS tag on the dict and
                  # every value inside it): resolving this name IS the
                  # tagged dict read, so this is where real prints the
                  # block - Origin'd at whatever value was being templated
                  # at that moment (VarSubstitutor#vars_dict_read_origin),
                  # issue #1028.
                  VarSubstitutor.emit_vars_dict_deprecation(VarSubstitutor.vars_dict_read_origin)
                  build_vars_dict
                elsif @raw_vars.has_key?(name)
                  # ansible-core 2.19.11 emits the play_hosts read
                  # deprecation each time the magic variable resolves, even
                  # reached through the `vars` dict's own materialization -
                  # both funnel through this per-name resolution. The
                  # Origin comes from the fiber's current render/param
                  # context (play_hosts_read_origin); reads with no
                  # reproducible Origin stay silent.
                  Krikri::ResultDisplay.emit_play_hosts_deprecation(VarSubstitutor.play_hosts_read_origin) if name == "play_hosts"
                  emit_fact_deprecation(name)
                  # A task `vars:` value that rendered eagerly at
                  # vars-context build recorded its fact readings for the
                  # render that CONSUMES it (see
                  # VarSubstitutor.capture_var_deprecations) - this
                  # resolution is that consuming render. Not during `vars`
                  # dict materialization: resolving every name to build the
                  # dict consumes nothing.
                  VarSubstitutor.flush_pending_var_deprecations(name) unless JinjaVarResolver.materializing_vars?
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

      # ansible-core 2.21 deprecates reading a gathered fact's top-level
      # `ansible_`-prefixed spelling (INJECT_FACTS_AS_VARS default). The
      # tag fires on an actual template READ - this per-name resolution -
      # and the warning's Origin is the position of whatever value real was
      # templating at that moment (VarSubstitutor#fact_read_origin).
      private def emit_fact_deprecation(name : String) : Nil
        return if JinjaVarResolver.materializing_vars?
        # See VarSubstitutor#emit_loop_item_fact_deprecation: a loop item
        # that IS a deprecated fact's own value trips the deprecation again
        # on every read, at this operation's own site.
        VarSubstitutor.emit_loop_item_fact_deprecation(name)
        return unless VarSubstitutor.top_level_fact_name?(name, @raw_vars)
        VarSubstitutor.emit_fact_deprecation(VarSubstitutor.fact_read_origin(name))
      end

      # Ansible's `vars` magic variable: the whole current scope as a
      # dict, for dynamically computed names (`vars['prefix_' + suffix]`).
      # It never contains itself, matching `'vars' in vars` being False.
      private def build_vars_dict : KrikriJinja::AnyValue
        dict = {} of String => KrikriJinja::AnyValue
        JinjaVarResolver.note_materializing_vars(1)
        begin
          @raw_vars.each_key do |key|
            next if key == "vars"
            # The materialization's own per-key fetch is NOT a read of the
            # fetched name: the `vars`-dict copy of `play_hosts` is
            # re-tagged with the vars deprecate tag in ansible-core 2.21
            # (vars/manager.py), replacing the play_hosts one, so
            # consuming the dict never warns about play_hosts - only a
            # VALUE whose own template text reads the name does, and that
            # read goes through the normal #resolve from the per-key
            # preparation below (live-verified against 2.21.6: `{{
            # vars | length }}` prints no play_hosts block, while a stored
            # `d1: "{{ play_hosts }}"` inside the dumped dict prints one).
            # The fetch also stays UNCACHED, so a later template READ of
            # the name still resolves - and warns - like real.
            value = if key == "play_hosts"
                      @cache[key]? || convert(key)
                    else
                      resolve(key)
                    end
            dict[key] = value if value && !value.raw.is_a?(KrikriJinja::Undefined)
          end
        ensure
          JinjaVarResolver.note_materializing_vars(-1)
        end
        KrikriJinja::AnyValue.new(dict)
      end
    end
  end
end
