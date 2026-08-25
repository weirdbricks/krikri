require "crinja"
require "./crinja_renderer"

module CrystalPlay
  module VariableSubstitutor
    # A `Crinja::Context` backed directly by the raw `Hash(String,
    # JSON::Any)` variable scope, converting one entry to `Crinja::Value`
    # only when a template actually reads it - see
    # `CrinjaRenderer#build_lazy_context`'s own comment for why (turns
    # O(all vars) per renderer into O(vars a template actually
    # references), typically 1-5 out of a context that can run into the
    # thousands on a real hardening/collection role).
    #
    # Safe to subclass this way because `Crinja::Context < Crinja::Util::
    # ScopeMap(String, Crinja::Value)`, and `#[]`/`#has_key?` are the
    # ONLY two ScopeMap methods anything in `lib/crinja` ever calls on a
    # context (`Resolver#resolve` for `#[]`; the `{% from %}` import tag
    # for `#has_key?` - checked directly, not assumed, via `grep -rn
    # 'context\[|context\.has_key\?' lib/crinja/src`) - `keys`/`values`/
    # `entries`/`session_bindings` are never read, so a context that only
    # implements those two lazily is behaviorally identical to one that
    # eagerly materializes the whole scope up front.
    class LazyCrinjaContext < Crinja::Context
      def initialize(@raw_vars : Hash(String, JSON::Any), @substitutor : VarSubstitutor, parent : Crinja::Context? = nil)
        super(parent, nil)
      end

      # Precedence, matching the eager version's exact behavior (git
      # history - `finish_crinja_vars`): the "vars" magic dict always
      # wins over a real variable literally named "vars" (checked
      # first); a real variable always wins over the "omit" sentinel
      # default (checked only once `@raw_vars` itself doesn't have the
      # key, i.e. the old `vars["omit"] ||= ...`); a real variable is
      # otherwise looked up and memoized into `scope` on first read;
      # anything else falls through to the parent context (normally
      # `shared_env.context`, the process root - practically always
      # empty) or, failing that, Undefined.
      def [](key : String) : Crinja::Value
        if scope.has_key?(key)
          return scope[key]
        end

        if key == "vars"
          return scope[key] = build_vars_dict
        end

        if @raw_vars.has_key?(key)
          return scope[key] = convert(key)
        end

        if key == "omit"
          return scope[key] = Crinja::Value.new(CrystalPlay::OMIT_SENTINEL)
        end

        parent.try(&.[key]) || undefined
      end

      def has_key?(key : String) : Bool
        return true if scope.has_key?(key) || key == "vars" || key == "omit" || @raw_vars.has_key?(key)

        parent.try(&.has_key?(key)) || false
      end

      # `ScopeMap#keys` (and, in terms of it, the base class's own
      # `values`/`entries`/`has_value?`) is real - `lookup('varnames',
      # pattern)` (`jinja_filters.cr`'s own `env.context.keys.select {
      # ... }`) genuinely needs every variable NAME in scope to
      # pattern-match against, not just the ones some earlier expression
      # happened to read. The original "nothing in lib/crinja ever calls
      # keys/entries/values on a context" audit only grepped
      # `lib/crinja/src` - true for the vendored library itself, but
      # missed this codebase's OWN `lookup('varnames', ...)`
      # implementation, found the hard way when `crystal spec`'s full
      # suite (not this file in isolation - the pre-existing
      # require-ordering gap the isolation run hits masked it) caught 2
      # real failures. Returning just the NAMES (not converting every
      # value) keeps this cheap - O(N) string collection, not O(N) full
      # per-key conversion - so `varnames` stays correct without
      # reintroducing the eager-conversion cost this whole class exists
      # to avoid.
      def keys
        all = @raw_vars.keys
        all << "vars" unless all.includes?("vars")
        all << "omit" unless all.includes?("omit")

        if p = parent
          all += p.keys
        end

        all
      end

      private def convert(key : String) : Crinja::Value
        CrinjaRenderer.convert_var(@raw_vars[key], @substitutor, key)
      end

      # Real Ansible's `vars` magic variable - a dict of the whole
      # current scope, letting a template look up a DYNAMICALLY-COMPUTED
      # variable name (`vars['prefix_' + suffix]`) rather than a fixed
      # one. openstack.ansible-hardening's own audit-rule template does
      # exactly this (`vars['security_rhel7_audit_' + command_sanitized]
      # | bool`, picking which of ~40 individually-named enable/disable
      # flags applies to the audit rule currently being rendered).
      # Building this still means converting every entry of `@raw_vars`
      # (there's no way around that for a "give me the whole scope as a
      # dict" feature) - but only the ~2% of templates that actually
      # reference `vars` ever pay for it, and only once per renderer
      # (memoized into `scope["vars"]` above), matching the ~98% that
      # never do paying nothing at all. Converts straight from
      # `@raw_vars` via `#convert` (not through `self[key]`) so a
      # `@raw_vars` entry literally named "vars" doesn't recurse back
      # into this same method - matches the eager version's own
      # behavior, where the dict clone was taken from the
      # already-populated (but not yet "vars"-key-overwritten) working
      # hash.
      private def build_vars_dict : Crinja::Value
        dict = Crinja::Dictionary.new
        @raw_vars.each_key do |key|
          dict[Crinja::Value.new(key)] = scope.has_key?(key) ? scope[key] : (scope[key] = convert(key))
        end
        Crinja::Value.new(dict)
      end
    end
  end
end
