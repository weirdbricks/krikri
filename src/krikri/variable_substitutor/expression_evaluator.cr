require "json"
require "../unsafe_values"
require "base64"
require "http/client"
require "uri"
require "../conditional_evaluator"
require "./comparison_evaluator"
require "./filter_engine"
require "./array_slicer"
require "./variable_lookup"
require "./jinja_renderer"
require "../python_lookup_runner"
require "./undefined"
require "../variable_substitutor"
require "../lookups/lookup_dispatch"
require "../lookups/lookup_scalar"
require "../lookups/lookup_file"
require "../lookups/lookup_list"
require "../lookups/lookup_misc"
require "../lookups/lookup_first_found"

module Krikri
  module VariableSubstitutor
    # ExpressionEvaluator - Orchestrates evaluation of all expression types
    # Delegates to specialized evaluators based on expression type
    class ExpressionEvaluator
      @vars : Hash(String, JSON::Any)
      @comparison : ComparisonEvaluator
      @filter : FilterEngine
      @slicer : ArraySlicer
      @lookup : VariableLookup
      @jinja_renderer : VariableSubstitutor::JinjaRenderer?
      # When true this evaluator resolves its Crinja-delegated operands
      # (method-call args like `.split('\n')`, `~` concat operands) against
      # the decoding environment instead of the inline verbatim one - set
      # only for the conditional/assert path by ConditionalEvaluator.
      @decode : Bool

      def initialize(@vars : Hash(String, JSON::Any), @decode : Bool = false)
        @comparison = ComparisonEvaluator.new(@vars)
        @filter = FilterEngine.new(@vars)
        @slicer = ArraySlicer.new(@vars)
        @lookup = VariableLookup.new(@vars)
      end

      # Built lazily - most `{{ }}` spans never reach the boolean_logic?
      # branch below, so most `ExpressionEvaluator`s never need this.
      private def jinja_renderer : VariableSubstitutor::JinjaRenderer
        @jinja_renderer ||= VariableSubstitutor::JinjaRenderer.new(@vars, @decode)
      end

      # Guards the Crinja-first delegation branches below against
      # genuine infinite recursion: `JinjaRenderer#prepare_crinja_vars`
      # re-templates any variable whose OWN value still contains `{{` by
      # building a fresh `VarSubstitutor`/`ExpressionEvaluator` and
      # calling back into `#evaluate` - if THAT evaluation also delegates
      # to Crinja (any of the branches below), it builds ANOTHER fresh
      # `JinjaRenderer`, which calls `prepare_crinja_vars` again on the
      # same variables, which re-templates again, forever - each level
      # constructing entirely new objects, so no single instance's own
      # state could ever detect the cycle. Real crash found by this
      # session's own `crystal spec` run immediately after adding the
      # comparison-operator delegation branch (a variable holding a
      # still-templated comparison as its default value). Same shape of
      # bug, and same fix (a process-wide depth counter, not a per-
      # instance one, since every recursion level IS a new instance), as
      # `VarSubstitutor`'s own pre-existing `@@block_tag_escalation_
      # depth` guard - see that class's own comment for the fuller
      # rationale (cloudalchemy.grafana's `grafana_package:` stack
      # overflow, round 3).
      @@crinja_delegation_depth = 0
      MAX_CRINJA_DELEGATION_DEPTH = 20

      private def render_via_jinja(expr : String) : String
        raise "crinja delegation depth exceeded" if @@crinja_delegation_depth >= MAX_CRINJA_DELEGATION_DEPTH
        @@crinja_delegation_depth += 1
        begin
          jinja_renderer.render!("{{ #{expr} }}")
        ensure
          @@crinja_delegation_depth -= 1
        end
      end

      # Same delegation-depth guard as #render_via_jinja, but returns
      # Crinja's RAW structured result (nil for undefined) instead of a
      # pre-stringified String - see `JinjaRenderer#evaluate_value!`'s
      # own comment for the full "why" (this codebase's internal
      # render-then-`JSON.parse`-back round trip breaks if a container-
      # valued Crinja result is stringified via Crinja's own Python-repr
      # `Finalizer` instead of this codebase's JSON-compact
      # `VariableLookup#format_value`). Any construct whose result might
      # be an Array/Hash (not just a scalar) must go through this, not
      # #render_via_jinja directly - constructs 1-6 (boolean/and/or/is,
      # ternary, comparisons, bare literals, `~`, `*`/`/`/`//`) don't
      # need it, since every one of them is provably scalar-only
      # (verified via extensive empirical probing during their own
      # convergence - none produce a container result).
      private def render_via_jinja_value(expr : String) : JSON::Any?
        raise "crinja delegation depth exceeded" if @@crinja_delegation_depth >= MAX_CRINJA_DELEGATION_DEPTH
        @@crinja_delegation_depth += 1
        begin
          jinja_renderer.evaluate_value!(expr)
        ensure
          @@crinja_delegation_depth -= 1
        end
      end

      # Structured (raw JSON::Any) evaluation of a full expression, for
      # callers outside this class - Krikri.bracket_index_failure_message's
      # strict-probe use (round 812045, pluggero.bibata_cursor), which must
      # see a JSON-null result as a real None value, not as the
      # "undefined"-sentinel string the String-returning #evaluate collapses
      # it to. Deliberately does NOT rescue: the caller decides what a
      # Crinja failure means on its own path.
      def evaluate_structured(expr : String) : JSON::Any?
        render_via_jinja_value(expr)
      end

      # #render_via_jinja_value, formatted through this codebase's own
      # `VariableLookup#format_value` (not Crinja's `Finalizer`) - the
      # convenience form for a call site that ultimately wants a String
      # (matching #render_via_jinja's signature) without losing the
      # format-consistency fix that method exists for.
      private def render_via_jinja_string(expr : String) : String
        value = render_via_jinja_value(expr)
        value ? @lookup.format_value(value) : "undefined"
      end

      # #render_via_jinja, but re-routed through the JSON-compact
      # `#render_via_jinja_string` path ONLY when the result is
      # actually a container - every other scalar case keeps
      # #render_via_jinja's own stringification untouched. A ternary's
      # chosen branch can be an arbitrary sub-expression - a filter chain
      # producing a real Array (`x | regex_findall(...) if y else []`,
      # RedHatOfficial.rhel8_pci_dss's own "Set gpgcheck=1 for each yum
      # repo" loop source) is a real counter-example to this file's own
      # "ternary is provably scalar-only" claim near
      # #render_via_jinja_value. Plain #render_via_jinja alone stringifies
      # a container result through Crinja's own Python-repr Finalizer
      # (`[['a.repo', 'sec1'], ...]`, single-quoted, not valid JSON)
      # instead of this codebase's JSON-compact `VariableLookup#format_
      # value` - the internal render-then-`JSON.parse`-back round trip
      # every loop-template caller relies on (`resolve_loop_template`'s
      # own `parse_list_result`) then fails to parse it, falls through to
      # the array-wrapped scalar fallback, and the WHOLE unparsed repr
      # string became ONE loop item instead of the real list of tuples.
      #
      # `undefined_sentinel` controls what an UNDEFINED result renders as.
      # A ternary WITH an else clause whose CHOSEN branch is undefined
      # (`missing_var if bool_true else 'x'`) renders the codebase's
      # standard "undefined" sentinel - the same thing a bare undefined
      # reference produces on both evaluator entry points (VariableLookup,
      # `JinjaRenderer#evaluate_value!`'s nil convention) - not the empty
      # string the krikri-jinja render Finalizer produces for a top-level
      # Undefined, which made the two entry points disagree with each
      # other (found by bin/differential_fuzz; Ansible fails the task
      # in either shape under StrictUndefined). The else-less ternary
      # (`TRUTHY if COND` with a FALSE cond) passes false and keeps the
      # Finalizer's "": there the empty render is load-bearing for real
      # roles (ansible-community.ansible-vault's `{{ '+ent' if
      # vault_enterprise }}{{ '.hsm' if vault_enterprise_hsm }}` suffix
      # concatenation must NOT grow a literal "undefined" text).
      private def render_via_jinja_container_safe(expr : String, undefined_sentinel : Bool = true) : String
        value = render_via_jinja_value(expr)
        raw = value.try(&.raw)
        return @lookup.format_value(value.not_nil!) if raw.is_a?(Array) || raw.is_a?(Hash)
        return "undefined" if value.nil? && undefined_sentinel
        render_via_jinja(expr)
      end

      # #evaluate, but formatting a CONTAINER result the way Ansible
      # renders one into final text - Python's `repr` (`['a', 'b']`),
      # not this codebase's internal JSON-compact form (`["a","b"]`).
      #
      # Deliberately narrow: only a plain variable reference (bare,
      # dotted or indexed) is re-resolved structurally here, because
      # those are the shapes whose value is available WITHOUT re-running
      # the evaluation, and `{{ some_list }}` is where this difference
      # actually shows up. A filter chain still renders through
      # #evaluate's JSON form - see KNOWN_MISSING.md; closing that needs
      # the evaluator to carry structured results out to the final
      # boundary, which is the round trip JinjaRenderer#evaluate_value!
      # warns about.
      #
      # Only VarSubstitutor's outermost `{{ }}` expansion may call this.
      def evaluate_output(expr : String) : String
        rendered = evaluate(expr)

        # Only a result that LOOKS like a container is worth a second,
        # structural look - which keeps the common scalar render at
        # exactly one evaluation.
        return rendered unless container_shaped?(rendered)

        if value = structured_container(expr)
          return @lookup.format_value_output(value)
        end

        # query()/q() always return lists (and lookup(..., wantlist=True) does
        # too), but structured_container deliberately skips lookup calls so a
        # side-effecting lookup never runs twice. The already-rendered result
        # string is the JSON-compact form, so parse THAT and print it as
        # Python repr like Ansible's `[1, 2]` in mixed text. A plain
        # lookup('file', ...) whose content merely looks like JSON is NOT
        # converted: only the list-forcing forms are.
        if list_forcing_lookup?(expr) && (value = (JSON.parse(rendered) rescue nil)) && value.as_a?
          return @lookup.format_value_output(value)
        end
        rendered
      end

      private def list_forcing_lookup?(expr : String) : Bool
        stripped = expr.strip
        return true if stripped.starts_with?("query(") || stripped.starts_with?("q(")
        stripped.starts_with?("lookup(") && stripped.matches?(/wantlist\s*=\s*(True|true)/)
      end

      # The undefined-typed form of #evaluate: Undefined::INSTANCE when the
      # expression genuinely does not resolve to any value, the rendered
      # String otherwise - which may itself be the literal text
      # "undefined" when a real stored value collides with the sentinel.
      #
      # This is the seam the "undefined"-string sentinel architecture
      # could not cross (KNOWN_MISSING.md's dotted-index collision entry):
      # #evaluate's String return type cannot distinguish a genuine miss
      # from a real value that happens to BE the text "undefined", so any
      # caller that re-checks its own output (`rendered == "undefined"`)
      # misreads the collision as a miss and, under strict-undefined,
      # fails a task Ansible runs. The disambiguation here never
      # compares strings: a rendered "undefined" is demoted to Undefined
      # only when the undefined-typed structural resolver
      # (VariableLookup#resolve - nil on a miss, JSON::Any otherwise)
      # ALSO finds no value. For the plain dotted/bracket chain shapes
      # its strict-undefined and dynamic-dict-key callers feed it, that
      # resolver is complete (quoted/integer/bare/bracket index keys,
      # numeric dot-indexing into lists, dynamic keys via recursion,
      # recursive re-templating of templated bases). Shapes resolve can't
      # parse degrade to the old behavior rather than to a regression:
      # they only reach the ambiguous branch when the render was already
      # the sentinel text.
      def evaluate_or_undefined(expr : String) : String | Undefined
        rendered = evaluate(expr)
        return rendered unless rendered == "undefined"
        @lookup.resolve(expr).nil? ? Undefined::INSTANCE : rendered
      end

      private def container_shaped?(rendered : String) : Bool
        return false if rendered.size < 2
        (rendered.starts_with?('[') && rendered.ends_with?(']')) ||
          (rendered.starts_with?('{') && rendered.ends_with?('}'))
      end

      # Re-resolves *expr* to its structured value, to tell a real
      # container apart from a STRING that merely looks like one (a var
      # holding the text `{"a": 1}` renders identically but must not be
      # reformatted). A plain reference is answered straight from the
      # variable table; anything else goes back through Crinja, which
      # evaluates any expression structurally.
      #
      # Skipped entirely for an expression with a side effect
      # (`lookup('pipe', ...)` and friends), which must never run twice.
      # The side-effect test matches a pipe lookup/query CALL specifically
      # - the old bare `expr.includes?("pipe")` skipped structural
      # resolution for any expression merely containing those letters
      # (`mypipeline_list`).
      private def side_effecting_call?(expr : String) : Bool
        expr.includes?("lookup(") || expr.includes?("query(") ||
          expr.matches?(/(lookup|query|q)\s*\(\s*['"]pipe/)
      end

      private def structured_container(expr : String) : JSON::Any?
        value =
          if expr.matches?(REGEX_PLAIN_REFERENCE)
            @lookup.resolve(expr)
          elsif side_effecting_call?(expr)
            nil
          else
            render_via_jinja_value(expr)
          end

        return nil unless value
        raw = value.raw
        (raw.is_a?(Array) || raw.is_a?(Hash)) ? value : nil
      rescue
        nil
      end

      # Evaluate any expression and return string result. A thin guard in
      # front of #evaluate_expr for the inline ternary `TRUTHY if COND else
      # FALSY` (Jinja2/Ansible syntax, used directly in default vars
      # like konstruktoid-hardening's `sysctl_conf_dir: "{{
      # '/usr/lib/sysctl.d' if usr_lib_sysctl_d_dir else '/etc/sysctl.d'
      # }}"`) - split out from the main body (rather than added as another
      # branch in it) purely to keep that method's already-high cyclomatic
      # complexity from tipping over ameba's threshold. Checked before any
      # of #evaluate_expr's own checks since COND itself commonly contains
      # a comparison - splitting first keeps that comparison scoped to COND
      # instead of being (wrongly) evaluated against the whole expression.
      # A plain variable reference: name, dotted path, bracket index.
      # No filters, operators, calls or literals - matching
      # REGEX_BARE_VAR_REF's spirit in variable_substitutor.cr.
      # Dotted NUMERIC parts (`.0`, Jinja's list-index shorthand) are
      # plain references too: excluding them sent `l.0.0` to the Jinja
      # fallback, whose stringification loses the container's native
      # shape (`structured_container` saw a JSON TEXT string, not a
      # dict, so a mixed-text `parent={{ l.0.0 }}` rendered
      # `{"name":"s1"}` where Ansible renders Python repr
      # `{'name': 's1'}` - live-verified vs 2.19.11). VariableLookup's
      # apply_dotted_parts owns the Array-vs-Hash-key decision.
      REGEX_PLAIN_REFERENCE = /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*|\.[0-9]+|\[(?:-?\d+|'[^']*'|"[^"]*")\])*\z/

      def evaluate(expr : String) : String
        if ternary = split_ternary(expr)
          # Crinja-first delegation, ternary construct (after boolean_logic?
          # below): Jinja2's inline ternary is right-associative
          # (`a if b else c if d else e` chains) and its condition can
          # itself be any expression, including one this hand-rolled
          # evaluator's OWN #split_ternary/#evaluate_ternary don't fully
          # agree on (they recurse back into #evaluate for the chosen
          # branch, which happens to make simple right-associative
          # chaining work, but the split is still a string heuristic,
          # not a real parse). `omit` and the `is failed`/etc.
          # register-result tests - the two things that had to be ported
          # to Crinja before the FIRST construct (boolean_logic? below)
          # could safely swap - are already available here for free,
          # since they're bound in `JinjaRenderer`'s own shared vars
          # context, not specific to that branch. See
          # #render_via_jinja_container_safe's own comment for why a
          # ternary needs it instead of plain #render_via_jinja.
          begin
            render_via_jinja_container_safe(expr)
          rescue
            evaluate_ternary(ternary)
          end
        elsif ternary_no_else = split_ternary_no_else(expr)
          begin
            render_via_jinja_container_safe(expr, undefined_sentinel: false)
          rescue
            evaluate_ternary_no_else(ternary_no_else)
          end
        elsif boolean_logic?(expr)
          # A full boolean expression (`X is failed or Y != Z`, `A and
          # B`) as a `{{ }}` span's entire content, most commonly a
          # set_fact: value - Ansible/Jinja2 evaluates `or`/`and`/
          # `is` tests identically whether they sit inside a bare when:
          # or a `{{ }}` substitution, but this evaluator (the "plain"
          # one used for {{ }} spans) had no concept of any of the
          # three; only ConditionalEvaluator (used for bare when:/
          # failed_when:/assert conditions) did. Real bug found
          # benchmarking ansible-community.ansible-vault's own
          # `installation_required: "{{ vault_installation is failed or
          # installed_vault_version.stdout != vault_version~(...) }}"` -
          # `is failed` alone rendered "undefined", and the whole `or`
          # expression fell through to a plain (always-undefined)
          # variable lookup on the literal text, formatting as "True"
          # (self.class of bug as the other bare-boolean-literal fixes
          # nearby - a non-empty string is truthy) regardless of the
          # real installed version, forcing every run to redundantly
          # reinstall the package.
          #
          # BUT: Jinja2's `or`/`and` are value-selectors, not pure
          # boolean operators - `X or Y` evaluates to X itself (not
          # "True") when X is truthy, only falling through to Y when X
          # isn't. `ConditionalEvaluator.evaluate(...) ? "True" :
          # "False"` is only correct when every operand is ALREADY a
          # boolean condition (comparisons/is-tests, as in the vault
          # example above) - it's wrong the moment an operand is a plain
          # value expression, e.g. robertdebock.users' own `groups: "{{
          # user.groups | default([]) | join(',') or omit }}"`, which
          # must resolve to the joined string (or the omit sentinel),
          # not the literal text "True"/"False". #evaluate_value_or_and
          # only engages for that plain-value shape (single top-level
          # `or`, neither side looking like a real boolean condition)
          # and returns nil otherwise, leaving the boolean-coercion
          # fallback below untouched for genuine conditions.
          #
          # Dual-evaluator convergence: this branch is the first,
          # deliberately narrow, piece of that convergence
          # - `or`/`and`/`is` is the highest historical bug density part
          # of this file (this very comment documents one), and Crinja's
          # real recursive-descent parser gets precedence right BY
          # CONSTRUCTION, unlike the string-heuristic dispatch the rest
          # of this class is built from. Tries Crinja first (`render!`,
          # which raises instead of Crinja::JinjaRenderer#render's own
          # "give back the original text" failure mode - actively wrong
          # here, since a caller of #evaluate always wants a real
          # value); falls back to the ORIGINAL hand-rolled path on ANY
          # failure, so a construct Crinja doesn't yet support degrades
          # to exactly today's behavior rather than a regression.
          # `is failed`/`changed`/`skipped`/`succeeded`/`success` (Ansible register-result tests) and the `omit` magic variable
          # both needed porting to Crinja's own registry/context first
          # (see jinja_filters.cr's `result_field` tests and
          # JinjaRenderer#prepare_crinja_vars's own `omit` binding) -
          # without those this swap would have silently regressed both.
          begin
            render_via_jinja(expr)
          rescue
            evaluate_value_or_and(expr) || (ConditionalEvaluator.evaluate(expr, @vars) ? "True" : "False")
          end
        else
          evaluate_expr(expr)
        end
      end

      # Whether *expr* has a top-level (outside quotes/brackets/parens)
      # ` or `, ` and `, or ` is ` - the three Jinja/Ansible boolean-logic
      # keywords ConditionalEvaluator natively understands but this
      # evaluator otherwise doesn't. Depth-aware for the same reason
      # #top_level_keyword_index already is elsewhere in this file: a
      # nested `(a is defined) or b`'s own " is " inside the parens must
      # not trip this at the outer level (ConditionalEvaluator's own
      # recursive descent already handles that correctly once the whole
      # expression is handed to it).
      # SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #4: memoized by literal
      # `expr` text, process-wide - the SAME `{{ var | filter }}` source
      # commonly appears dozens-to-hundreds of times across a role, and
      # #evaluate re-scans it from scratch on every single call (up to 6
      # full character-by-character `top_level_keyword_index` passes -
      # 2 from #split_ternary, 1 from #split_ternary_no_else, 3 from
      # #boolean_logic? - before ever reaching #evaluate_expr for an
      # expression that matches none of the 3 special shapes).
      #
      # Deliberately narrower than the item's original "memoize which
      # dispatch path" framing, which a prior pass (0.9.485) investigated
      # and did NOT implement: whether `render_via_jinja(expr)` itself
      # raises depends on Crinja's runtime evaluation (a variable's
      # actual TYPE, not just the expression's static text - `{{ x |
      # first }}` can succeed or raise depending on whether `x` is
      # empty), so caching "did Crinja end up handling this" by source
      # text alone would be memoizing a RUNTIME-dependent outcome as if
      # it were a pure function of the string - unsafe, per that
      # investigation's own finding. What's cached here is narrower and
      # provably safe: `#split_ternary`/`#split_ternary_no_else`/
      # `#boolean_logic?` are pure string scans with no `@vars` access
      # at all (verified by reading all 3 bodies directly - only
      # `#top_level_keyword_index`, itself pure) - which of the 4
      # dispatch SHAPES an expr's TEXT has is a genuine constant, and
      # `render_via_jinja`/the hand-rolled fallback are still invoked
      # completely fresh on every real call, exactly as before - only
      # the shape CLASSIFICATION is reused, never the outcome of trying
      # to render it.
      #
      # Differential-tested, not just spec-tested: ran all 3080 real
      # "output"-kind `{{ }}` expressions scraped from `testing/roles` +
      # 21 benchmarked Galaxy roles through `ExpressionEvaluator#evaluate`
      # before and after this change - byte-identical output (or identical raised
      # exception class) for all 3080, confirming the memoization is
      # invisible to real-world dispatch behavior, not just this
      # project's own spec suite.
      @@split_ternary_cache = Hash(String, {String, String, String}?).new
      @@split_ternary_no_else_cache = Hash(String, {String, String}?).new
      @@boolean_logic_cache = Hash(String, Bool).new

      # All three caches are keyed on raw expression TEXT, and an
      # expression can legitimately vary per loop item (`assert:`'s
      # `that: "{{ item.a }} == 'x'"` finalizes to different text per
      # item) - unbounded growth over a long run. The memoized values
      # are PURE functions of the text, so resetting is always safe; a
      # reset only costs re-computation.
      MEMO_CACHE_MAX_ENTRIES = 10_000

      private def memo_cache_full?(*caches : Hash) : Bool
        caches.any?(&.size.>=(MEMO_CACHE_MAX_ENTRIES))
      end

      private def boolean_logic?(expr : String) : Bool
        return @@boolean_logic_cache[expr] if @@boolean_logic_cache.has_key?(expr)

        result = !top_level_keyword_index(expr, " or ").nil? ||
                 !top_level_keyword_index(expr, " and ").nil? ||
                 !top_level_keyword_index(expr, " is ").nil?
        @@boolean_logic_cache.clear if memo_cache_full?(@@boolean_logic_cache)
        @@boolean_logic_cache[expr] = result
        result
      end

      # Tokens whose presence on one side of a top-level `or`/`and` mean
      # that side is a genuine boolean condition (comparison, is-test,
      # negation, or another nested or/and) rather than a plain value -
      # in that case the whole expression must keep going through
      # ConditionalEvaluator's boolean coercion instead of #evaluate_
      # value_or_and's value-passthrough semantics.
      BOOLEAN_CONDITION_TOKENS = [" is ", " in ", " not ", "==", "!=", "<=", ">=", " and ", " or "]

      private def looks_like_condition?(expr : String) : Bool
        stripped = expr.strip
        BOOLEAN_CONDITION_TOKENS.any? { |tok| stripped.includes?(tok) } || stripped.starts_with?("not ")
      end

      # Real Python/Jinja2 truthiness of an already-rendered string
      # value (this evaluator's #evaluate always returns String) - only
      # an empty string, "false"/"False", "none"/"None", "0", "[]", "{}",
      # or the omit sentinel are falsy; everything else (including "0.0"
      # rendered forms aren't reachable here since numeric literals
      # render via VariableLookup#format_value, matching Python) is
      # truthy.
      private def truthy_string?(value : String) : Bool
        return false if value.empty?
        !{"false", "False", "none", "None", "0", "[]", "{}", OMIT_SENTINEL}.includes?(value)
      end

      # Value-selector `or`/`and` (`X or Y` returns X itself when X is
      # truthy, not the literal text "True") - only engages for the
      # single-top-level-operator, no-nested-condition shape; returns
      # nil for anything else so the caller falls back to full boolean
      # coercion via ConditionalEvaluator.
      private def evaluate_value_or_and(expr : String) : String?
        if idx = top_level_keyword_index(expr, " or ")
          evaluate_value_or(expr, idx)
        elsif idx = top_level_keyword_index(expr, " and ")
          evaluate_value_and(expr, idx)
        end
      end

      private def evaluate_value_or(expr : String, idx : Int32) : String?
        return nil if top_level_keyword_index(expr, " and ") || top_level_keyword_index(expr, " is ")
        left = expr[0...idx].strip
        right = expr[(idx + 4)..].strip
        return nil if looks_like_condition?(left) || looks_like_condition?(right)

        left_val = evaluate_operand(left)
        return left_val if truthy_string?(left_val)
        evaluate_operand(right)
      end

      private def evaluate_value_and(expr : String, idx : Int32) : String?
        return nil if top_level_keyword_index(expr, " is ")
        left = expr[0...idx].strip
        right = expr[(idx + 5)..].strip
        return nil if looks_like_condition?(left) || looks_like_condition?(right)

        left_val = evaluate_operand(left)
        return left_val unless truthy_string?(left_val)
        evaluate_operand(right)
      end

      # `omit` isn't a real variable - it's a magic bareword sentinel
      # (Ansible's own way to conditionally drop a module param
      # entirely), only ever meaningful as an operand here, never
      # resolvable via a normal variable lookup.
      private def evaluate_operand(expr : String) : String
        return OMIT_SENTINEL if expr == "omit"
        evaluate_expr(expr)
      end

      private def evaluate_expr(expr : String) : String
        if result = evaluate_expr_bare_literal(expr)
          return result
        end
        if result = evaluate_expr_bare_call(expr)
          return result
        end
        if result = evaluate_expr_operator(expr)
          return result
        end
        evaluate_expr_access(expr)
      end

      private def evaluate_expr_bare_literal(expr : String) : String?
        # A bare boolean literal (`true`/`false`/`True`/`False`), as
        # opposed to a quoted string one - Ansible/Jinja2 accepts
        # both spellings as literals. Checked before anything else falls
        # through to a plain variable lookup on the literal identifier
        # text itself (always undefined). Real bug found benchmarking
        # ansible-community.ansible-vault's own `vault_tls_copy_keys:
        # "{{ false if (vault_install_hashi_repo) else true }}"` - the
        # ternary's own branch-resolution in #evaluate_ternary re-enters
        # #evaluate on whichever bare literal branch was chosen, which
        # previously always came back "undefined" (a non-empty string,
        # so `| bool` downstream treated it as truthy regardless of the
        # actual condition).
        #
        # Crinja-first delegation, "bare literals" construct (first
        # #evaluate_expr sub-piece): tries Crinja first, same
        # render_via_jinja/rescue pattern as constructs 1-3. Found a
        # latent inconsistency doing this: the old unconditional
        # `expr.downcase` returned lowercase "true"/"false" here, at odds
        # with every other boolean-producing path in this codebase
        # (ConditionalEvaluator, ComparisonEvaluator's own construct-3
        # convergence, VariableLookup) which all produce capitalized
        # "True"/"False" (real Python/Jinja2 `str(bool)` convention) -
        # this branch was simply never reached with Crinja unavailable
        # for a bare literal, since Crinja renders `{{ true }}`/
        # `{{ false }}` as "True"/"False" like Ansible does, so the
        # divergence never showed up in practice. Kept as the fallback
        # (unchanged) for the case Crinja itself is ever unavailable.
        if expr == "true" || expr == "false" || expr == "True" || expr == "False"
          return begin
            render_via_jinja(expr)
          rescue
            expr.downcase
          end
        end

        # A bare numeric literal as the WHOLE expression (`{{ 5 }}`,
        # `{{ 5.7 }}`) or a leading-paren-wrapped one that recurses back
        # here (`{{ (5) | int }}`'s own `evaluate("5")` re-entry) - never
        # checked anywhere in this dispatch chain on its own (only ever
        # as an *operand* inside a `+`/`-`/`*`/`/` expression, via
        # #resolve_plus_operand's own identical check), so it fell all
        # the way through to a plain variable-name lookup on the literal
        # digit text itself, always undefined. Found chasing geerlingguy.
        # swap's own check-size.yml after fixing `*`/`/` arithmetic and
        # the `int` filter's own float handling - a literal float/int
        # piped straight into a filter with no variable or arithmetic
        # involved at all (`{{ 256.0 | int }}`) hit this same gap.
        if literal = numeric_literal(expr)
          # Crinja-first delegation, "bare literals" construct: try-Crinja-first, same
          # pattern as above. Crinja's own number-literal grammar is
          # stricter than Crystal's `to_i64?`/`to_f64?` (rejects
          # scientific notation like `1e10`, underscore separators like
          # `1_000`, hex like `0x1F` - all of which Crystal's own parse
          # happily accepts) - a hard `Crinja::TemplateSyntaxError`, not
          # a silent misrender, so those forms safely fall back to the
          # exact previous behavior via the rescue below.
          return begin
            render_via_jinja(expr)
          rescue
            @lookup.format_value(literal)
          end
        end

        # A bare quoted string literal (`{{ 'some.url/with.dots' }}`,
        # the whole `{{ }}` span, no filter/operator at all) - previously
        # unchecked anywhere in this dispatch chain, so a literal
        # containing a `.` (routine for a URL or IP address, e.g. a
        # `lookup('url', ...)` argument built via `+` concatenation and
        # re-evaluated as its own bare operand) fell through to the
        # `expr.includes?(".")` dotted-lookup branch further down, which
        # treated the literal text - quotes included - as a dotted
        # variable PATH rather than a string value, always undefined.
        #
        # `sole_quoted_literal?` (not the plain `quoted_string_literal`
        # every other bare-literal check in this file already uses)
        # matters here specifically: this check runs before the `+`
        # splitter below, and `quoted_string_literal` only looks at the
        # FIRST and LAST characters - `'a' + var + 'b'` also starts and
        # ends with `'`, so the plain check wrongly swallowed the whole
        # `+` chain as one "literal", stripping just the outer quotes
        # and leaving the middle ` + var + ` as literal garbage text.
        # Real regression introduced fixing the bug above, caught
        # immediately after via cloudalchemy.prometheus's own
        # `lookup('url', 'https://...v' + prometheus_version + '/...',
        # wantlist=True)` - the URL argument is built exactly this way.
        if literal = sole_quoted_literal?(expr)
          # Crinja-first delegation, "bare literals" construct: try-Crinja-first, same
          # pattern as above. `sole_quoted_literal?` itself never
          # unescapes anything (a literal `\'` inside the string comes
          # back with the backslash still attached) - Crinja's real
          # string-literal parsing does unescape, so a successful Crinja
          # render is MORE correct than the fallback here, not just
          # equivalent; the fallback (this method's own raw extraction)
          # only engages if Crinja itself fails on the literal.
          return begin
            render_via_jinja(expr)
          rescue
            literal
          end
        end

        nil
      end

      private def evaluate_expr_bare_call(expr : String) : String?
        # Each `name(args)` shape gets its own predicate-and-evaluate
        # method below; the first match wins, exactly as the original
        # inline if-chain did. (Kept as separate methods rather than one
        # big if/elsif to keep this dispatch readable - and under ameba's
        # cyclomatic-complexity ceiling.)
        evaluate_bare_lookup_call(expr) ||
          evaluate_bare_lookup_chained_call(expr) ||
          evaluate_bare_query_call(expr) ||
          evaluate_bare_range_call(expr) ||
          evaluate_bare_dict_call(expr)
      end

      # `lookup('first_found', ffparams)` - Ansible's lookup()
      # function call syntax (distinct from a `|` filter chain), used
      # pervasively across linux-system-roles to pick an OS-version-
      # specific vars file: `include_vars: "{{ lookup('first_found',
      # ffparams) }}"` where ffparams is `{files: [...], paths: [...]}`.
      # Checked first (function-call syntax, not an operator) since
      # nothing else in this dispatch chain understands `name(args)` at
      # all - it fell through everywhere else to a plain variable
      # lookup on the literal text "lookup('first_found', ffparams)",
      # always undefined.
      private def evaluate_bare_lookup_call(expr : String) : String?
        return evaluate_lookup(expr[7..-2]) if bare_call?(expr, "lookup(")
        nil
      end

      # `lookup(...).method()` chained directly with no `|` filter at
      # all (a bare `{{ }}` mustache, not a filter chain - the sibling
      # bug to filter_chain_special_head's own lookup( branch, same
      # root cause: bare_call? above requires lookup(...)'s own
      # matching close paren to be expr's LAST character, which is
      # false once a method call like `.splitlines()` follows it, so
      # this bare-mustache shape fell through to a plain variable-name
      # lookup on the whole literal text and always resolved
      # "undefined" - round 199, bodsch.tomcat).
      private def evaluate_bare_lookup_chained_call(expr : String) : String?
        return nil if !expr.starts_with?("lookup(") || top_level_pipe?(expr)
        return nil unless close_idx = matching_close_paren_index(expr, 6)
        suffix = expr[(close_idx + 1)..]
        # Only a genuine `.method()` continuation, not a ` | filter`
        # chain (that's a different expression shape entirely,
        # already handled by top_level_pipe?/split_chain further
        # down this dispatch - `lookup(...) | default(...)` and
        # `lookup(...).splitlines() | length` (a method call
        # FOLLOWED by a filter, top_level_pipe? is true for both)
        # must fall through to it unchanged, not be swallowed here;
        # filter_chain_special_head's own lookup( branch has the
        # equivalent fix for the pipe case).
        return nil unless suffix.lstrip.starts_with?('.')

        lookup_rendered = evaluate_lookup(expr[7...close_idx])
        result = (JSON.parse(lookup_rendered) rescue JSON::Any.new(lookup_rendered))
        result = @lookup.apply_method_suffix(result, suffix) || result
        result.raw.is_a?(String) ? result.as_s : result.to_json
      end

      # `query('first_found', params)` - Ansible's OTHER lookup-
      # invocation syntax; unlike `lookup(...)` (which comma-joins a
      # multi-result lookup into a scalar string unless `wantlist=True`
      # is passed explicitly), `query(...)` is Ansible's own
      # `lookup(..., wantlist=True)` shorthand and ALWAYS returns a
      # real list - the standard modern idiom for `loop: "{{
      # query('first_found', params) }}"` (picking an OS-specific vars
      # file to include, one candidate per iteration). Previously
      # entirely unrecognized - `bare_call?` only ever matched
      # "lookup(", so this fell through to a plain variable-name
      # lookup on the literal text "query('first_found', _params)",
      # always "undefined" - #resolve_loop_template's `loop:` then ran
      # once with a bogus `_loop_var`, so `include_vars: "{{ _loop_var
      # }}"` failed with "file not found: undefined" instead of the
      # real per-OS vars file. Found live benchmarking buluma.confluence
      # (round 165): ansible-playbook resolved the loop to the
      # real candidate (`ubuntu-22.04.yml`) and continued; crystal
      # failed at the very first real task.
      private def evaluate_bare_query_call(expr : String) : String?
        return evaluate_query(expr[6..-2]) if bare_call?(expr, "query(")
        # `q(...)` - Ansible's documented short alias for `query(...)`
        # (same lookup-plugin dispatch, always the list form). Previously
        # unrecognized - this fell through to a plain variable-name lookup
        # on the literal text `q('first_found', include_files, ...)`,
        # always "undefined" - found live benchmarking nephelaiio.devtools.
        # No prefix collision with `query(` itself ("query(" does not start
        # with "q(") nor with any other builtin (`quote(` etc. lack the
        # paren right after the q).
        return evaluate_query(expr[2..-2]) if bare_call?(expr, "q(")
        nil
      end

      # `range(...)` - Jinja2/Python's function-call range syntax,
      # commonly used as a `loop:` source (`loop: "{{ range(1, 11) |
      # list }}"`) rather than the engine's own `with_sequence:`
      # keyword. Checked here (bare, no filter chain) for the no-filter
      # case; the filter-chain case (`range(...) | list`) is handled in
      # evaluate_with_filter's own base-value resolution, since a bare
      # `range(` prefix check there would otherwise never be reached -
      # top_level_pipe? routes any expression with a `|` straight past
      # this method into evaluate_with_filter before this line runs.
      private def evaluate_bare_range_call(expr : String) : String?
        return nil unless bare_call?(expr, "range(")

        # Crinja-first delegation, general filter-chain-dispatch
        # construct (continued): unlike `dict()` just below,
        # `range()`'s raw-value output matches
        # the hand-rolled path exactly (probed across positive/
        # negative step, variable arguments) - safe via the same
        # #render_via_jinja_value pattern as the literal array/dict
        # cases above.
        begin
          value = render_via_jinja_value(expr)
          value ? @lookup.format_value(value) : "undefined"
        rescue
          @lookup.format_value(evaluate_range(expr[6..-2]))
        end
      end

      # `dict(iterable)` - Ansible's Templar exposes actual
      # Python's `dict` builtin (not Jinja2's own `**kwargs`-only
      # `dict` global), which also accepts a single positional
      # argument: an iterable of [key, value] pairs. Real bug found
      # live-verifying prometheus.prometheus.node_exporter: its own
      # _common role builds a checksum-filename lookup with `dict(raw
      # .splitlines() | map('regex_findall', ...) | map('flatten') |
      # map('reverse'))` - a positional iterable, not keyword args -
      # entirely unhandled here before (fell through to a plain
      # variable lookup on the literal text "dict(...)", always
      # undefined). Only the single-positional-arg form is
      # implemented, the only one any real role seen so far uses;
      # `dict(a=1, b=2)` keyword form is Crinja-only (jinja_filters.
      # cr's own lib/function/dict.cr), reached only once escalated
      # to the full Crinja renderer.
      private def evaluate_bare_dict_call(expr : String) : String?
        return nil unless bare_call?(expr, "dict(")

        # Dual-evaluator convergence: converged 2026-08-14 (0.9.340). The blocker
        # documented below (Crinja's own `dict()` reading only kwargs
        # and silently producing an EMPTY dict for a positional arg)
        # is fixed fork-side (`weirdbricks/crinja` `crystal-play-0.9.4`,
        # `src/lib/function/dict.cr`): the single positional-iterable
        # form (mapping, or list/tuple of 2-element pairs) now builds a
        # real dict and raises a clean `Arguments::Error` for anything
        # else - the same `render_via_jinja_value`/rescue pattern as
        # `range()` above, `evaluate_dict_call` unchanged as the
        # fallback.
        begin
          value = render_via_jinja_value(expr)
          value ? @lookup.format_value(value) : "undefined"
        rescue
          @lookup.format_value(evaluate_dict_call(expr[5..-2]))
        end
      end

      # A bare identifier whose OWN stored raw value is a pure, single-
      # level `{{ other_var }}` indirection (no filters, no dotted/
      # bracket access) - the exact shape KNOWN_MISSING.md's "native
      # typing" gap documents as the one that actually diverges in
      # practice (found live in robertdebock.java/buluma.java's own
      # `java_version == 8` gate). This engine's `{{ }}` substitution
      # deliberately preserves the SOURCE type as a string through such
      # an indirection rather than re-inferring a scalar type from
      # rendered text (see jinja_renderer.cr's own `rerender_string_
      # value` comment on why - protecting `buluma.bind`'s `(
      # bind_python_version == '3')` idiom, which needs the opposite
      # behavior) - correct for Ansible's OWN pre-2.19 templating
      # model, but ansible-core 2.19 made native types the default, so
      # a same-run `X == <int>` against exactly this indirected shape
      # can take the wrong branch silently. Not chased as a general
      # fix (measured at ~0.16% frequency across 611 real roles - see
      # KNOWN_MISSING.md's own decision-rule writeup, which explicitly
      # defers the full native-typing rewrite); this is the narrow
      # one-off it names as the alternative.
      INDIRECTION_ONLY_RE = /\A\{\{\s*[A-Za-z_]\w*\s*\}\}\z/

      private def bare_indirected_operand?(name : String) : Bool
        return false unless name =~ /\A[A-Za-z_]\w*\z/
        raw = @vars[name]?.try(&.raw)
        raw.is_a?(String) && INDIRECTION_ONLY_RE.matches?(raw.strip)
      end

      # True when *expr* is a top-level `==`/`!=`/`<`/`>`/`<=`/`>=`
      # comparison with at least one bare-indirected operand (see
      # above) - the shape where Crinja's own (otherwise perfectly
      # correct) comparison would silently disagree with
      # ComparisonEvaluator's own already-existing type-preserving
      # reparse (`rerender_if_templated`, blind `JSON.parse` on any
      # scalar - already used for `when:`/`assert:`, which is WHY
      # `when: java_version == 8` already worked correctly before this
      # fix while the identical comparison inside a `{{ }}` span, e.g.
      # a `debug: msg:`, did not: #evaluate_expr_operator tries Crinja
      # FIRST and only falls back to `@comparison` on a Crinja
      # exception, but Crinja doesn't raise here - it just returns a
      # plausible, wrong-typed answer).
      private def type_sensitive_comparison?(expr : String) : Bool
        ["==", "!=", "<=", ">=", ">", "<"].each do |op|
          next unless expr.includes?(op)
          parts = expr.split(op, 2)
          next if parts.size != 2
          return true if bare_indirected_operand?(parts[0].strip) || bare_indirected_operand?(parts[1].strip)
        end
        false
      end

      # @comparison.evaluate returns Crystal's own lowercase "true"/
      # "false" (Bool#to_s); a comparison that IS a whole `{{ }}`
      # expression's entire content renders that text directly to the
      # user (a debug: msg:, etc.), where real Python/Jinja2 always
      # capitalizes - matches the ternary swap's own identical fix
      # elsewhere in this file.
      private def capitalize_bool_text(text : String) : String
        case text
        when "true"  then "True"
        when "false" then "False"
        else              text
        end
      end

      private def evaluate_expr_operator(expr : String) : String?
        # Check for comparison operators FIRST (before filters)
        if has_comparison?(expr)
          # Crinja-first delegation, comparison construct: same try-Crinja-first,
          # fall-back-to-the-exact-previous-code pattern as the
          # boolean_logic?/ternary swaps above. `@comparison.evaluate`
          # returns Crystal's own lowercase "true"/"false" (`Bool#to_s`)
          # rather than real Python/Jinja2's capitalized "True"/"False" -
          # already the SAME inconsistency the ternary swap's spec fix
          # above found and corrected elsewhere, so this is intentional,
          # not a regression. Confirmed safe before swapping: the one
          # in-class consumer of a rendered comparison result
          # (#truthy_string?, a few lines below) already checks BOTH
          # casings (`"false"`/`"False"`) defensively; no other call site
          # in this codebase pattern-matches a bare lowercase "true"/
          # "false" against something this specific method could have
          # produced.
          #
          # EXCEPT when type_sensitive_comparison? - there, Crinja is
          # skipped entirely in favor of @comparison (ComparisonEvaluator),
          # since it's the one with the type-preserving reparse this
          # exact shape needs and Crinja's own successful-but-wrong-
          # typed answer would otherwise never be overridden by the
          # ordinary rescue-based fallback below.
          return begin
            if type_sensitive_comparison?(expr)
              capitalize_bool_text(@comparison.evaluate(expr))
            else
              render_via_jinja(expr)
            end
          rescue
            capitalize_bool_text(@comparison.evaluate(expr))
          end
        end

        # Check for top-level `-` subtraction - specifically datetime
        # subtraction (dev-sec os_hardening's own `to_datetime(...) -
        # to_datetime(...)`, producing a timedelta `.days` can then read)
        # and plain numeric subtraction. Requires spaces around the `-`
        # (unlike `+`, a bare hyphen is common inside ordinary
        # identifiers/text, so only the unambiguous "a - b" spacing is
        # treated as the operator) and, like `+`, must come before the
        # filter check: `|` binds tighter than `-`, so each side may
        # still carry its own filter chain evaluated independently.
        #
        # Crinja-first delegation, arithmetic `-` construct: same
        # try-Crinja-first, fall-back-to-the-exact-previous-code pattern
        # as the other converged constructs (mult/div, `~`, filter
        # chains). Probed across numeric int/float/bool mixes, every
        # non-numeric operand class (strings, lists, null, undefined),
        # and bare datetime subtraction - every non-numeric class raises
        # in Crinja and falls back identically, and undefined operands
        # match. The one divergence (bare `(a | to_datetime) - (b |
        # to_datetime)` with no `.days` suffix) produces a real
        # structured timedelta where the hand-rolled path silently
        # produced "" - see CRINJA_PHASE2_REPORT.md. Uses the raw-value
        # path, not #render_via_jinja: a datetime result converts back
        # as a structured Hash, and #render_via_jinja's Crinja-side
        # stringification would Python-repr it instead of going through
        # this codebase's own `format_value`.
        if minus = split_top_level_minus(expr)
          left_expr, right_expr = minus
          return begin
            value = render_via_jinja_value(expr)
            value ? @lookup.format_value(value) : "undefined"
          rescue
            evaluate_minus(left_expr, right_expr)
          end
        end

        # Check for top-level `+` concatenation (list/string/number), e.g.
        # `mountpoints_list + ['/dev', '/dev/shm', '/run', '/tmp']`, or
        # `acc | default([]) + [item]` (dev-sec os_hardening's own
        # account-list accumulator pattern) - a common Jinja2 idiom for a
        # self-referential set_fact appending literal entries onto a
        # list. Must come before both the filter check below (Jinja
        # binds `|` tightly to its immediate left operand only - `acc |
        # default([]) + [item]` is `(acc | default([])) + [item]`, not
        # `acc | (default([]) + [item])`, so `+` is the outer, lower-
        # precedence split here) and the generic "[" check further down,
        # which would otherwise misparse the whole expression as
        # `var[key]` off a literal array operand's own brackets.
        if segments = split_top_level_plus(expr)
          # Strict operand-class gate, BEFORE the Crinja-first attempt:
          # the vendored Crinja is lenient on every strict class (probe:
          # undefined operand stringifies "", null renders its "None"
          # repr, an omit operand its sentinel text, list + int APPENDS)
          # and succeeds where Ansible hard-fails the task - so a
          # raise from the fallback below would never even be reached.
          # Runs the hand-rolled operand resolution + combination once
          # for validation only; only its OWN strict verdict propagates,
          # any other internal raise (a filter-chain operand this
          # evaluator can't resolve, say) means "cannot validate
          # conservatively" and leaves the Crinja-first attempt
          # untouched. lookup(...)/query(...) operands are skipped
          # entirely - same second-execution guard
          # Krikri.bracket_index_failure_message applies.
          validate_plus_operands_strictly(expr, segments)
          # Crinja-first delegation, arithmetic `+` construct: same
          # try-Crinja-first, fall-back-to-the-exact-previous-code
          # pattern as the `-` swap above. Probed across string
          # concatenation (the dominant real-role shape), numeric
          # int/float/bool mixes, list concatenation, dict/array-literal
          # operands, recursive re-templating of operand values, and
          # every non-numeric operand class - all matched except the
          # divergences documented in CRINJA_PHASE2_REPORT.md (notably
          # int + float, which Jinja adds numerically and the
          # hand-rolled path below string-concatenates). Uses the
          # raw-value path (like the filter-chain construct, NOT the
          # scalar-only #render_via_jinja): a `+` chain can produce a
          # container (`list1 + list2`), whose result must format
          # through `format_value`'s JSON-compact form, not Crinja's
          # Python-repr Finalizer.
          return begin
            value = render_via_jinja_value(expr)
            value ? @lookup.format_value(value) : "undefined"
          rescue
            evaluate_plus(segments)
          end
        end

        # Top-level `*`/`/`/`//` arithmetic - entirely unimplemented
        # before (neither this dispatch nor #resolve_plus_operand's own
        # `+`/`-`-operand resolution recognized them at all), so even a
        # bare `{{ 10 / 2 }}` rendered the literal string "undefined".
        # Found via geerlingguy.swap's own check-size.yml: `(swap_file_
        # check.stat.size / 1024 / 1024) | int` (converting a stat'd
        # byte count to MB) - the whole division chain resolved
        # undefined, so the file-size comparison this feeds always
        # differed, deleting and recreating the swap file on every
        # single run instead of converging. Checked after both `-` and
        # `+` (so `2 + 3 * 4` still splits on `+` first, each side
        # separately reaching this check via #resolve_plus_operand,
        # matching Jinja2's normal precedence - `*`/`/` bind
        # tighter than `+`/`-`) but before the filter/literal/variable
        # checks further down.
        if mult_div = split_top_level_mult_div(expr)
          parts, ops = mult_div
          return evaluate_mult_div(expr, parts, ops)
        end

        # Jinja2's `~` string-concatenation operator (distinct from `+`,
        # which errors on mismatched operand types - `~` always
        # stringifies both sides first) - real bug found benchmarking
        # ansible-community.ansible-vault's own `installed_vault_version.
        # stdout != vault_version~('+ent' if vault_enterprise)`.
        # Entirely unimplemented before (no `~` handling anywhere in the
        # engine) - fell through everywhere else to a plain variable
        # lookup on the whole literal text, always "undefined", so the
        # role's own version-comparison logic always concluded a
        # (re-)install was needed regardless of what was actually
        # installed.
        if segments = split_top_level_tilde(expr)
          # Crinja-first delegation, general filter-chain-dispatch
          # construct (tilde-concat): try-Crinja-first, same pattern
          # as the other constructs. Crinja natively
          # supports `~` (`src/lib/operator/tilde.cr`); probing it
          # against this hand-rolled path first (empirically, across
          # strings/numbers/undefined/multi-segment chains, all
          # matching) surfaced a REAL bug in the fork itself before this
          # swap could be trusted: `~`'s (and `+`'s identical fallback
          # branch's) string-fallback used `Value#to_s`, bypassing
          # `Finalizer` - a Bool operand rendered lowercase "true"/
          # "false" instead of Python-parity "True"/"False", and an
          # Array/Hash operand leaked its raw `Crinja::Value<...>`
          # wrapper inspect text instead of a real stringified list/dict.
          # Fixed in the fork (`crystal-play-0.9.3`) before converging
          # this construct, not worked around here.
          return begin
            render_via_jinja(expr)
          rescue
            evaluate_tilde(segments)
          end
        end

        nil
      end

      private def evaluate_expr_access(expr : String) : String
        # A leading parenthesized sub-expression, optionally followed by
        # dotted/indexed access on its result (`( a | to_datetime(...) -
        # b | to_datetime(...) ).days` - dev-sec os_hardening's own
        # password-ageing day-count assert). Recurses into the inner
        # expression (which may itself contain `-`/`+`/filters/anything
        # else `evaluate` understands) and, once resolved, walks any
        # trailing `.attr`/`[index]` suffix against the *result* rather
        # than against @vars - VariableLookup#walk exists for exactly
        # this (a base value that didn't come from a plain variable
        # lookup). Checked AFTER `+`/`-` above (moved here - was
        # previously first, before either): those are correctly depth-
        # aware and skip content inside the leading paren on their own,
        # so a genuine `(x) + y`/`(x) - y` is now handled by the +/-
        # splitters, whose own per-operand resolution already knows how
        # to unwrap a leading-paren operand. Left first, this check's own
        # evaluate_leading_paren blindly treated *any* non-empty text
        # after the closing paren as a `.attr`/`[idx]`/`|filter` walk
        # suffix - `(ternary_returning_int) + '-'` (linux-system-roles/
        # logging's rsyslog subrole, building a config filename) had its
        # trailing ` + '-'` handed to VariableLookup#walk, which
        # recognizes neither `.` nor `[` as its first char and returns
        # nil - collapsing the whole expression to "undefined" instead of
        # concatenating. A bare `(x)` or `(x).attr` with no top-level
        # operator at all still reaches this unchanged, since split_top_
        # level_plus/minus return nil for those and fall through here.
        if paren = split_leading_paren(expr)
          # Crinja-first delegation, final construct: leading-paren
          # wrapper (`(expr).attr[idx] | filter`) - try Crinja first on
          # the FULL original expr text via the raw-value path, same
          # pattern as the rest of `#evaluate_expr`. Probed matching
          # exactly across arithmetic/filter/dotted/indexed suffix
          # combinations. Falls back to the existing
          # `#evaluate_leading_paren` (which itself already recurses
          # through `#evaluate`, so still benefits from every other
          # converged construct even on the fallback path).
          return evaluate_leading_paren_crinja_first(expr, paren)
        end

        # Check for filters (|) - depth-aware: a `|` nested inside a
        # `[...]` index (`rsyslog_weight_map[inner_item.type | d('rules')]`
        # - linux-system-roles/logging's rsyslog subrole again, this time
        # a filter chain used as a dict index rather than a ternary
        # branch) belongs to the index expression, not a top-level filter
        # chain on the whole thing. A naive substring check routed the
        # *entire* `name[key | filter]` expression into evaluate_with_
        # filter, whose own var_expr/segments[0] split treats an unclosed
        # `[` as "still part of the base lookup" and calls back into
        # evaluate() with that same (now `[`-containing, so still
        # `|`-routed) text - not infinite (unlike the has_comparison? bug
        # above, evaluate_with_filter's `[`-branch only recurses one level
        # before falling back to a plain lookup that fails), but it always
        # silently returned the *unindexed* base value instead of properly
        # indexing it. See resolve_index_key for the other half of the fix
        # - actually evaluating a filter-chain index key once dispatch
        # correctly reaches the bracket-access path below.
        if top_level_pipe?(expr)
          return evaluate_with_filter(expr)
        end

        # A literal Jinja array (`[]`, `['x']`, `[item]`) standing alone -
        # `resolve_plus_operand` already special-cases this for a `+`
        # operand via parse_literal_array, but the general dispatch here
        # had no equivalent, so the same literal used anywhere else (a
        # ternary branch: linux-system-roles/logging's rsyslog subrole
        # `__rsyslog_tls_packages if (...) else []`) fell through to the
        # generic `[` dict/list-access check below, which treats the
        # bracketed text as *indexing syntax* on the (empty, since there's
        # no variable name before the bracket) prefix - always failing and
        # resolving to "undefined" instead of an empty/literal list. Only
        # an expr that *starts* with `[` can be this case; `list[0]`/
        # `list[0:2]` always start with the variable name instead, so this
        # can't misfire on real indexing/slicing.
        # A literal Jinja dict (`{item.name: new_value}` - linux-system-
        # roles/kernel_settings' own dynamic-key dict literal, merged in
        # via `| combine(__new_item)`) shares a dispatch branch with the
        # `[` bracket case for the same reasoning as the literal-array
        # comment inside evaluate_bracket_expr (FilterEngine's own
        # parse_dict_literal only ever sees this as a filter *argument*,
        # and even there treats the key as literal text rather than an
        # expression - wrong for a dynamic key like `item.name`), just for
        # `{...}` instead of `[...]`. Combined into one method purely to
        # keep this method's own branch count under ameba's cyclomatic-
        # complexity threshold.
        if result = evaluate_bracket_or_dict_expr(expr)
          return result
        end

        # Check for nested access (.)
        if expr.includes?(".")
          return evaluate_expr_dotted(expr)
        end

        # Simple variable lookup
        begin
          value = render_via_jinja_value(expr)
          value ? @lookup.format_value(value) : "undefined"
        rescue
          # A leading unary minus whose Crinja evaluation failed: negate a
          # numeric operand, raise on a missing bare reference or a
          # non-numeric one - Jinja2/Ansible fails the task on both
          # (`- missing_var`, `- 'abc'`), while the plain-lookup fallback
          # below silently rendered the "undefined" sentinel (found by
          # bin/differential_fuzz: "cannot negate" divergences). Same
          # conservative shape-gating the strict `+` operand resolution
          # uses: a genuinely-missing operand only raises when it matches
          # REGEX_BARE_VAR_REF (an operand shape this evaluator simply
          # can't resolve must stay a lenient fallback, not become a
          # spurious task failure).
          if operand = unary_minus_operand(expr)
            negated = evaluate_unary_minus(operand)
            return negated if negated
          end
          @lookup.simple(expr)
        end
      end

      # The operand text of a leading unary minus (`- 5`, `- var.attr`),
      # or nil when *expr* doesn't start with one. A bare `-5` numeric
      # literal never reaches here (parsed earlier as a literal).
      private def unary_minus_operand(expr : String) : String?
        stripped = expr.strip
        return nil unless stripped.starts_with?('-') && stripped.size > 1
        rest = stripped[1..].strip
        rest.empty? ? nil : rest
      end

      # Negate *operand* for a leading unary minus, or nil when the shape
      # can't be resolved conservatively (the caller keeps the lenient
      # plain-lookup fallback). A genuinely-missing bare reference raises
      # Ansible's strict-undefined message (via resolve_plus_operand's
      # own strict gate); a resolvable non-numeric operand raises real
      # Python's unary-minus TypeError.
      private def evaluate_unary_minus(operand : String) : String?
        resolved =
          begin
            resolve_plus_operand(operand, strict: true)
          rescue e : PlusMinusOperandError
            # A missing bare reference is a real strict failure; any other
            # shape-gated failure means "can't resolve conservatively" and
            # keeps the lenient plain-lookup fallback.
            raise e if REGEX_BARE_VAR_REF.matches?(operand)
            return nil
          end

        if number = python_number(resolved)
          return @lookup.format_value(JSON::Any.new(-number))
        end

        if resolved.raw.nil? && !REGEX_BARE_VAR_REF.matches?(operand) && !@lookup.resolve(operand)
          return nil
        end

        raise PlusMinusOperandError.new("bad operand type for unary -: '#{python_type_name(resolved)}'")
      end

      # Dotted variable/attribute access - split out of
      # #evaluate_expr_access purely to keep that method's own branch
      # count under ameba's cyclomatic-complexity threshold.
      private def evaluate_expr_dotted(expr : String) : String
        # Crinja-first delegation, general filter-chain-dispatch
        # construct (dotted variable/attribute access) - try Crinja first via the
        # raw-value path, same pattern and rationale as the literal
        # array/dict and range() cases above. Probed extensively
        # (nested dict/array traversal, `.get(key, default)`, Python
        # string methods, `hostvars[...]`, a missing key/attribute) -
        # all matched `@lookup.nested`'s own output exactly.
        value = render_via_jinja_value(expr)
        # A `nil` result here isn't necessarily a genuinely undefined
        # value - Crinja's own vars are prepared once and never
        # re-templated, so a dotted base whose STORED value is
        # itself unrendered `{{ }}` text (a role default like
        # `spamassassin_service: "{{ _spamassassin_service[...] |
        # default(...) }}"`, robertdebock.spamassassin's own vars/
        # main.yml) fails attribute access on the raw string outright
        # (Crinja's Undefined, not an exception) instead of first
        # re-resolving it - `@lookup.nested` already has the
        # `rerender_if_templated` handling for exactly this, but
        # previously only ran on an actual Crinja *exception*, never
        # on a quiet `nil`. Ansible resolves the var fully (via
        # its own vars_context) before evaluating `.name`.
        value ? @lookup.format_value(value) : @lookup.nested(expr)
      rescue
        @lookup.nested(expr)
      end

      # Dispatches every `[`-bearing expr that isn't already a top-level
      # +/-/filter/paren case (those are checked before this in
      # evaluate_expr). A literal Jinja array (`[]`, `['x']`, `[item]`)
      # standing alone must be checked first: `resolve_plus_operand`
      # already special-cases this for a `+` operand via
      # parse_literal_array, but a ternary branch (linux-system-roles/
      # logging's rsyslog subrole: `__rsyslog_tls_packages if (...) else
      # []`) reaches this general dispatch instead - without this check it
      # fell through to the indexed-access branch, which treats the
      # bracketed text as *indexing syntax* on the (empty, since there's
      # no variable name before the bracket) prefix, always failing and
      # resolving to "undefined" instead of an empty/literal list. Only an
      # expr that *starts* with `[` can be this case; `list[0]`/
      # `list[0:2]` always start with the variable name instead, so this
      # can't misfire on real indexing/slicing.
      private def evaluate_bracket_expr(expr : String) : String
        if literal_array_expr?(expr)
          # Crinja-first delegation, general filter-chain-dispatch
          # construct (literal array/dict expressions) - try
          # Crinja first via the raw-value path (#render_via_jinja_
          # value), which preserves this codebase's own JSON-compact
          # `format_value` output instead of Crinja's Python-repr
          # `Finalizer` style - see that method's own comment for why
          # the plain String-returning #render_via_jinja can't be used
          # here (it would break the render-then-reparse round trip
          # other call sites depend on). Falls back to the original
          # hand-rolled `parse_literal_array` on any failure.
          return begin
            value = render_via_jinja_value(expr)
            value ? @lookup.format_value(value) : "undefined"
          rescue e : KrikriJinja::TemplateError
            # Same out-of-range propagation as the general bracket path,
            # surfaced as this evaluator's own strict bracket-index error.
            if e.message.try(&.includes?("has no element"))
              raise UndefinedVariableError.new(bracket_index_failure(expr) || e.message.not_nil!)
            end
            @lookup.format_value(parse_literal_array(expr))
          end
        end
        # Real bug found probing whether this branch was safe to converge
        # to Crinja-first as part of the general filter-chain-dispatch
        # construct: `expr.includes?("[:") || expr.includes?
        # (":]")` only catches a slice with an EMPTY start or end
        # (`items[:3]`, `items[2:]`) - a slice with BOTH bounds present
        # (`items[1:3]`) has neither literal substring (there's a digit
        # between the `[`/`:` and between the `:`/`]`), so it fell
        # through to `@lookup.indexed` below, which has no slice
        # handling at all, always resolving to "undefined". Broadened to
        # the same top-level-bracket-contains-a-colon check
        # `ArraySlicer#slice` itself already implicitly requires via its
        # own `/^([^\[]+)\[([^:]*):([^\]]*)\]/` regex.
        if expr.matches?(/\[[^\[\]]*:[^\[\]]*\]/)
          # Crinja-first delegation, general filter-chain-dispatch
          # construct (Python slice syntax) - the fork already has real support for it
          # (`PATCHES.md`'s "Python slice syntax" entry), verified
          # matching `ArraySlicer#slice`'s own output across both-bounds/
          # single-bound/negative-index slices via the raw-value path.
          return begin
            value = render_via_jinja_value(expr)
            value ? @lookup.format_value(value) : "undefined"
          rescue
            @slicer.slice(expr)
          end
        end

        # Crinja-first delegation, general filter-chain-dispatch
        # construct (general indexed access: `var[key]`, `var[0]`, `var[-1]`) - same
        # pattern as the dotted-access/simple-lookup cases above.
        #
        # The engine (krikri-jinja v0.4.20) now hard-fails an out-of-range
        # list/tuple subscript with Jinja2's "list object has no
        # element N" strict undefined - that raise must propagate (Ansible fails the task), not fall into the lenient plain-lookup
        # fallback below, which would render the "undefined" sentinel.
        # Anything else the engine raises on stays a fallback shape (an
        # engine-capability gap degrades leniently, never into a spurious
        # task failure).
        begin
          value = render_via_jinja_value(expr)
        rescue e : KrikriJinja::TemplateError
          if e.message.try(&.includes?("has no element"))
            raise UndefinedVariableError.new(bracket_index_failure(expr) || e.message.not_nil!)
          end
          return @lookup.indexed(expr)
        end

        # Round 812045 (pluggero.bibata_cursor): same strict bracket-index
        # check as the leading-paren path above - a plain `none_var[0]`
        # (JSON-null base) or `short_list[5]` (past the end) must fail the
        # task the way Ansible does, not render "undefined". A
        # `| default(...)` guard after the index never reaches this (the
        # whole chain goes through the top-level-pipe path instead, and
        # the trailing-index walk in bracket_index_failure_message stops
        # at any non-`]` tail), so leniency for guarded lookups is
        # preserved.
        if (value.nil? || value.not_nil!.raw.nil?) &&
           (failure = bracket_index_failure(expr))
          raise UndefinedVariableError.new(failure)
        end
        value ? @lookup.format_value(value) : "undefined"
      end

      # Returns nil (not a String) when *expr* is neither a dict literal
      # nor `[`-bearing at all, so evaluate_expr's caller knows to fall
      # through to the plain `.`/simple-lookup checks instead.
      private def evaluate_bracket_or_dict_expr(expr : String) : String?
        if literal_dict_expr?(expr)
          # Same rationale and pattern as the literal-array case above.
          return begin
            value = render_via_jinja_value(expr)
            value ? @lookup.format_value(value) : "undefined"
          rescue
            evaluate_dict_literal(expr)
          end
        end

        # A `[` anywhere in the string (even deep inside a method call's
        # own ARGUMENT, e.g. `{...}.get(ansible_facts['architecture'],
        # ...)` - a dict-literal `.get()` call whose argument happens to
        # contain `[...]` indexing) previously always routed to indexed-
        # access handling regardless of nesting - same class of bug as
        # VariableLookup#resolve's own identical fix, see there for the
        # full rationale (prometheus.prometheus.node_exporter's own
        # `_node_exporter_go_ansible_arch`). Only a top-level `[` that
        # comes BEFORE any top-level `(` means "this whole expression is
        # itself indexed" - a `(` appearing first means a method/filter
        # call starts before any real indexing.
        if bracket_idx = top_level_keyword_index(expr, "[")
          paren_idx = top_level_keyword_index(expr, "(")
          return evaluate_bracket_expr(expr) if !paren_idx || bracket_idx < paren_idx
        end

        nil
      end

      private def literal_array_expr?(expr : String) : Bool
        expr.starts_with?('[') && expr.ends_with?(']')
      end

      private def literal_dict_expr?(expr : String) : Bool
        expr.starts_with?('{') && expr.ends_with?('}')
      end

      # Resolves the branch selected by a ternary's condition. A branch
      # that's a plain quoted string literal (the common case - both
      # branches of `X if C else Y` are usually literals) is unquoted
      # directly rather than handed to `evaluate`, which has no top-level
      # "bare quoted literal" case of its own and would otherwise try
      # (and fail) to look it up as a variable name, quotes included.
      private def evaluate_ternary(ternary : {String, String, String}) : String
        truthy_expr, cond_expr, falsy_expr = ternary
        chosen = ConditionalEvaluator.evaluate(cond_expr, @vars) ? truthy_expr : falsy_expr
        quoted_string_literal(chosen).try(&.as_s) || evaluate(chosen)
      end

      # Splits *expr* on a top-level ` if ` ... ` else ` (outside
      # quotes/brackets), returning {truthy, condition, falsy} or nil if
      # the expression isn't a ternary at all. Only the first top-level
      # ` if ` and the last top-level ` else ` are used as delimiters, so
      # a condition that itself contains " if "/" else " inside quotes or
      # nested parens/brackets is left intact.
      private def split_ternary(expr : String) : {String, String, String}?
        return @@split_ternary_cache[expr] if @@split_ternary_cache.has_key?(expr)

        if_idx = top_level_keyword_index(expr, " if ")
        result = if if_idx
                   else_idx = top_level_keyword_index(expr, " else ", if_idx + 4)
                   if else_idx
                     truthy = expr[0...if_idx].strip
                     cond = expr[(if_idx + 4)...else_idx].strip
                     falsy = expr[(else_idx + 6)..].strip
                     (truthy.empty? || cond.empty? || falsy.empty?) ? nil : {truthy, cond, falsy}
                   end
                 end

        @@split_ternary_cache.clear if memo_cache_full?(@@split_ternary_cache, @@split_ternary_no_else_cache)
        @@split_ternary_cache[expr] = result
        result
      end

      # Splits *expr* on a top-level ` if ` with NO ` else ` clause at all
      # - Jinja2's else-less inline-if (`TRUTHY if COND`), which
      # renders as an empty string when COND is false (Jinja evaluates the
      # missing else branch to Undefined, whose default __str__ is "").
      # Real bug found benchmarking ansible-community.ansible-vault's own
      # `vault_version_release_site_suffix: "{{ '+ent' if vault_enterprise
      # }}{{ '.hsm' if vault_enterprise_hsm }}"` - previously fell through
      # to #evaluate_expr on the literal text `'+ent' if vault_enterprise`,
      # always resolving to the string "undefined" instead of "".
      private def split_ternary_no_else(expr : String) : {String, String}?
        return @@split_ternary_no_else_cache[expr] if @@split_ternary_no_else_cache.has_key?(expr)

        if_idx = top_level_keyword_index(expr, " if ")
        result = if if_idx
                   truthy = expr[0...if_idx].strip
                   cond = expr[(if_idx + 4)..].strip
                   (truthy.empty? || cond.empty?) ? nil : {truthy, cond}
                 end

        @@split_ternary_no_else_cache.clear if memo_cache_full?(@@split_ternary_cache, @@split_ternary_no_else_cache)
        @@split_ternary_no_else_cache[expr] = result
        result
      end

      private def evaluate_ternary_no_else(ternary : {String, String}) : String
        truthy_expr, cond_expr = ternary
        return "" unless ConditionalEvaluator.evaluate(cond_expr, @vars)
        quoted_string_literal(truthy_expr).try(&.as_s) || evaluate(truthy_expr)
      end

      # Finds the index of *keyword* at bracket/quote depth 0, starting the
      # scan at *from*.
      private def top_level_keyword_index(expr : String, keyword : String, from : Int32 = 0) : Int32?
        depth = 0
        quote = nil.as(Char?)
        i = from
        while i < expr.size
          char = expr[i]
          if q = quote
            quote = nil if char == q
          elsif char == '\'' || char == '"'
            quote = char
          elsif depth == 0 && expr[i, keyword.size]? == keyword
            # Checked BEFORE the generic bracket-depth adjustment below -
            # a *keyword* that is itself one of "[({"/"])}" (a single
            # bracket char, not a multi-char operator keyword) would
            # otherwise always be intercepted by the depth-adjustment
            # branch first, incrementing depth without ever reporting
            # "found at top level".
            return i
          elsif "[({".includes?(char)
            depth += 1
          elsif "])}".includes?(char)
            depth -= 1
          end
          i += 1
        end
        nil
      end

      # Whether expr has a `|` outside any bracket/paren/quote nesting -
      # reuses the same depth-tracking top_level_keyword_index already
      # does for " if "/" else ".
      private def top_level_pipe?(expr : String) : Bool
        !top_level_keyword_index(expr, "|").nil?
      end

      # Check if expression contains a comparison operator *at the top
      # level* - depth/quote-aware, like top_level_keyword_index and the
      # +/- splitters below, rather than a plain substring search. A naive
      # substring check fires on an operator nested inside a paren'd sub-
      # expression too (linux-system-roles/logging's own rsyslog subrole:
      # `a + (b if (cond_len > 0) else []) + (c | flatten)`, where the `>`
      # belongs to the ternary's own condition, not a top-level comparison
      # of the whole plus-expression) - routing the *entire* expression
      # into ComparisonEvaluator in that case makes it split on the nested
      # operator using its own naive text split, producing a garbage
      # operand with an unbalanced trailing `)`. That operand, fed back
      # into the evaluator, permanently unbalances every depth-tracking
      # scanner downstream (split_top_level_plus, FilterEngine.split_chain)
      # - each returns the *unchanged* input as "the whole thing to
      # evaluate again" once it can never find its target token at depth
      # 0, and evaluate_expr/evaluate_with_filter call each other with
      # that identical string forever: a stack overflow, not just a wrong
      # answer.
      private def has_comparison?(expr : String) : Bool
        depth = 0
        quote = nil.as(Char?)
        i = 0
        while i < expr.size
          char = expr[i]
          if q = quote
            quote = nil if char == q
          elsif char == '\'' || char == '"'
            quote = char
          elsif "[({".includes?(char)
            depth += 1
          elsif "])}".includes?(char)
            depth -= 1
          elsif depth == 0 && top_level_comparison_char?(expr, i, char)
            return true
          end
          i += 1
        end
        false
      end

      private def top_level_comparison_char?(expr : String, i : Int32, char : Char) : Bool
        two = expr[i, 2]?
        two == "==" || two == "!=" || two == "<=" || two == ">=" || char == '>' || char == '<'
      end

      # Splits *expr* on every top-level `+` (outside quotes/brackets),
      # returning nil (not a two-part array) when there's no top-level `+`
      # at all so the caller's normal routing is untouched.
      private def split_top_level_plus(expr : String) : Array(String)?
        state = PlusSplitState.new
        expr.each_char { |char| split_top_level_plus_step(state, char) }
        state.parts << state.current.to_s.strip
        state.found? ? state.parts : nil
      end

      private class PlusSplitState
        property parts = [] of String
        property current = String::Builder.new
        property depth = 0
        property quote : Char? = nil
        property? found = false
      end

      private def split_top_level_plus_step(state : PlusSplitState, char : Char) : Nil
        if quote = state.quote
          state.current << char
          state.quote = nil if char == quote
          return
        end

        return split_top_level_plus_delimiter(state, char) if "'\"[](){}".includes?(char)

        if char == '+' && state.depth == 0
          state.parts << state.current.to_s.strip
          state.current = String::Builder.new
          state.found = true
        else
          state.current << char
        end
      end

      private def split_top_level_plus_delimiter(state : PlusSplitState, char : Char) : Nil
        case char
        when '\'', '"'
          state.quote = char
        when '[', '(', '{'
          state.depth += 1
        when ']', ')', '}'
          state.depth -= 1
        end
        state.current << char
      end

      # Splits *expr* on every top-level `*`, `/`, or `//` (outside
      # quotes/brackets - `*`/`/` need no spacing requirement, unlike
      # `-`, since a bare `*` or `/` never appears inside an ordinary
      # identifier). Returns {operands, operators} (one fewer operator
      # than operand), or nil when there's no top-level `*`/`/` at all.
      private def split_top_level_mult_div(expr : String) : {Array(String), Array(String)}?
        state = MultDivSplitState.new
        chars = expr.chars
        i = 0
        while i < chars.size
          i = split_top_level_mult_div_step(state, chars, i)
        end
        state.parts << state.current.to_s.strip

        state.ops.empty? ? nil : {state.parts, state.ops}
      end

      private class MultDivSplitState
        property parts = [] of String
        property ops = [] of String
        property current = String::Builder.new
        property depth = 0
        property quote : Char? = nil
      end

      private def split_top_level_mult_div_step(state : MultDivSplitState, chars : Array(Char), i : Int32) : Int32
        char = chars[i]
        if q = state.quote
          state.current << char
          state.quote = nil if char == q
          return i + 1
        end

        case char
        when '\'', '"', '[', '(', '{', ']', ')', '}'
          split_mult_div_delimiter(state, char)
        when '*', '/'
          # The operator step's own skip-ahead return value (i + 2 for a
          # `//` pair) must propagate: the old code discarded it and
          # advanced only one character, so `10 // 0` split as
          # parts ["10", "", "0"], ops ["//", "/"] - the phantom empty
          # operand combined to JSON null, which silently papered over
          # every `//` the Crinja-first attempt didn't handle (and, after
          # combine_mult_div went strict, surfaced as a spurious
          # unsupported-operand error on the empty part).
          return split_mult_div_operator(state, chars, i, char)
        else
          state.current << char
        end
        i + 1
      end

      private def split_mult_div_delimiter(state : MultDivSplitState, char : Char) : Nil
        case char
        when '\'', '"'
          state.quote = char
        when '[', '(', '{'
          state.depth += 1
        when ']', ')', '}'
          state.depth -= 1
        end
        state.current << char
      end

      private def split_mult_div_operator(state : MultDivSplitState, chars : Array(Char), i : Int32, char : Char) : Int32
        return split_mult_div_outside(state, chars, i, char) if state.depth == 0
        state.current << char
        i + 1
      end

      private def split_mult_div_outside(state : MultDivSplitState, chars : Array(Char), i : Int32, char : Char) : Int32
        state.parts << state.current.to_s.strip
        state.current = String::Builder.new
        if char == '/'
          if i + 1 < chars.size && chars[i + 1] == '/'
            state.ops << "//"
            return i + 2
          end
          state.ops << "/"
        else
          state.ops << "*"
        end
        i + 1
      end

      # Resolves each operand (the same resolver `+`/`-` operands use -
      # a literal, a variable, or a whole sub-expression with its own
      # filter chain) and combines them left to right, matching real
      # Jinja2/Python's own arithmetic: `/` always produces a float
      # (true division, even for an evenly-divisible pair), `*`
      # preserves int when both operands are int, `//` floors to int.
      private def evaluate_mult_div(expr : String, parts : Array(String), ops : Array(String)) : String
        # Crinja-first delegation, general filter-chain-dispatch
        # construct (mult/div): try-Crinja-first, same pattern as the
        # other constructs. Probed extensively
        # against the hand-rolled path below (int/float mixes, chained
        # `*`, both directions of negative floor division, division by
        # zero) - matched in every case Crinja itself didn't cleanly
        # raise (mismatched-type operands, `//` by zero), which the
        # fallback below already handles identically. One real crash bug
        # found along the way (not a convergence regression, pre-existing
        # and unrelated to whether this construct is converged or not):
        # `10 // 0` overflowed converting `Float64::INFINITY.floor` to
        # `Int64` - fixed directly in `#combine_mult_div` below.

        render_via_jinja(expr)
      rescue
        values = parts.map { |pth| resolve_plus_operand(pth) }
        result = values[0]
        ops.each_with_index do |op, idx|
          result = combine_mult_div(result, values[idx + 1], op)
        end
        @lookup.format_value(result)
      end

      private def combine_mult_div(a : JSON::Any, b : JSON::Any, op : String) : JSON::Any
        af = numeric_operand(a)
        bf = numeric_operand(b)

        case op
        when "*"
          if af && bf
            both_int = (a.raw.is_a?(Int64) || a.raw.is_a?(Bool)) &&
                       (b.raw.is_a?(Int64) || b.raw.is_a?(Bool))
            return both_int ? JSON::Any.new((af * bf).to_i64) : JSON::Any.new(af * bf)
          end

          # Real Python/Jinja2 `*` also repeats: str*int, int*str,
          # list*int, int*list (bool counts as its int-subclass value).
          # Previously any non-numeric pair silently produced JSON null
          # (rendered as ""), so even the VALID repeat shapes
          # (`'-' * 40`, a Ansible idiom) rendered empty while
          # Ansible repeated the operand, and the invalid ones
          # (`str * list`) were silently answered where Jinja2
          # raises TypeError (found by bin/differential_fuzz).
          if (repeat = python_repeat(a, b)) || (repeat = python_repeat(b, a))
            return repeat
          end
        when "/"
          if af && bf
            return JSON::Any.new(af / bf)
          end
        when "//"
          if af && bf
            # `10 // 0` previously crashed the whole process with an
            # uncaught `OverflowError` (`(10.0 / 0.0).floor` is
            # `Float64::INFINITY`, and `Infinity.to_i64` overflows Int64) -
            # found probing whether `*`/`/`/`//` were safe to converge to
            # Crinja-first as part of the general filter-chain-dispatch
            # construct; real Crinja raises a clean `DivisionByZeroError`
            # for the same input instead of crashing, which is what exposed
            # this. `/`'s own by-zero case already degrades leniently to
            # `Infinity` rather than raising (line above) - matching that
            # existing convention here (nil/"undefined", not a crash) is
            # more consistent than introducing a hard failure only `//` has.
            return bf.zero? ? JSON::Any.new(nil) : JSON::Any.new((af / bf).floor.to_i64)
          end
        end

        # Every non-numeric, non-repeatable operand pair is a strict
        # operand-class failure - real Python/Jinja2 raises TypeError
        # (`unsupported operand type(s) for /: 'str' and 'float'`) and
        # Ansible fails the task; the old `JSON::Any.new(nil)` here
        # silently rendered "" instead.
        raise PlusMinusOperandError.new(
          "unsupported operand type(s) for #{op}: '#{python_type_name(a)}' and '#{python_type_name(b)}'")
      end

      # Python `*` repeat semantics: a String or Array operand repeated by
      # an int-coercible one (Bool counts as its int-subclass value; a
      # Float64 multiplier is a real TypeError, not a repeat). Returns nil
      # when the pair isn't a repeat shape at all. Checked in BOTH
      # orientations by the caller (`str * int` and `int * str`). A
      # negative count repeats zero times (Python semantics); a count that
      # would materialize more than MAX_REPEAT_ELEMENTS elements raises
      # rather than exhausting memory the way real Python's MemoryError
      # fails the task.
      MAX_REPEAT_ELEMENTS = 10_000_000

      private def python_repeat(value : JSON::Any, count : JSON::Any) : JSON::Any?
        return nil unless value.raw.is_a?(String) || value.raw.is_a?(Array)
        times = python_repeat_count(count) || return nil
        if value.raw.is_a?(String)
          return JSON::Any.new(times <= 0 ? "" : value.as_s * times)
        end
        base = value.as_a
        return JSON::Any.new([] of JSON::Any) if times <= 0 || base.empty?
        if times > MAX_REPEAT_ELEMENTS // base.size
          raise Exception.new("repetition of #{python_type_name(value)} by #{times} exceeds the maximum supported size")
        end
        result = [] of JSON::Any
        times.times { result.concat(base) }
        JSON::Any.new(result)
      end

      private def python_repeat_count(count : JSON::Any) : Int64?
        case raw = count.raw
        when Bool  then raw ? 1_i64 : 0_i64
        when Int64 then raw
        end
      end

      private def numeric_operand(value : JSON::Any) : Float64?
        case raw = value.raw
        when Int64
          raw.to_f64
        when Float64
          raw
        when Bool
          # Python's bool is an int subclass (True == 1, False == 0), so
          # `true * 2` is 2 in Jinja2, not a type error.
          raw ? 1.0 : 0.0
        end
      end

      # Python-equivalent numeric value of *value* for the +/- arithmetic
      # combines: a Bool coerces to its int subclass value (True == 1,
      # False == 0), an Int64/Float64 passes through, anything else is
      # nil (not arithmetic at all). Found via galaxyproject.galaxy's own
      # first task, `(galaxy_manage_clone + galaxy_manage_download +
      # galaxy_manage_existing) <= 1` with three boolean defaults -
      # Python sums those to 1 and the assert passes; here the Bools
      # fell through to the string-concat fallback ("TrueFalseFalse")
      # and the assert failed where Ansible's succeeds.
      private def python_number(value : JSON::Any) : Int64 | Float64 | Nil
        case raw = value.raw
        when Bool    then raw ? 1_i64 : 0_i64
        when Int64   then raw
        when Float64 then raw
        end
      end

      # Bool-in-arithmetic fast path shared by #combine_plus and
      # #combine_minus: when either side is a Bool and both sides are
      # numeric, operate on the Python-coerced values (int result unless
      # a float participates, matching Python's own promotion).
      private def combine_with_bool_coercion(a : JSON::Any, b : JSON::Any, op : Char) : JSON::Any?
        return nil unless a.raw.is_a?(Bool) || b.raw.is_a?(Bool)
        an = python_number(a) || return nil
        bn = python_number(b) || return nil
        if an.is_a?(Float64) || bn.is_a?(Float64)
          af = an.to_f64
          bf = bn.to_f64
          JSON::Any.new(op == '+' ? af + bf : af - bf)
        else
          ai = an.to_i64
          bi = bn.to_i64
          JSON::Any.new(op == '+' ? ai + bi : ai - bi)
        end
      end

      # Resolves and concatenates/adds every operand of a top-level `+`
      # expression, left to right - array+array concatenates, string+string
      # concatenates, number+number adds; anything else is a strict
      # operand-class failure (Ansible fails the task, see
      # #python_type_name / CRINJA_PHASE2_REPORT.md's strictness section).
      private def evaluate_plus(segments : Array(String)) : String
        values = segments.map { |seg| resolve_plus_operand(seg, strict: true) }
        result = values.reduce { |acc, val| combine_plus(acc, val) }
        @lookup.format_value(result)
      end

      # Strict `+` operand-class gate for the dispatch's Crinja-first
      # branch - see the call site above for why it must run BEFORE
      # Crinja. Re-runs the exact fallback resolution + combination
      # (evaluate_plus's own code path, strict raise included); only
      # PlusMinusOperandError propagates, everything else is "this
      # shape can't be validated conservatively".
      private def validate_plus_operands_strictly(expr : String, segments : Array(String)) : Nil
        return if expr.includes?("lookup(") || expr.includes?("query(")

        begin
          values = segments.map { |seg| resolve_plus_operand(seg, strict: true) }
          values.reduce { |acc, val| combine_plus(acc, val) }
        rescue e : PlusMinusOperandError
          raise e
        rescue
          nil
        end
      end

      private def resolve_plus_operand(expr : String, strict : Bool = false) : JSON::Any
        expr = expr.strip
        # Strict +/- mode, undefined filter-chain operand: Ansible
        # hard-fails `'a' + undef_var|string` ("'undef_var' is undefined")
        # - the lenient render path below collapses the chain to "" and
        # silently concatenates. Same conservative probe the bare-reference
        # branch further down already uses (bare head genuinely absent from
        # vars, first filter not undefined-tolerant), so an evaluator gap
        # still can't become a spurious failure. Only the `+`/`-` constructs
        # pass strict: true; `~` and mult/div keep the lenient default
        # (b6a5a157's deliberate scope boundary).
        if strict && (undefined_name = Krikri.undefined_filter_chain_source(expr, @vars))
          raise PlusMinusOperandError.new(Krikri.strict_undefined_message(undefined_name, @vars))
        end
        value = resolve_plus_operand_literal(expr)
        return value if value
        value = resolve_plus_operand_mult_div(expr)
        return value if value
        value = resolve_plus_operand_recursive(expr)
        return value if value

        # Strict +/- mode (only the `+`/`-` constructs pass strict: true;
        # `~` and mult/div's operand fallback keep the lenient default):
        # the `omit` keyword and a `none` literal resolve to their real
        # values here so the combine-time strict check can see them as the
        # operand classes Ansible fails on (an omit operand reaches
        # the combine as OMIT_SENTINEL; NoneType as JSON null), instead of
        # a plain-name lookup that can't see either and would report them
        # as undefined.
        if strict
          return JSON::Any.new(OMIT_SENTINEL) if expr == "omit"
          return JSON::Any.new(nil) if expr == "none" || expr == "None"
        end

        resolved = @lookup.resolve(expr)

        # Ansible's recursive re-templating - the fifth (and, so
        # far, last) independent plain-lookup fallback in this engine
        # found needing this exact fix, alongside ConditionalEvaluator's
        # bare when:, ExpressionEvaluator's filter-chain head,
        # FilterEngine's default() argument, and ComparisonEvaluator's
        # bare comparison operand. Found via cloudalchemy.prometheus's
        # own `go_arch: "{{ go_arch_map[ansible_architecture] | default(
        # ansible_architecture) }}"` (role vars/main.yml, not defaults/)
        # used as a bare `+`-operand inside `('linux-' + go_arch +
        # '.tar.gz') in item` - `{{ go_arch }}` alone rendered correctly
        # elsewhere (a different, already-fixed code path), but this
        # plain-lookup fallback for a bare `+`/`~` operand returned the
        # raw, unrendered template text, so the "in" check against every
        # real checksum-file line always came back false.
        if value = retemplated_lookup_value(resolved, expr)
          return value
        end

        # Strict +/- mode, genuinely-missing operand: Ansible hard-
        # fails the task on `missing_var + 'x'` ("'missing_var' is
        # undefined", live-verified against 2.19.11) - the old lenient
        # null-collapse here made krikri silently produce the right-hand
        # side instead. Deliberately gated on the same conservative
        # bare-reference shape the strict: substitution path uses
        # (REGEX_BARE_VAR_REF): an operand resolve can also come back nil
        # for a shape this evaluator simply can't resolve (a lookup(...)
        # call, a crinja-only filter chain) - failing THOSE would turn an
        # evaluator gap into a spurious task failure.
        # An out-of-range (or None-base) integer bracket index is a real
        # task failure in Ansible for EVERY construct, lenient or
        # strict - the engine (krikri-jinja v0.4.20) raises the same way,
        # and bracket_index_failure_message diagnoses the shape with
        # Ansible's own message. nil for every shape it can't pin down
        # (missing bare references stay on the strict/lenient gates
        # below; dict-key misses stay lenient by long-standing
        # convention).
        if resolved.nil? && (failure = bracket_index_failure(expr))
          raise PlusMinusOperandError.new(failure)
        end

        if resolved.nil? && strict && REGEX_BARE_VAR_REF.matches?(expr)
          raise PlusMinusOperandError.new(Krikri.strict_undefined_message(expr, @vars))
        end

        resolved || JSON::Any.new(nil)
      end

      private def resolve_plus_operand_literal(expr : String) : JSON::Any?
        if literal = quoted_string_literal(expr) || numeric_literal(expr) ||
                     bool_literal(expr)
          return literal
        end

        return parse_literal_array(expr) if expr.starts_with?('[') && expr.ends_with?(']')

        # A dict-literal operand (`{'name': item['name'], 'home': item[
        # 'home']}` inside `acc | default([]) + [{...}]` - diodonfrost.
        # p10k's own user-info accumulator, round 601558) needs the same
        # treatment the array-literal case above already gets: without
        # it the raw `{...}` text fell through to a plain variable-name
        # lookup, which cannot resolve it, so every accumulated element
        # came back null. Reuses evaluate_dict_literal (already the
        # top-level dict-literal path) and parses its output back into
        # structured data - format_value of a Hash is JSON-compact
        # on purpose for exactly this round trip.
        if literal_dict_expr?(expr)
          rendered = evaluate_dict_literal(expr)
          return (JSON.parse(rendered) rescue JSON::Any.new(rendered))
        end

        nil
      end

      private def resolve_plus_operand_mult_div(expr : String) : JSON::Any?
        # A `*`/`/`/`//` sub-expression nested inside a `+`/`-` operand
        # (`2 + 3 * 4`'s own right-hand `+`-segment) - checked here so
        # `*`/`/` bind tighter than the `+`/`-` that already split this
        # segment out, matching Jinja2 precedence.
        if mult_div = split_top_level_mult_div(expr)
          parts, ops = mult_div
          rendered = evaluate_mult_div(expr, parts, ops)
          return (JSON.parse(rendered) rescue JSON::Any.new(rendered))
        end
        nil
      end

      private def resolve_plus_operand_recursive(expr : String) : JSON::Any?
        # A filter chain or parenthesized sub-expression operand (`acc |
        # default([])` in `acc | default([]) + [item]`) needs the full
        # recursive evaluator, not the plain variable lookup below, which
        # only ever resolves a bare/dotted/indexed name.
        if expr.includes?('|') || (expr.starts_with?('(') && expr.ends_with?(')'))
          # Crinja (krikri-jinja) FIRST, as a typed structured value: `|`
          # binds tighter than `+`, so a filter-chain operand's own result
          # type is what `combine_plus` must see - `v|string` on a float
          # var is the STRING "4.0", not the float the old
          # stringify-then-`JSON.parse` round trip below turned it into
          # (mrlesmithjr.mongodb round 981080: `'https://x/server-' +
          # v|string + '.asc'` hard-failed "can only concatenate str
          # (not "float") to str" where Ansible concatenated). A
          # stringly-typed re-parse cannot distinguish a str that merely
          # LOOKS numeric from a real number; only the structured engine
          # result can. nil (Crinja-undefined) deliberately falls through
          # to the old path so strict-undefined operand handling is
          # untouched. Side-effecting lookups skip the Crinja attempt:
          # a failure here would fall back to #evaluate below and run
          # the lookup a second time.
          unless side_effecting_call?(expr)
            begin
              if value = render_via_jinja_value(expr)
                return value
              end
            rescue
              # fall through to the hand-rolled path below
            end
          end
          rendered = evaluate(expr)
          # `return X rescue Y` is NOT `return (X rescue Y)` in Crystal -
          # the rescue modifier attaches to the whole `return X` statement,
          # so when X raises, the exception is caught but `return` never
          # completed and Y's value is simply discarded, falling through
          # to whatever comes after this `if` block instead of actually
          # returning it. `rendered` is frequently plain unparseable text
          # ("local-modules" is not valid JSON) - every such case silently
          # fell through to @lookup.resolve(expr) below, which can't
          # resolve raw pipe/paren text either, collapsing the whole `+`
          # operand to undefined (found via linux-system-roles/logging's
          # rsyslog subrole building a config filename: `(inner_item.name
          # | d('rules')) + ...` inside a larger `+` chain silently
          # dropped the name entirely). Parenthesizing forces the rescue
          # to actually produce the value `return` sends back.
          return (JSON.parse(rendered) rescue JSON::Any.new(rendered))
        end

        nil
      end

      # Whether *source_expr* reads a hostvars entry key that is
      # execution-resolved for the OWNING host - see
      # HostvarsContext.origin_host_and_key.
      private def hostvars_origin_unsafe?(source_expr : String?) : Bool
        return false unless source_expr
        if hk = HostvarsContext.origin_host_and_key(@vars, source_expr)
          VarSubstitutor.resolved_var_name?(hk[0], hk[1])
        else
          false
        end
      end

      # Re-renders a plain-lookup result whose own raw value is still
      # unrendered Jinja template text (`{%`/`{#` block tags need the
      # full Crinja renderer; a `{{ }}`-span re-enters this evaluator) -
      # nil when the value isn't template text at all. *source_expr* is
      # the expression the value was resolved FROM: a root published as
      # execution-resolved (registered result / set_fact / fact / loop
      # item) makes the value unsafe - returned verbatim, never
      # re-rendered (ansible-core's AnsibleUnsafe semantics).
      private def retemplated_lookup_value(resolved : JSON::Any?, source_expr : String? = nil) : JSON::Any?
        return nil unless resolved
        return nil if VarSubstitutor.unsafe_root?(@vars, source_expr)
        # The OTHER host's registry: a value read through
        # `hostvars[<other>].<name>` whose name is execution-resolved for
        # THAT host (registered result / set_fact / fact) is verbatim
        # content - never re-rendered, no matter that the reading host's
        # own registry knows nothing of the name.
        return nil if hostvars_origin_unsafe?(source_expr)

        # A hostvars-rooted expression re-renders with the OTHER host's
        # scope (Ansible's HostVarsVars templar) - see
        # HostvarsContext. The unsafe gates above/below still apply: the
        # other host's own execution-resolved values are gated by its
        # registry (the merged scope carries its inventory_hostname), and
        # hostile stored text by the value-level registry.
        render_vars = if (host = HostvarsContext.origin_host(@vars, source_expr)) &&
                         (merged = HostvarsContext.merged_vars(host, @vars))
                        merged
                      else
                        @vars
                      end

        # An Array/Hash resolved value can hold nested String elements
        # that are STILL unrendered `{{ }}` text one level down - the
        # same class of gap `JinjaRenderer.rerender_nested_templates`
        # exists for (already shared process-wide for the Crinja
        # context-conversion path), just never reached from THIS
        # plain-lookup fallback before. Found live via jtyr.motd's own
        # `motd_info: "{{ motd_info__default + motd_info__custom }}"`:
        # `motd_info__default`'s own list items are dicts whose VALUES
        # are each a further `{{ ansible_facts.fqdn }}`-style
        # indirection - resolving the bare `+`-operand `motd_info__
        # default` here returned the raw, un-re-rendered array, so the
        # rendered MOTD showed literal `{{ ansible_facts.fqdn }}` text
        # instead of the real hostname (confirmed live against a real
        # host). Delegates to the exact same recursive helper the
        # Crinja path already uses, rather than a second, separately-
        # maintained copy.
        raw = resolved.raw
        if raw.is_a?(Array) || raw.is_a?(Hash)
          # defer_unresolved: Jinja2/Ansible templates a container's
          # values lazily, on access - a filter chain over a list of dicts
          # (`mylist | selectattr('state', ...)`) that only ever reads ONE
          # field must not fail on a SIBLING field whose own template
          # references an intentionally-undefined caller variable
          # (stackhpc.libvirt-vm's default libvirt_vms list, round 952484:
          # `name: "{{ libvirt_vm_name }}"` next to a `when:` that only
          # filters on `state`). The eager whole-structure render below is
          # kept (it feeds every full-structure consumer: sort/join/combine/
          # to_json...), but a leaf that bottoms out at an undefined name is
          # left raw so the chain behaves like Jinja's lazy containers;
          # access points that DO read the leaf render it strictly
          # (FilterEngine's map/selectattr attribute extraction and the
          # to_json-family serializers), so nothing that today hard-fails
          # silently succeeds with different values.
          return JinjaRenderer.rerender_nested_templates(resolved, VarSubstitutor.new(vars: render_vars), defer_unresolved: true)
        end

        return nil unless raw.is_a?(String)
        return nil if UnsafeValues.unsafe_text?(raw)
        if raw.includes?("{%") || raw.includes?("{#")
          # Block tags need the full Crinja renderer, not this plain
          # `{{ }}`-only evaluator - see variable_lookup.cr's identical
          # fix for the full rationale (found via prometheus.prometheus's
          # own _common role's `_common_dependencies` default).
          rendered = JinjaRenderer.new(render_vars, @decode).render(raw)
          return (JSON.parse(rendered) rescue JSON::Any.new(rendered))
        end

        return nil unless raw.includes?("{{")
        # Strict-span parity (live-verified vs 2.19.11, p12 probe): a
        # whole-single-span templated value read through this plain-lookup
        # fallback under an active strict span re-renders STRICTLY - a
        # `vars:` value of `{{ undefined_deep }}` consumed by
        # `"{{ 'a' ~ badvar ~ 'b' }}"` fails at the use site
        # ("'undefined_deep' is undefined"), exactly like the
        # VariableLookup whole-span path already does; the old lenient
        # `evaluate(inner)` here silently collapsed the value to "" and
        # both a task NAME's warning block and a module arg's strict
        # finalization never saw the failure. Multi-part and block-tag
        # values keep the lenient render: real renders those with inline
        # error markers instead of raising (p6 probe).
        if VarSubstitutor.strict_span_active? &&
           (ws = raw.strip).starts_with?("{{") && ws.ends_with?("}}") &&
           (raw.split("{{").size - 1) == 1 && (raw.split("}}").size - 1) == 1
          rendered = VarSubstitutor.new(vars: render_vars).substitute(raw, strict: true)
          return (JSON.parse(rendered) rescue JSON::Any.new(rendered))
        end
        inner = raw.strip
        inner = inner[2..-3].strip if inner.starts_with?("{{") && inner.ends_with?("}}")
        rendered = render_vars.same?(@vars) ? evaluate(inner) : ExpressionEvaluator.new(render_vars, @decode).evaluate(inner)
        (JSON.parse(rendered) rescue JSON::Any.new(rendered))
      end

      # Splits *expr* on every top-level `~` (outside quotes/brackets),
      # same depth-tracking approach as #split_top_level_plus - a
      # separate copy (rather than a parameterized shared helper) since
      # `~` needs none of #split_top_level_plus's `+`-vs-`-`-adjacent
      # bookkeeping.
      private def split_top_level_tilde(expr : String) : Array(String)?
        parts = [] of String
        current = String::Builder.new
        depth = 0
        quote = nil.as(Char?)
        found = false

        expr.each_char do |char|
          if q = quote
            current << char
            quote = nil if char == q
            next
          end

          case char
          when '\'', '"'
            quote = char
            current << char
          when '[', '(', '{'
            depth += 1
            current << char
          when ']', ')', '}'
            depth -= 1
            current << char
          when '~'
            if depth == 0
              parts << current.to_s.strip
              current = String::Builder.new
              found = true
            else
              current << char
            end
          else
            current << char
          end
        end

        parts << current.to_s.strip
        found ? parts : nil
      end

      # `~` always stringifies both operands (unlike `+`, which errors on
      # a type mismatch) - reuses #resolve_plus_operand for parsing each
      # segment (literal/paren/filter-chain/plain-variable resolution is
      # identical either way), then joins their string forms directly
      # rather than #combine_plus's type-preserving add/concat.
      private def evaluate_tilde(segments : Array(String)) : String
        segments.map { |seg| @lookup.format_value(resolve_plus_operand(seg)) }.join
      end

      private def quoted_string_literal(expr : String) : JSON::Any?
        return nil if expr.size < 2
        return nil unless expr[0] == expr[-1] && (expr[0] == '\'' || expr[0] == '"')
        JSON::Any.new(expr[1..-2])
      end

      # Stricter counterpart to #quoted_string_literal: nil unless *expr*
      # is a single quoted literal spanning its ENTIRE length, not just
      # matching first/last characters. `'a' + var + 'b'` starts and
      # ends with `'` too but is a `+` chain, not one literal -
      # confirmed by walking from the opening quote and requiring its
      # first unescaped matching close to be the expression's last
      # character.
      private def sole_quoted_literal?(expr : String) : String?
        return nil if expr.size < 2
        quote = expr[0]
        return nil unless quote == '\'' || quote == '"'

        i = 1
        while i < expr.size
          char = expr[i]
          if char == '\\' && i + 1 < expr.size
            i += 2
            next
          end
          if char == quote
            return i == expr.size - 1 ? expr[1...i] : nil
          end
          i += 1
        end
        nil
      end

      private def numeric_literal(expr : String) : JSON::Any?
        if int_val = expr.to_i64?
          JSON::Any.new(int_val)
        elsif float_val = expr.to_f64?
          JSON::Any.new(float_val)
        end
      end

      # A bare `true`/`false`/`True`/`False` literal operand - real
      # Jinja2/Python accepts both capitalizations, and a Bool operand
      # reaches the +/- combines as its int-subclass value.
      private def bool_literal(expr : String) : JSON::Any?
        case expr
        when "true", "True"   then JSON::Any.new(true)
        when "false", "False" then JSON::Any.new(false)
        end
      end

      # Python/Jinja2 `range(stop)` / `range(start, stop)` /
      # `range(start, stop, step)` - each argument may itself be an
      # expression (a variable, a filter chain, ...), so every part is
      # evaluated (not just parsed as a literal int) before being coerced
      # to Int32. Matches Python's own half-open, stop-exclusive range.
      # Whether *expr* is ENTIRELY one bare `prefix(...)` function call -
      # not just "starts with prefix( and ends with some )", which a
      # trailing filter chain's own closing paren can satisfy too
      # (`lookup('env', 'X') | default('2.0.3', true)` starts with
      # "lookup(" and does end with ")" - just default(...)'s, not
      # lookup(...)'s own matching one). Finds the paren that actually
      # matches `prefix`'s own opening one (depth/quote-aware) and
      # confirms it's the expression's last character; if there's
      # trailing content after it (like " | default(...)"), this isn't
      # a bare call at all. Real bug found benchmarking ansible-
      # community.ansible-vault's own `lookup('env', 'VAULT_VERSION') |
      # default('2.0.3', true)`: the naive check swallowed the entire
      # string (filter chain included) into evaluate_lookup as one
      # garbled, unbalanced argument, never reaching top_level_pipe?/
      # evaluate_with_filter at all.
      # Returns the index of the closing paren that matches the opening
      # paren at *open_index*, depth/quote-aware - unlike #bare_call?,
      # doesn't require that close to be the expression's last
      # character, so a caller can locate a call's real end even when
      # something else (a chained `.method()`) follows it. nil if
      # *open_index* isn't actually an open paren or none matches.
      private def matching_close_paren_index(expr : String, open_index : Int32) : Int32?
        return nil unless expr[open_index]? == '('

        depth = 1
        quote : Char? = nil
        ((open_index + 1)...expr.size).each do |i|
          char = expr[i]
          if quote
            quote = nil if char == quote
            next
          end
          case char
          when '\'', '"'
            quote = char
          when '('
            depth += 1
          when ')'
            depth -= 1
            return i if depth == 0
          end
        end
        nil
      end

      private def bare_call?(expr : String, prefix : String) : Bool
        return false unless expr.starts_with?(prefix) && expr.ends_with?(')')

        depth = 0
        quote : Char? = nil
        (prefix.size...expr.size).each do |i|
          char = expr[i]
          if quote
            quote = nil if char == quote
            next
          end
          case char
          when '\'', '"'
            quote = char
          when '('
            depth += 1
          when ')'
            if depth == 0
              return i == expr.size - 1
            end
            depth -= 1
          end
        end
        false
      end

      private def evaluate_range(args : String) : JSON::Any
        parts = split_top_level_commas(args).map { |part| resolve_plus_operand(part).as_i }
        start, stop, step = case parts.size
                            when 1 then {0, parts[0], 1}
                            when 2 then {parts[0], parts[1], 1}
                            else        {parts[0], parts[1], parts[2]}
                            end
        return JSON::Any.new([] of JSON::Any) if step == 0

        values = [] of JSON::Any
        n = start
        if step > 0
          while n < stop
            values << JSON::Any.new(n.to_i64)
            n += step
          end
        else
          while n > stop
            values << JSON::Any.new(n.to_i64)
            n += step
          end
        end
        JSON::Any.new(values)
      end

      # `dict(iterable)` - see the `bare_call?(expr, "dict(")` call site
      # above for the full rationale. *args* is the single positional
      # argument's raw text (a filter chain or bare variable), resolved
      # to an array of 2-element [key, value] arrays/pairs.
      private def evaluate_dict_call(args : String) : JSON::Any
        pairs = resolve_plus_operand(args)
        return JSON::Any.new(Hash(String, JSON::Any).new) unless raw = pairs.as_a?

        result = Hash(String, JSON::Any).new
        raw.each do |pair|
          items = pair.as_a?
          next unless items && items.size == 2
          result[items[0].as_s? || items[0].to_json] = items[1]
        end
        JSON::Any.new(result)
      end

      # A literal Jinja dict (`{item.name: new_value}`, `{"a": 1}`) - each
      # key AND value resolved as a full expression via resolve_plus_
      # operand (a bare identifier, dotted path, quoted literal, or filter
      # chain), unlike FilterEngine's own parse_dict_literal (used only
      # for a filter argument like `combine({...})`), which treats the key
      # as literal already-final text. A key that resolves to a non-
      # string (e.g. a bare number) is stringified, matching how a real
      # dict's string keys work once templated.
      private def evaluate_dict_literal(expr : String) : String
        inner = expr[1..-2].strip
        return @lookup.format_value(JSON::Any.new(Hash(String, JSON::Any).new)) if inner.empty?

        h = Hash(String, JSON::Any).new
        split_top_level_commas(inner).each do |pair|
          key_part, sep, val_part = pair.partition(':')
          next if sep.empty?

          key_value = resolve_plus_operand(key_part.strip)
          key = key_value.as_s? || key_value.as_i64?.try(&.to_s) || @lookup.format_value(key_value)
          value = resolve_plus_operand(val_part.strip)
          # An `omit` VALUE drops its whole key, the same way it drops a
          # module parameter - verified against ansible-core 2.19.4:
          # `{{ {'a': 1, 'b': v_omit} }}` renders as `{"a": 1}`, not as a
          # "b" key holding a placeholder. Without this the raw sentinel
          # text became the key's real value.
          next if omit?(value)
          h[key] = value
        end

        @lookup.format_value(JSON::Any.new(h))
      end

      # A literal Jinja list (`['/dev', '/dev/shm']`) is valid Python/Jinja
      # syntax but not valid JSON on account of the single quotes - swapped
      # for double quotes before parsing, which is good enough for the
      # common case of a literal list of unquoted or simply-quoted string
      # items (this codebase's only real use of `+ [...]`).
      # A literal Jinja list (`['/dev', '/dev/shm']`, or `[item]` - a
      # single-element array wrapping a *variable* reference, dev-sec
      # os_hardening's own `acc | default([]) + [item]` accumulator
      # pattern) - each element is resolved the same way any other `+`
      # operand is (literal, or a variable/dotted/indexed lookup),
      # rather than requiring the whole thing to already be valid JSON
      # (which a bare identifier element like `item` never is).
      private def parse_literal_array(expr : String) : JSON::Any
        inner = expr[1..-2].strip
        return JSON::Any.new([] of JSON::Any) if inner.empty?

        # An `omit` ELEMENT is removed from the list rather than kept as
        # a placeholder - verified against ansible-core 2.19.4:
        # `{{ [1, v_omit, 3] }}` renders as `[1, 3]`.
        elements = split_top_level_commas(inner)
          .map { |elem| resolve_plus_operand(elem) }
          .reject { |elem| omit?(elem) }
        JSON::Any.new(elements)
      end

      # Whether *value* is the omit sentinel (see Krikri::
      # OMIT_SENTINEL) - the marker Ansible's `omit` leaves behind
      # for a container/parameter to drop rather than render.
      private def omit?(value : JSON::Any) : Bool
        value.as_s? == OMIT_SENTINEL
      end

      private def split_top_level_commas(expr : String) : Array(String)
        state = PlusSplitState.new
        expr.each_char { |char| split_top_level_commas_step(state, char) }
        final = state.current.to_s.strip
        # A trailing comma is legal Python/Jinja syntax for list/dict
        # literals (and call argument lists), yielding no extra element - the
        # final buffered part is empty exactly then, and keeping it made each
        # element parser see a bogus empty operand (`['a', 'b', ]` evaluated
        # a variable named ''; round 5250000, cans.package-install).
        state.parts << final unless final.empty? && !state.parts.empty?
        state.parts
      end

      private def split_top_level_commas_step(state : PlusSplitState, char : Char) : Nil
        if quote = state.quote
          state.current << char
          state.quote = nil if char == quote
          return
        end

        return split_top_level_plus_delimiter(state, char) if "'\"[](){}".includes?(char)

        if char == ',' && state.depth == 0
          state.parts << state.current.to_s.strip
          state.current = String::Builder.new
        else
          state.current << char
        end
      end

      # Ansible's Python type name for a +/- operand value, for the
      # strict failure messages (`unsupported operand type(s) for +:
      # 'NoneType' and 'str'`). The OMIT_SENTINEL string is this
      # codebase's own encoding of Ansible's omit - live-verified
      # against local ansible-core: real Python reports an omit operand
      # by its class name `_OmitType` (`can only concatenate str (not
      # "_OmitType") to str`, `unsupported operand type(s) for +:
      # '_OmitType' and 'str'`), so the older plain-"omit" wording here
      # was renamed to match.
      private def python_type_name(value : JSON::Any) : String
        return "_OmitType" if value.raw == OMIT_SENTINEL
        case value.raw
        when Nil     then "NoneType"
        when Bool    then "bool"
        when Int64   then "int"
        when Float64 then "float"
        when String  then "str"
        when Array   then "list"
        when Hash    then "dict"
        else              "object"
        end
      end

      private def combine_plus(a : JSON::Any, b : JSON::Any) : JSON::Any
        # The omit sentinel is itself a String, so it would otherwise hit
        # the {String, String} branch below and silently concatenate -
        # Ansible fails the task on an omit operand (`_OmitType`).
        # Omit on the LEFT: every real Python class pair fails the same
        # way (`unsupported operand type(s) for +: '_OmitType' and 'str'`).
        # Omit on the RIGHT is side-dependent - str/list left operands
        # fail with the concat wording (`can only concatenate str (not
        # "_OmitType") to str`, live-verified), everything else with the
        # unsupported-operand wording - so it is left to the typed
        # branches below, which the sentinel (a String) would otherwise
        # silently concatenate into.
        if a.raw == OMIT_SENTINEL
          raise PlusMinusOperandError.new(
            "unsupported operand type(s) for +: '#{python_type_name(a)}' and '#{python_type_name(b)}'")
        end
        if b.raw == OMIT_SENTINEL
          case a.raw
          when String
            raise PlusMinusOperandError.new(
              %(can only concatenate str (not "#{python_type_name(b)}") to str))
          when Array
            raise PlusMinusOperandError.new(
              %(can only concatenate list (not "#{python_type_name(b)}") to list))
          else
            raise PlusMinusOperandError.new(
              "unsupported operand type(s) for +: '#{python_type_name(a)}' and '#{python_type_name(b)}'")
          end
        end

        if coerced = combine_with_bool_coercion(a, b, '+')
          return coerced
        end

        case {a.raw, b.raw}
        when {Array, Array}
          JSON::Any.new(a.as_a + b.as_a)
        when {String, String}
          JSON::Any.new(a.as_s + b.as_s)
        when {Int64, Int64}
          JSON::Any.new(a.as_i64 + b.as_i64)
        when {Float64, Float64}
          JSON::Any.new(a.as_f + b.as_f)
        when {Int64, Float64}
          JSON::Any.new(a.as_i64.to_f64 + b.as_f)
        when {Float64, Int64}
          JSON::Any.new(a.as_f + b.as_i64.to_f64)
        when {String, _}
          # Real Python/Ansible: a str left operand can only concatenate
          # another str (`can only concatenate str (not "NoneType") to
          # str`) - previously this branch string-concatenated the
          # rendered forms, silently absorbing null/omit/number/list
          # operands Ansible hard-fails on.
          raise PlusMinusOperandError.new(
            "can only concatenate str (not \"#{python_type_name(b)}\") to str")
        when {Array, _}
          raise PlusMinusOperandError.new(
            "can only concatenate list (not \"#{python_type_name(b)}\") to list")
        else
          raise PlusMinusOperandError.new(
            "unsupported operand type(s) for +: '#{python_type_name(a)}' and '#{python_type_name(b)}'")
        end
      end

      # Finds the first top-level " - " (spaces required - see the
      # `evaluate` call site for why), outside quotes/brackets/parens,
      # and splits *expr* around it. nil if there's no such split point at
      # all (not a subtraction expression).
      private class QuoteDepthTracker
        property depth = 0
        property quote : Char? = nil

        def advance(char : Char) : Nil
          if q = quote
            self.quote = nil if char == q
            return
          end
          advance_unquoted(char)
        end

        private def advance_unquoted(char : Char) : Nil
          case char
          when '\'', '"'     then self.quote = char
          when '(', '[', '{' then self.depth += 1
          when ')', ']', '}' then self.depth -= 1
          end
        end

        def top_level? : Bool
          quote.nil? && depth == 0
        end
      end

      private def split_top_level_minus(expr : String) : {String, String}?
        tracker = QuoteDepthTracker.new
        expr.each_char.with_index do |char, i|
          tracker.advance(char)
          return {expr[0...i].strip, expr[(i + 1)..].strip} if tracker.top_level? && spaced_minus_at?(expr, i)
        end
        nil
      end

      private def spaced_minus_at?(expr : String, i : Int32) : Bool
        return false unless expr[i] == '-'
        i > 0 && expr[i - 1] == ' ' && i + 1 < expr.size && expr[i + 1] == ' '
      end

      # The Crinja-first attempt for a leading-paren expression, split out
      # of #evaluate_expr_access so the strict bracket-index check below
      # sits OUTSIDE the blanket rescue (a raise from it must propagate as
      # a real task failure, not be swallowed into the hand-rolled
      # fallback and silently collapse to "undefined" again).
      private def evaluate_leading_paren_crinja_first(expr : String, paren : {String, String}) : String
        begin
          value = render_via_jinja_value(expr)
        rescue e : KrikriJinja::TemplateError
          # The engine's out-of-range list/tuple subscript failure is a
          # real task failure, not an engine-capability gap - surface it
          # as this evaluator's own strict bracket-index error (same
          # UndefinedVariableError type and krikri message convention the
          # plain-bracket path raises) instead of degrading to the lenient
          # hand-rolled fallback.
          if e.message.try(&.includes?("has no element"))
            raise UndefinedVariableError.new(bracket_index_failure(expr) || e.message.not_nil!)
          end
          return evaluate_leading_paren(paren)
        end

        # Crinja resolves a bracket index into Python None (or an
        # out-of-range index into a real list) to its own Undefined -
        # a Crystal nil here, indistinguishable from a genuinely-undefined
        # base - so the strict check runs on BOTH a nil result and a
        # defined-but-null (real None) one before anything renders.
        if (value.nil? || value.not_nil!.raw.nil?) &&
           (failure = bracket_index_failure(expr))
          raise UndefinedVariableError.new(failure)
        end
        return "undefined" unless value
        @lookup.format_value(value)
      end

      # Krikri.bracket_index_failure_message for this expression, with any
      # internal evaluation failure (unknown Crinja feature, depth guard)
      # demoted to "no detectable failure" so the strict check can never
      # turn an evaluator gap into a spurious task failure.
      private def bracket_index_failure(expr : String) : String?
        begin
          Krikri.bracket_index_failure_message(expr, @vars)
        rescue
          nil
        end
      end

      # Resolves each side (same operand resolution `+` uses - a literal,
      # a variable, or a whole sub-expression with its own filter chain)
      # and subtracts them: two `to_datetime(...)`-tagged values produce a
      # timedelta, two numbers subtract normally, anything else is
      # undefined (unlike `+`, there's no sensible generic fallback for
      # `-`).
      private def evaluate_leading_paren(paren : {String, String}) : String
        inner, suffix = paren
        rendered = evaluate(inner.strip)
        return rendered if suffix.empty?

        parsed = JSON.parse(rendered) rescue JSON::Any.new(rendered)
        walk_part, filter_part = split_suffix_walk_and_filters(suffix)
        # The split cuts at the `|` itself, so the walk-able prefix keeps
        # the blank before it (".versions | ..." -> ".versions ") -
        # `@lookup.walk` does no trimming of its own, so that trailing
        # blank made it look up the dict key "versions " and return nil,
        # collapsing the whole expression to "undefined". Same
        # diodonfrost.vagrant shape as the Crinja-side unknown-filter
        # gate in `JinjaRenderer#evaluate_value!` - this is that
        # branch's hand-rolled fallback path, which a non-Crinja filter
        # name (one only FilterEngine implements) still reaches.
        walk_part = walk_part.strip

        value = if walk_part.empty?
                  parsed
                else
                  walked = @lookup.walk(parsed, walk_part)
                  return "undefined" unless walked
                  walked
                end

        return @lookup.format_value(value) if filter_part.strip.empty?

        segments = FilterEngine.split_chain(filter_part.strip)
        result = segments.reduce(value) { |acc, filter_expr| @filter.apply(acc, filter_expr) }
        @lookup.format_value(result)
      end

      # A leading-paren suffix (`(expr).foo[0] | bar(...)`) can carry a
      # dotted/indexed access portion, a `|`-chained filter pipeline, or
      # both - `@lookup.walk` only understands the former, so a suffix
      # that's a pure filter chain (dev-sec os_hardening's own
      # `((sysctl_config | combine(...)) | combine(...)) | combine(...)`,
      # where the leading-paren's own suffix is another `| combine(...)`)
      # previously went straight into `walk`, which had no `.attr`/`[idx]`
      # to find and returned nil, collapsing the whole expression to
      # "undefined". Splits at the first top-level `|` (respecting quotes/
      # bracket depth, same approach as FilterEngine.split_chain) so the
      # walk-able prefix and the filter-chain remainder are handled
      # separately.
      private def split_suffix_walk_and_filters(suffix : String) : {String, String}
        tracker = QuoteDepthTracker.new
        suffix.each_char.with_index do |char, i|
          tracker.advance(char)
          return {suffix[0...i], suffix[(i + 1)..]} if char == '|' && tracker.top_level?
        end
        {suffix, ""}
      end

      private def evaluate_minus(left_expr : String, right_expr : String) : String
        left = resolve_plus_operand(left_expr, strict: true)
        right = resolve_plus_operand(right_expr, strict: true)
        @lookup.format_value(combine_minus(left, right))
      end

      private def combine_minus(a : JSON::Any, b : JSON::Any) : JSON::Any
        if (a_epoch = datetime_epoch(a)) && (b_epoch = datetime_epoch(b))
          return timedelta(a_epoch - b_epoch)
        end

        # Same omit-sentinel guard as #combine_plus - a sentinel String
        # would otherwise fall to the strict else branch anyway, but with
        # the operand named "omit" instead of its type.
        if a.raw == OMIT_SENTINEL || b.raw == OMIT_SENTINEL
          raise PlusMinusOperandError.new(
            "unsupported operand type(s) for -: '#{python_type_name(a)}' and '#{python_type_name(b)}'")
        end

        if coerced = combine_with_bool_coercion(a, b, '-')
          return coerced
        end

        case {a.raw, b.raw}
        when {Int64, Int64}
          JSON::Any.new(a.as_i64 - b.as_i64)
        when {Float64, Float64}
          JSON::Any.new(a.as_f - b.as_f)
        when {Int64, Float64}
          JSON::Any.new(a.as_i64.to_f64 - b.as_f)
        when {Float64, Int64}
          JSON::Any.new(a.as_f - b.as_i64.to_f64)
        else
          # Real Python/Ansible: `-` only supports numeric (and the
          # datetime/bool cases above) - every other operand class
          # (strings, lists, null, omit) hard-fails the task
          # (`unsupported operand type(s) for -: 'NoneType' and 'str'`).
          # Previously this branch returned JSON null, which the caller
          # rendered as the empty string.
          raise PlusMinusOperandError.new(
            "unsupported operand type(s) for -: '#{python_type_name(a)}' and '#{python_type_name(b)}'")
        end
      end

      private def datetime_epoch(value : JSON::Any) : Int64?
        return nil unless value.raw.is_a?(Hash)
        value[FilterEngine::DATETIME_TAG]?.try(&.as_i64?)
      end

      # Python's real timedelta normalizes days/seconds/microseconds from
      # a raw second count; only `days` and `seconds` are modeled here (no
      # caller needs microseconds), and only for a non-negative delta -
      # every real use of this codebase's own `-` support subtracts an
      # earlier date from a later one.
      private def timedelta(diff_seconds : Int64) : JSON::Any
        JSON::Any.new({
          FilterEngine::TIMEDELTA_TAG => JSON::Any.new(true),
          "days"                      => JSON::Any.new(diff_seconds // 86400),
          "seconds"                   => JSON::Any.new(diff_seconds % 86400),
        })
      end

      # Finds the matching close paren for a leading "(" and splits
      # *expr* into {inner_without_parens, trailing_suffix} - nil if
      # *expr* doesn't start with "(" at all, or the leading "(" never
      # closes (malformed).
      private def split_leading_paren(expr : String) : {String, String}?
        return nil unless expr.starts_with?('(')

        depth = 0
        quote : Char? = nil

        expr.each_char.with_index do |char, i|
          if q = quote
            quote = nil if char == q
          elsif char == '\'' || char == '"'
            quote = char
          elsif char == '('
            depth += 1
          elsif char == ')'
            depth -= 1
            return {expr[1...i], expr[(i + 1)..]} if depth == 0
          end
        end

        nil
      end

      # Evaluate expression with a (possibly chained) filter pipeline.
      # Example: myvar | default('value'), or items | sort | join(',')
      #
      # Splits on *every* top-level `|` (not just the first), and resolves
      # the head expression to a real JSON::Any (an array/hash, not a
      # pre-stringified String) so FilterEngine can carry actual structure
      # from one filter to the next - `sort`'s real array output feeding
      # into `join`, not a JSON-encoded string `sort` had no choice but to
      # return before.
      private def evaluate_with_filter(expr : String) : String
        # Crinja-first delegation, filter-chain construct: `|`-filter chains -
        # try Crinja first via the raw-value path, same pattern as the
        # rest of #evaluate_expr's now-converged constructs. Safe because
        # of (a) a filter-coverage audit that already established every
        # `FilterEngine` filter/test has a
        # Crinja/`jinja_filters.cr` equivalent bar `to_datetime`, and
        # (b) extensive empirical probing across real chain shapes used
        # throughout this codebase's own history (`combine`, `selectattr`
        # + `list` + `first`, nested `(...)` heads, `default()`,
        # `to_json`, `regex_replace`/`regex_search`, `hash`/
        # `password_hash`, register-result tests like `is changed`,
        # recursive re-templating via a `{{`/`{%`-containing head value) -
        # all matched exactly. `lookup(...)`-headed chains correctly fall
        # back (Crinja has no `lookup()` equivalent, so it raises
        # cleanly rather than silently misrendering); a `to_datetime`
        # head falls back the same way. Also found (not a regression -
        # Crinja is MORE correct here): the hand-rolled `FilterEngine`
        # has no `round` filter at all (silently passes the value through
        # unchanged rather than rounding) - a real, pre-existing gap this
        # convergence fixes for free on the Crinja-success path, and
        # leaves exactly as broken as before on the (should-be-rare)
        # fallback path.
        value = render_via_jinja_value(expr)
        value ? @lookup.format_value(value) : "undefined"
      rescue ex : KrikriJinja::TemplateError
        # A filter's OWN runtime TypeError (Python's len(None) ->
        # "object of type ... has no length") is the CORRECT semantic
        # failure, not a Crinja capability gap - falling back to the
        # hand-rolled chain there re-resolves the head leniently (a
        # first_found errors='ignore' no-match renders as "") and
        # silently answers 0, skipping a task real ansible fails
        # (lotusnoir.apps_consul_exporter round 5210000). Only that
        # TypeError class re-raises here (wrapped in Ansible's filter-
        # plugin wording, NoneType spelled Python's way); every other
        # engine failure keeps the existing hand-rolled fallback.
        if ex.message.try(&.includes?("has no length"))
          # Python's own TypeError text for len() on a non-sized value:
          # "object of type 'NoneType' has no len()" - the engine words
          # it "object of type Nil has no length" with its own "line N:"
          # prefix, neither of which Ansible ever prints.
          cause = ex.message.not_nil!
            .sub(/\Aline \d+: /, "")
            .sub("object of type Nil", "object of type 'NoneType'")
            .sub("object of type Float64", "object of type 'float'")
            .sub("object of type Int64", "object of type 'int'")
            .sub(" has no length", " has no len()")
          raise Krikri::FilterPluginError.new(
            "The filter plugin 'ansible.builtin.length' failed: #{cause}", cause)
        end
        evaluate_with_filter_fallback(expr)
      rescue
        evaluate_with_filter_fallback(expr)
      end

      private def evaluate_with_filter_fallback(expr : String) : String
        segments = FilterEngine.split_chain(expr)
        var_expr = segments[0]

        value = filter_chain_head_value(var_expr)

        root = VarSubstitutor.expression_root(var_expr)
        result = segments[1..].reduce(value) { |acc, filter_expr| @filter.apply(acc, filter_expr, root) }
        @lookup.format_value(result)
      end

      # Resolves a filter chain's head expression to a real JSON::Any
      # (an array/hash, not a pre-stringified String) so FilterEngine can
      # carry actual structure from one filter to the next - `sort`'s
      # real array output feeding into `join`, not a JSON-encoded string
      # `sort` had no choice but to return before. Split out of
      # #evaluate_with_filter_fallback purely to keep that method's own
      # branch count under ameba's cyclomatic-complexity threshold.
      private def filter_chain_head_value(var_expr : String) : JSON::Any
        filter_chain_special_head(var_expr) || filter_chain_literal_head(var_expr) ||
          filter_chain_var_head(var_expr)
      end

      # The non-plain-variable head shapes: a parenthesized
      # sub-expression, a `range(...)`/`lookup(...)` call, a quoted
      # string or numeric literal, or any `[`-bearing expression
      # (slicing/indexing). nil when none match - the caller falls back
      # to a plain variable lookup.
      private def filter_chain_special_head(var_expr : String) : JSON::Any?
        filter_chain_paren_head(var_expr) || filter_chain_range_head(var_expr) ||
          filter_chain_lookup_head(var_expr)
      end

      # A parenthesized sub-expression as the chain's head -
      # dev-sec os_hardening's sysctl merge nests filter chains
      # this way: `((sysctl_config | combine(...)) |
      # combine(...)) | combine(...)`. Recursing (stripping the
      # outer pair) resolves each layer instead of treating the
      # whole parenthesized text as a literal variable name -
      # which always failed the lookup and silently collapsed
      # the entire with_dict: source to nothing.
      private def filter_chain_paren_head(var_expr : String) : JSON::Any?
        return nil unless var_expr.starts_with?('(') && var_expr.ends_with?(')')

        rendered = evaluate(var_expr[1..-2].strip)
        (JSON.parse(rendered) rescue JSON::Any.new(rendered))
      end

      # `range(1, 11) | list` / `range(1, 11) | ...` - same
      # function-call syntax as the no-filter case in
      # evaluate_expr, just reached via a different path since
      # top_level_pipe? routes anything with a `|` here first.
      private def filter_chain_range_head(var_expr : String) : JSON::Any?
        return nil unless var_expr.starts_with?("range(") && var_expr.ends_with?(')')

        evaluate_range(var_expr[6..-2])
      end

      # `lookup('env', 'VAULT_VERSION') | default('2.0.3',
      # true)` - same function-call syntax as evaluate_expr's
      # own bare (no-filter) `lookup(` case, just reached via
      # a different path since top_level_pipe? routes
      # anything with a `|` here first. split_chain already
      # isolated var_expr to exactly this call (depth-aware,
      # so the filter chain's own trailing `)` from
      # default(...) was never part of it) - the actual bug
      # this sits alongside was evaluate_expr's own top-level
      # `starts_with("lookup(") && ends_with(')')` check
      # wrongly matching the *whole* "lookup(...) |
      # default(...)" text (any trailing filter call ending
      # in its own `)` satisfies ends_with(')') too),
      # swallowing the entire expression into evaluate_lookup
      # with a garbled, unbalanced argument string before
      # top_level_pipe? ever got a chance to run - fixed via
      # #bare_call?, which confirms the matching close paren
      # for `lookup(`'s own open paren is the expression's
      # actual last character, not just checking whether the
      # tail of the string happens to be some `)`.
      #
      # A bare trailing method call chained directly onto the
      # lookup with no `|` in between (`lookup("file", "{{ a }}/
      # {{ b }}").splitlines() | select(...) | list`, bodsch.
      # tomcat round 199) also satisfies ends_with(')') - its own
      # closing paren, not lookup(...)'s - so var_expr[7..-2]
      # sliced a garbled, unbalanced argument string ("...".
      # splitlines(" minus its last char). Locate lookup(...)'s
      # OWN matching close paren depth-aware instead of assuming
      # it is the expression's last character, then dispatch
      # anything after it (".splitlines()") as a method-call
      # suffix on the lookup's result via VariableLookup, the
      # same dispatcher a plain variable's own dotted method
      # chain already goes through (variable_lookup.cr's
      # `string_method_call`/`apply_method_suffix`).
      private def filter_chain_lookup_head(var_expr : String) : JSON::Any?
        return nil unless var_expr.starts_with?("lookup(") && var_expr.ends_with?(')')
        return nil unless close_idx = matching_close_paren_index(var_expr, 6)

        lookup_rendered = evaluate_lookup(var_expr[7...close_idx])
        result = (JSON.parse(lookup_rendered) rescue JSON::Any.new(lookup_rendered))
        suffix = var_expr[(close_idx + 1)..]
        result = @lookup.apply_method_suffix(result, suffix) || result unless suffix.empty?
        result
      end

      # Literal / bracket-bearing heads (`'foo' | upper`, `5.7 | int`,
      # `list[0:2] | ...`) - split out of #filter_chain_special_head
      # purely to keep that method's own branch count under ameba's
      # cyclomatic-complexity threshold.
      private def filter_chain_literal_head(var_expr : String) : JSON::Any?
        if literal = quoted_string_literal(var_expr)
          # A quoted string literal as the chain's head
          # (`{{ 'foo' | upper }}`, `{{ mysql_log_error | dirname
          # }}`'s own sibling pattern with a literal instead of a
          # variable) - previously fell to the plain-lookup else
          # branch below, treating the literal text (quotes
          # included) as a variable NAME to resolve, always
          # undefined.
          return literal
        end
        if literal = numeric_literal(var_expr)
          # A bare numeric literal as the chain's head (`{{ 5.7 |
          # int }}`, `{{ 256.0 | int }}`) - same gap as the
          # quoted-string-literal case just above, one level
          # deeper: found via geerlingguy.swap's own check-
          # size.yml (`(stat.size / 1024 / 1024) | int` - the
          # parenthesized form recurses through #evaluate_expr's
          # own now-fixed bare-numeric-literal check, but a
          # *literal* head with no parens at all, as in this
          # simplified repro, never reached any numeric check
          # here and fell to the plain-lookup else branch,
          # always undefined).
          return literal
        end
        if var_expr.includes?("[")
          # Array slicing (`list[0:2]`) and plain indexing
          # (`list[0]`) aren't resolved to JSON::Any directly here
          # (ArraySlicer/VariableLookup#indexed both still only
          # return pre-formatted Strings) - fall back to the
          # existing String-returning path and re-parse it, rather
          # than duplicating that logic. "undefined" isn't valid
          # JSON, so it maps to a real JSON null.
          rendered = evaluate(var_expr)
          return (JSON.parse(rendered) rescue JSON::Any.new(rendered))
        end

        nil
      end

      private def filter_chain_var_head(var_expr : String) : JSON::Any
        resolved = @lookup.resolve(var_expr)

        # Ansible's recursive re-templating: a variable
        # whose own raw value is itself unrendered Jinja (a
        # role default defined in terms of another default,
        # e.g. ansible-community.ansible-vault's own
        # `vault_tls_gossip: "{{ lookup('env',
        # 'VAULT_TLS_GOSSIP') | default(false, true) }}"`) must
        # be rendered before a filter chain sees it - otherwise
        # `vault_tls_gossip | bool` saw the raw, non-empty
        # template text itself (truthy) rather than the real
        # (false) rendered value. Same class of bug as
        # ConditionalEvaluator's identical fix for a bare `when:
        # vault_tls_gossip` condition - this is the filter-chain
        # counterpart, since `{{ vault_tls_gossip }}` alone (no
        # filter) already got a re-render pass elsewhere but a
        # filter chain's own head resolution here didn't.
        if value = retemplated_lookup_value(resolved, var_expr)
          return value
        end

        resolved || JSON::Any.new(nil)
      end
    end
  end
end
