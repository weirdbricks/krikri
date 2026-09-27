require "json"

module Krikri
  module VariableSubstitutor
    # Per-host variable context for `hostvars[<other host>]` values.
    #
    # Real Ansible renders a value read through `hostvars['other']` with
    # THAT host's own templar (HostVarsVars): the value's `{{ myname }}`
    # resolves against the other host's inventory vars/facts/registered
    # vars/inventory_hostname, never the reading host's. This engine's
    # re-render funnels (Rerender, ExpressionEvaluator's plain-lookup
    # re-render, the span re-pass, JinjaRenderer.prepare_hostvars) all
    # rendered with the CURRENT host's scope - found via a two-host
    # inventory where `who: "{{ myname }}"` read through
    # `hostvars['h2'].who` came back with the reading host's `myname`.
    #
    # The rendering scope built here is the other host's own entry
    # (inventory vars + facts + registered vars + inventory_hostname, as
    # assembled by TaskExecutor#build_hostvars) laid OVER the reading
    # host's scope: entry keys win, everything the entry does not carry
    # (play/role vars, shared magic vars like groups/playbook_dir,
    # hostvars itself) falls back to the reading host's scope - for two
    # hosts in the same play those are identical in real Ansible, and the
    # entry carries every per-host difference. Lookups are unaffected:
    # `hostvars['h2'].missing_key` still resolves against the raw entry
    # alone (undefined), exactly as before - only the re-render of a
    # value that WAS found uses this scope.
    #
    # Unsafe-data semantics stay per host: the merged scope's
    # inventory_hostname (and therefore its resolved-var-name registry
    # via VarSubstitutor.host_from_vars) is the OTHER host's, so its own
    # registered results/set_facts stay execution-resolved (never
    # re-rendered) while the reading host's registry does not silence
    # the other host's author vars. The value-level registry
    # (UnsafeValues.unsafe_text?) is process-global text matching and
    # already guards hostile content relayed through hostvars either way.
    module HostvarsContext
      # Identity-keyed cache: (raw entry hash, reading scope hash) pair ->
      # merged scope. Both objects are rebuilt by the executor whenever
      # the underlying vars change (hostvars per hv_generation, the vars
      # context per task), so a stale pair can never be served: the
      # cache holds strong references to both objects and validates
      # identity on every hit. Capped because the pair is rebuilt per
      # task/generation - a long run would otherwise accumulate dead
      # keys; clearing just costs one rebuild.
      @@cache = {} of {UInt64, UInt64} => Tuple(Hash(String, JSON::Any), Hash(String, JSON::Any), Hash(String, JSON::Any))
      MAX_CACHE_ENTRIES = 256

      # Whether *source_expr* reads a hostvars entry key that is
      # execution-resolved for the OWNING host (its registered results /
      # set_facts / facts) - such values are execution data and must
      # never be re-rendered, even though the READING host's own registry
      # knows nothing of the name.
      def self.origin_unsafe?(vars : Hash(String, JSON::Any)?, source_expr : String?) : Bool
        return false unless hk = origin_host_and_key(vars, source_expr)
        VarSubstitutor.resolved_var_name?(hk[0], hk[1])
      end

      # #origin_host plus the first ENTRY-LEVEL key the expression reads
      # (`hostvars['h2'].r.stdout` -> {"h2", "r"}) - the name the OTHER
      # host's unsafe-name registry is consulted on, since registered
      # results/set_facts are execution data and must never be re-rendered
      # no matter which host reads them.
      def self.origin_host_and_key(vars : Hash(String, JSON::Any)?, source_expr : String?) : {String, String}?
        host_text, rest = access_head(vars, source_expr) || return nil
        host = validated_host(host_text, vars) || return nil

        rest = rest.lstrip
        key = if rest.starts_with?('[')
                close = matching_bracket_close(rest, 0) || return {host, ""}
                inner = rest[1...close].strip
                quoted_literal(inner) || resolve_key_expr(inner, vars) || ""
              elsif rest.starts_with?('.')
                attr_key(rest)
              else
                ""
              end
        {host, key || ""}
      end

      # The other host whose entry *source_expr* reads through, when the
      # expression is rooted at the hostvars magic variable:
      # `hostvars['h2'].who`, `hostvars[item]['nm']`, `hostvars.h2.nm`.
      # The first bracket/attr key is resolved (a quoted literal directly,
      # anything else through the evaluator, so `hostvars[item]` in a loop
      # works), then validated against the actual hostvars hash - a plain
      # variable the play happens to name "hostvars" is not treated as
      # the magic (its entries would not carry the inventory_hostname
      # marker the executor always writes). nil for every other shape:
      # those keep the pre-existing current-scope rendering.
      def self.origin_host(vars : Hash(String, JSON::Any)?, source_expr : String?) : String?
        origin_host_and_key(vars, source_expr).try(&.[0])
      end

      # Splits a hostvars-rooted expression into its first access key's
      # source text and the remainder of the expression - nil unless the
      # expression really is `hostvars` followed by a bracket index or an
      # attribute access.
      private def self.access_head(vars : Hash(String, JSON::Any)?, source_expr : String?) : {String, String}?
        return nil unless vars && source_expr
        expr = source_expr.strip
        expr = FilterEngine.split_chain(expr).first? || return nil
        return nil unless expr.starts_with?("hostvars")
        rest = expr[8..]?.try(&.lstrip) || return nil

        if rest.starts_with?('[')
          close = matching_bracket_close(rest, 0) || return nil
          {rest[1...close].strip, rest[(close + 1)..]}
        elsif rest.starts_with?('.')
          host_text = attr_key(rest)
          return nil if host_text.empty?
          {host_text, rest[(1 + host_text.size)..]}
        end
      end

      # The dotted-attribute spelling of a key (`hostvars.h2`) - up to the
      # next `.` or `[`.
      private def self.attr_key(rest : String) : String
        rest[1..].each_char.take_while { |char| char != '.' && char != '[' }.join.strip
      end

      # Resolves the host key text and validates the entry it names is the
      # hostvars magic's own (the inventory_hostname marker).
      private def self.validated_host(key_text : String, vars : Hash(String, JSON::Any)) : String?
        return nil if key_text.empty?
        host = quoted_literal(key_text) || resolve_key_expr(key_text, vars) || return nil
        entry = vars["hostvars"]?.try(&.as_h?).try(&.[host]?).try(&.as_h?) || return nil
        return nil unless entry["inventory_hostname"]?.try(&.as_s?) == host
        host
      end

      # The other host's rendering scope: its raw entry laid over the
      # reading host's vars (entry wins), with inventory_hostname pinned
      # to the other host so the per-host unsafe-name registry resolves
      # correctly even for an entry that lacks the marker. nil when
      # *host* has no hostvars entry (the caller then keeps the current
      # scope, the pre-existing behavior).
      def self.merged_vars(host : String, vars : Hash(String, JSON::Any)) : Hash(String, JSON::Any)?
        entry = vars["hostvars"]?.try(&.as_h?).try(&.[host]?).try(&.as_h?) || return nil

        key = {entry.object_id, vars.object_id}
        if (cached = @@cache[key]?) && cached[0].same?(entry) && cached[1].same?(vars)
          return cached[2]
        end
        @@cache.clear if @@cache.size >= MAX_CACHE_ENTRIES

        merged = vars.dup
        entry.each { |name, value| merged[name] = value }
        merged["inventory_hostname"] = JSON::Any.new(host)
        @@cache[key] = {entry, vars, merged}
        merged
      end

      # A VarSubstitutor rendering as the other host - same merged scope,
      # with the substitutor's own host identity (and therefore its
      # unsafe-name registry lookups) pointed at the other host.
      def self.substitutor_for(host : String, vars : Hash(String, JSON::Any)) : VarSubstitutor
        if merged = merged_vars(host, vars)
          VarSubstitutor.new(vars: merged, host_name: host)
        else
          VarSubstitutor.new(vars: vars, host_name: host)
        end
      end

      # The same, but nil when *host* has no hostvars entry - for call
      # sites that must fall back to their pre-existing behavior instead
      # of rendering in a guessed scope.
      def self.substitutor_for?(host : String, vars : Hash(String, JSON::Any)?) : VarSubstitutor?
        return nil unless vars
        return nil unless merged_vars(host, vars)
        substitutor_for(host, vars)
      end

      private def self.quoted_literal(text : String) : String?
        if text.size >= 2 && ((text[0] == '\'' && text[-1] == '\'') || (text[0] == '"' && text[-1] == '"'))
          text[1...-1]
        end
      end

      # A dynamic host key (`hostvars[item]`, `hostvars[groups['db'][0]]`)
      # - evaluated against the reading host's scope. A key that does not
      # evaluate to a string (or fails to evaluate at all) yields nil and
      # the caller falls back to current-scope rendering.
      private def self.resolve_key_expr(key_text : String, vars : Hash(String, JSON::Any)) : String?
        rendered = begin
          ExpressionEvaluator.new(vars).evaluate(key_text)
        rescue
          return nil
        end
        parsed = Krikri.parse_json_or_python_literal(rendered)
        parsed.as_s? || rendered.strip
      end

      private def self.matching_bracket_close(text : String, open_pos : Int32) : Int32?
        depth = 0
        quote : Char? = nil

        (open_pos...text.size).each do |i|
          char = text[i]
          if q = quote
            quote = nil if char == q
          elsif char == '\'' || char == '"'
            quote = char
          elsif "([{".includes?(char)
            depth += 1
          elsif ")]}".includes?(char)
            depth -= 1
            return i if depth == 0 && char == ']'
          end
        end

        nil
      end
    end
  end
end
