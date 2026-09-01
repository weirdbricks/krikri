require "json"
require "http/client"
require "uri"
require "../conditional_evaluator"
require "./comparison_evaluator"
require "./filter_engine"
require "./array_slicer"
require "./variable_lookup"
require "./crinja_renderer"
require "../variable_substitutor"

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
      @crinja_renderer : VariableSubstitutor::CrinjaRenderer?

      def initialize(@vars : Hash(String, JSON::Any))
        @comparison = ComparisonEvaluator.new(@vars)
        @filter = FilterEngine.new(@vars)
        @slicer = ArraySlicer.new(@vars)
        @lookup = VariableLookup.new(@vars)
      end

      # Built lazily - most `{{ }}` spans never reach the boolean_logic?
      # branch below, so most `ExpressionEvaluator`s never need this.
      private def crinja_renderer : VariableSubstitutor::CrinjaRenderer
        @crinja_renderer ||= VariableSubstitutor::CrinjaRenderer.new(@vars)
      end

      # Guards the Crinja-first delegation branches below against
      # genuine infinite recursion: `CrinjaRenderer#prepare_crinja_vars`
      # re-templates any variable whose OWN value still contains `{{` by
      # building a fresh `VarSubstitutor`/`ExpressionEvaluator` and
      # calling back into `#evaluate` - if THAT evaluation also delegates
      # to Crinja (any of the branches below), it builds ANOTHER fresh
      # `CrinjaRenderer`, which calls `prepare_crinja_vars` again on the
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

      private def render_via_crinja(expr : String) : String
        raise "crinja delegation depth exceeded" if @@crinja_delegation_depth >= MAX_CRINJA_DELEGATION_DEPTH
        @@crinja_delegation_depth += 1
        begin
          crinja_renderer.render!("{{ #{expr} }}")
        ensure
          @@crinja_delegation_depth -= 1
        end
      end

      # Same delegation-depth guard as #render_via_crinja, but returns
      # Crinja's RAW structured result (nil for undefined) instead of a
      # pre-stringified String - see `CrinjaRenderer#evaluate_value!`'s
      # own comment for the full "why" (this codebase's internal
      # render-then-`JSON.parse`-back round trip breaks if a container-
      # valued Crinja result is stringified via Crinja's own Python-repr
      # `Finalizer` instead of this codebase's JSON-compact
      # `VariableLookup#format_value`). Any construct whose result might
      # be an Array/Hash (not just a scalar) must go through this, not
      # #render_via_crinja directly - constructs 1-6 (boolean/and/or/is,
      # ternary, comparisons, bare literals, `~`, `*`/`/`/`//`) don't
      # need it, since every one of them is provably scalar-only
      # (verified via extensive empirical probing during their own
      # convergence - none produce a container result).
      private def render_via_crinja_value(expr : String) : JSON::Any?
        raise "crinja delegation depth exceeded" if @@crinja_delegation_depth >= MAX_CRINJA_DELEGATION_DEPTH
        @@crinja_delegation_depth += 1
        begin
          crinja_renderer.evaluate_value!(expr)
        ensure
          @@crinja_delegation_depth -= 1
        end
      end

      # #render_via_crinja_value, formatted through this codebase's own
      # `VariableLookup#format_value` (not Crinja's `Finalizer`) - the
      # convenience form for a call site that ultimately wants a String
      # (matching #render_via_crinja's signature) without losing the
      # format-consistency fix that method exists for.
      private def render_via_crinja_string(expr : String) : String
        value = render_via_crinja_value(expr)
        value ? @lookup.format_value(value) : "undefined"
      end

      # #evaluate, but formatting a CONTAINER result the way real Ansible
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
      # boundary, which is the round trip CrinjaRenderer#evaluate_value!
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
        rendered
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
      private def structured_container(expr : String) : JSON::Any?
        value =
          if expr.matches?(REGEX_PLAIN_REFERENCE)
            @lookup.resolve(expr)
          elsif expr.includes?("lookup(") || expr.includes?("query(") || expr.includes?("pipe")
            nil
          else
            render_via_crinja_value(expr)
          end

        return nil unless value
        raw = value.raw
        (raw.is_a?(Array) || raw.is_a?(Hash)) ? value : nil
      rescue
        nil
      end

      # Evaluate any expression and return string result. A thin guard in
      # front of #evaluate_expr for the inline ternary `TRUTHY if COND else
      # FALSY` (real Jinja2/Ansible syntax, used directly in default vars
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
      REGEX_PLAIN_REFERENCE = /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*|\[(?:-?\d+|'[^']*'|"[^"]*")\])*\z/

      def evaluate(expr : String) : String
        if ternary = split_ternary(expr)
          # Crinja-first delegation, ternary construct (after boolean_logic?
          # below): real Jinja2's inline ternary is right-associative
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
          # since they're bound in `CrinjaRenderer`'s own shared vars
          # context, not specific to that branch.
          begin
            render_via_crinja(expr)
          rescue
            evaluate_ternary(ternary)
          end
        elsif ternary_no_else = split_ternary_no_else(expr)
          begin
            render_via_crinja(expr)
          rescue
            evaluate_ternary_no_else(ternary_no_else)
          end
        elsif boolean_logic?(expr)
          # A full boolean expression (`X is failed or Y != Z`, `A and
          # B`) as a `{{ }}` span's entire content, most commonly a
          # set_fact: value - real Ansible/Jinja2 evaluates `or`/`and`/
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
          # BUT: real Jinja2's `or`/`and` are value-selectors, not pure
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
          # which raises instead of Crinja::CrinjaRenderer#render's own
          # "give back the original text" failure mode - actively wrong
          # here, since a caller of #evaluate always wants a real
          # value); falls back to the ORIGINAL hand-rolled path on ANY
          # failure, so a construct Crinja doesn't yet support degrades
          # to exactly today's behavior rather than a regression.
          # `is failed`/`changed`/`skipped`/`succeeded`/`success` (real
          # Ansible register-result tests) and the `omit` magic variable
          # both needed porting to Crinja's own registry/context first
          # (see jinja_filters.cr's `result_field` tests and
          # CrinjaRenderer#prepare_crinja_vars's own `omit` binding) -
          # without those this swap would have silently regressed both.
          begin
            render_via_crinja(expr)
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
      # and did NOT implement: whether `render_via_crinja(expr)` itself
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
      # `render_via_crinja`/the hand-rolled fallback are still invoked
      # completely fresh on every real call, exactly as before - only
      # the shape CLASSIFICATION is reused, never the outcome of trying
      # to render it.
      #
      # Differential-tested, not just spec-tested: ran all 3080 real
      # "output"-kind `{{ }}` expressions scraped from `testing/roles` +
      # 21 benchmarked Galaxy roles (`scripts/crinja_corpus/corpus.
      # jsonl`) through `ExpressionEvaluator#evaluate` before and after
      # this change - byte-identical output (or identical raised
      # exception class) for all 3080, confirming the memoization is
      # invisible to real-world dispatch behavior, not just this
      # project's own spec suite.
      @@split_ternary_cache = Hash(String, {String, String, String}?).new
      @@split_ternary_no_else_cache = Hash(String, {String, String}?).new
      @@boolean_logic_cache = Hash(String, Bool).new

      private def boolean_logic?(expr : String) : Bool
        return @@boolean_logic_cache[expr] if @@boolean_logic_cache.has_key?(expr)

        result = !top_level_keyword_index(expr, " or ").nil? ||
                 !top_level_keyword_index(expr, " and ").nil? ||
                 !top_level_keyword_index(expr, " is ").nil?
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
      # (real Ansible's own way to conditionally drop a module param
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
        # opposed to a quoted string one - real Ansible/Jinja2 accepts
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
        # render_via_crinja/rescue pattern as constructs 1-3. Found a
        # latent inconsistency doing this: the old unconditional
        # `expr.downcase` returned lowercase "true"/"false" here, at odds
        # with every other boolean-producing path in this codebase
        # (ConditionalEvaluator, ComparisonEvaluator's own construct-3
        # convergence, VariableLookup) which all produce capitalized
        # "True"/"False" (real Python/Jinja2 `str(bool)` convention) -
        # this branch was simply never reached with Crinja unavailable
        # for a bare literal, since Crinja renders `{{ true }}`/
        # `{{ false }}` as "True"/"False" like real Ansible does, so the
        # divergence never showed up in practice. Kept as the fallback
        # (unchanged) for the case Crinja itself is ever unavailable.
        if expr == "true" || expr == "false" || expr == "True" || expr == "False"
          return begin
            render_via_crinja(expr)
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
            render_via_crinja(expr)
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
            render_via_crinja(expr)
          rescue
            literal
          end
        end

        nil
      end

      private def evaluate_expr_bare_call(expr : String) : String?
        # `lookup('first_found', ffparams)` - real Ansible's lookup()
        # function call syntax (distinct from a `|` filter chain), used
        # pervasively across linux-system-roles to pick an OS-version-
        # specific vars file: `include_vars: "{{ lookup('first_found',
        # ffparams) }}"` where ffparams is `{files: [...], paths: [...]}`.
        # Checked first (function-call syntax, not an operator) since
        # nothing else in this dispatch chain understands `name(args)` at
        # all - it fell through everywhere else to a plain variable
        # lookup on the literal text "lookup('first_found', ffparams)",
        # always undefined.
        if bare_call?(expr, "lookup(")
          return evaluate_lookup(expr[7..-2])
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
        if expr.starts_with?("lookup(") && !top_level_pipe?(expr)
          if close_idx = matching_close_paren_index(expr, 6)
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
            if suffix.lstrip.starts_with?('.')
              lookup_rendered = evaluate_lookup(expr[7...close_idx])
              result = (JSON.parse(lookup_rendered) rescue JSON::Any.new(lookup_rendered))
              result = @lookup.apply_method_suffix(result, suffix) || result
              return result.raw.is_a?(String) ? result.as_s : result.to_json
            end
          end
        end

        # `query('first_found', params)` - real Ansible's OTHER lookup-
        # invocation syntax; unlike `lookup(...)` (which comma-joins a
        # multi-result lookup into a scalar string unless `wantlist=True`
        # is passed explicitly), `query(...)` is real Ansible's own
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
        # (round 165): real ansible-playbook resolved the loop to the
        # real candidate (`ubuntu-22.04.yml`) and continued; crystal
        # failed at the very first real task.
        if bare_call?(expr, "query(")
          return evaluate_query(expr[6..-2])
        end

        # `range(...)` - real Jinja2/Python's function-call range syntax,
        # commonly used as a `loop:` source (`loop: "{{ range(1, 11) |
        # list }}"`) rather than the engine's own `with_sequence:`
        # keyword. Checked here (bare, no filter chain) for the no-filter
        # case; the filter-chain case (`range(...) | list`) is handled in
        # evaluate_with_filter's own base-value resolution, since a bare
        # `range(` prefix check there would otherwise never be reached -
        # top_level_pipe? routes any expression with a `|` straight past
        # this method into evaluate_with_filter before this line runs.
        if bare_call?(expr, "range(")
          # Crinja-first delegation, general filter-chain-dispatch
          # construct (continued): unlike `dict()` just below,
          # `range()`'s raw-value output matches
          # the hand-rolled path exactly (probed across positive/
          # negative step, variable arguments) - safe via the same
          # #render_via_crinja_value pattern as the literal array/dict
          # cases above.
          return begin
            value = render_via_crinja_value(expr)
            value ? @lookup.format_value(value) : "undefined"
          rescue
            @lookup.format_value(evaluate_range(expr[6..-2]))
          end
        end

        # `dict(iterable)` - real Ansible's Templar exposes actual
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
        if bare_call?(expr, "dict(")
          # Dual-evaluator convergence: converged 2026-08-14 (0.9.340). The blocker
          # documented below (Crinja's own `dict()` reading only kwargs
          # and silently producing an EMPTY dict for a positional arg)
          # is fixed fork-side (`weirdbricks/crinja` `crystal-play-0.9.4`,
          # `src/lib/function/dict.cr`): the single positional-iterable
          # form (mapping, or list/tuple of 2-element pairs) now builds a
          # real dict and raises a clean `Arguments::Error` for anything
          # else - the same `render_via_crinja_value`/rescue pattern as
          # `range()` above, `evaluate_dict_call` unchanged as the
          # fallback.
          return begin
            value = render_via_crinja_value(expr)
            value ? @lookup.format_value(value) : "undefined"
          rescue
            @lookup.format_value(evaluate_dict_call(expr[5..-2]))
          end
        end

        nil
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
          return begin
            render_via_crinja(expr)
          rescue
            @comparison.evaluate(expr)
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
        if minus = split_top_level_minus(expr)
          left_expr, right_expr = minus
          return evaluate_minus(left_expr, right_expr)
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
          return evaluate_plus(segments)
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
        # matching real Jinja2's normal precedence - `*`/`/` bind
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
            render_via_crinja(expr)
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
          return begin
            value = render_via_crinja_value(expr)
            value ? @lookup.format_value(value) : "undefined"
          rescue
            evaluate_leading_paren(paren)
          end
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
          value = render_via_crinja_value(expr)
          value ? @lookup.format_value(value) : "undefined"
        rescue
          @lookup.simple(expr)
        end
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
        value = render_via_crinja_value(expr)
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
        # on a quiet `nil`. Real Ansible resolves the var fully (via
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
          # Crinja first via the raw-value path (#render_via_crinja_
          # value), which preserves this codebase's own JSON-compact
          # `format_value` output instead of Crinja's Python-repr
          # `Finalizer` style - see that method's own comment for why
          # the plain String-returning #render_via_crinja can't be used
          # here (it would break the render-then-reparse round trip
          # other call sites depend on). Falls back to the original
          # hand-rolled `parse_literal_array` on any failure.
          return begin
            value = render_via_crinja_value(expr)
            value ? @lookup.format_value(value) : "undefined"
          rescue
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
            value = render_via_crinja_value(expr)
            value ? @lookup.format_value(value) : "undefined"
          rescue
            @slicer.slice(expr)
          end
        end

        # Crinja-first delegation, general filter-chain-dispatch
        # construct (general indexed access: `var[key]`, `var[0]`, `var[-1]`) - same
        # pattern as the dotted-access/simple-lookup cases above.
        begin
          value = render_via_crinja_value(expr)
          value ? @lookup.format_value(value) : "undefined"
        rescue
          @lookup.indexed(expr)
        end
      end

      # Returns nil (not a String) when *expr* is neither a dict literal
      # nor `[`-bearing at all, so evaluate_expr's caller knows to fall
      # through to the plain `.`/simple-lookup checks instead.
      private def evaluate_bracket_or_dict_expr(expr : String) : String?
        if literal_dict_expr?(expr)
          # Same rationale and pattern as the literal-array case above.
          return begin
            value = render_via_crinja_value(expr)
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

        @@split_ternary_cache[expr] = result
        result
      end

      # Splits *expr* on a top-level ` if ` with NO ` else ` clause at all
      # - real Jinja2's else-less inline-if (`TRUTHY if COND`), which
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

      private def split_top_level_plus_step(state : PlusSplitState, char : Char)
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

      private def split_top_level_plus_delimiter(state : PlusSplitState, char : Char)
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
          split_mult_div_operator(state, chars, i, char)
        else
          state.current << char
        end
        i + 1
      end

      private def split_mult_div_delimiter(state : MultDivSplitState, char : Char)
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

        render_via_crinja(expr)
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
        return JSON::Any.new(nil) unless af && bf

        both_int = a.raw.is_a?(Int64) && b.raw.is_a?(Int64)

        case op
        when "*"
          both_int ? JSON::Any.new((af * bf).to_i64) : JSON::Any.new(af * bf)
        when "/"
          JSON::Any.new(af / bf)
        when "//"
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
          bf.zero? ? JSON::Any.new(nil) : JSON::Any.new((af / bf).floor.to_i64)
        else
          JSON::Any.new(nil)
        end
      end

      private def numeric_operand(value : JSON::Any) : Float64?
        case raw = value.raw
        when Int64
          raw.to_f64
        when Float64
          raw
        else
          nil
        end
      end

      # Resolves and concatenates/adds every operand of a top-level `+`
      # expression, left to right - array+array concatenates, string+string
      # concatenates, number+number adds; anything else falls back to
      # string concatenation of both sides' rendered form rather than
      # erroring.
      private def evaluate_plus(segments : Array(String)) : String
        values = segments.map { |seg| resolve_plus_operand(seg) }
        result = values.reduce { |acc, val| combine_plus(acc, val) }
        @lookup.format_value(result)
      end

      private def resolve_plus_operand(expr : String) : JSON::Any
        expr = expr.strip
        expr = expr.strip
        value = resolve_plus_operand_literal(expr)
        return value if value
        value = resolve_plus_operand_mult_div(expr)
        return value if value
        value = resolve_plus_operand_recursive(expr)
        return value if value

        resolved = @lookup.resolve(expr)

        # Real Ansible's recursive re-templating - the fifth (and, so
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
        if value = retemplated_lookup_value(resolved)
          return value
        end

        resolved || JSON::Any.new(nil)
      end

      private def resolve_plus_operand_literal(expr : String) : JSON::Any?
        if literal = quoted_string_literal(expr) || numeric_literal(expr)
          return literal
        end

        return parse_literal_array(expr) if expr.starts_with?('[') && expr.ends_with?(']')

        nil
      end

      private def resolve_plus_operand_mult_div(expr : String) : JSON::Any?
        # A `*`/`/`/`//` sub-expression nested inside a `+`/`-` operand
        # (`2 + 3 * 4`'s own right-hand `+`-segment) - checked here so
        # `*`/`/` bind tighter than the `+`/`-` that already split this
        # segment out, matching real Jinja2 precedence.
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

      # Re-renders a plain-lookup result whose own raw value is still
      # unrendered Jinja template text (`{%`/`{#` block tags need the
      # full Crinja renderer; a `{{ }}`-span re-enters this evaluator) -
      # nil when the value isn't template text at all.
      private def retemplated_lookup_value(resolved : JSON::Any?) : JSON::Any?
        return nil unless resolved && (raw = resolved.raw).is_a?(String)
        if raw.includes?("{%") || raw.includes?("{#")
          # Block tags need the full Crinja renderer, not this plain
          # `{{ }}`-only evaluator - see variable_lookup.cr's identical
          # fix for the full rationale (found via prometheus.prometheus's
          # own _common role's `_common_dependencies` default).
          rendered = CrinjaRenderer.new(@vars).render(raw)
          return (JSON.parse(rendered) rescue JSON::Any.new(rendered))
        end

        return nil unless raw.includes?("{{")
        inner = raw.strip
        inner = inner[2..-3].strip if inner.starts_with?("{{") && inner.ends_with?("}}")
        rendered = evaluate(inner)
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

      # `lookup('first_found', params)` - only the "first_found" lookup
      # type is supported (the one linux-system-roles actually uses, for
      # OS-version-specific vars files); any other lookup type resolves
      # to "undefined" rather than raising, matching how every other
      # unsupported construct in this evaluator degrades.

      # Defaults matching ansible-core 2.19's own constants when no
      # ansible.cfg / env override is set. Only the options real roles
      # actually look up (buluma.multi's COLOR_* / DEFAULT_* / RETRY_*)
      # are covered; anything else returns "" rather than inventing a value.
      private def ansible_config_value(name : String) : String
        name_up = name.upcase
        ansible_color_config_value(name_up) || ansible_default_config_value(name_up) ||
          # Honour a matching ANSIBLE_<NAME> env var when present (real
          # Ansible's own resolution order: env > cfg > default).
          ENV["ANSIBLE_#{name_up}"]? || ""
      end

      private def ansible_color_config_value(name_up : String) : String?
        case name_up
        when "COLOR_OK"                    then "green"
        when "COLOR_CHANGED"               then "yellow"
        when "COLOR_SKIP"                  then "cyan"
        when "COLOR_UNREACHABLE"           then "bright red"
        when "COLOR_ERROR", "COLOR_FAILED" then "red"
        when "COLOR_DEBUG"                 then "dark gray"
        when "COLOR_VERBOSE"               then "blue"
        when "COLOR_WARN"                  then "bright purple"
        end
      end

      private def ansible_default_config_value(name_up : String) : String?
        case name_up
        when "DEFAULT_BECOME_USER" then "root"
        when "DEFAULT_ROLES_PATH"  then "~/.ansible/roles:/usr/share/ansible/roles:/etc/ansible/roles"
        when "DEFAULT_HOST_LIST"   then "/etc/ansible/hosts"
        when "RETRY_FILES_SAVE_PATH"
          ""
        when "DEFAULT_TIMEOUT" then "10"
        when "DEFAULT_FORKS"   then "5"
        end
      end

      # A `lookup(...)`/`query(...)` argument that is itself a quoted
      # string literal CONTAINING a `{{ }}` span (`lookup('file', "{{
      # tomcat_local_tmp_directory }}/apache-tomcat-{{ tomcat_version
      # }}.tar.gz.sha512")`) needs that inner span rendered before the
      # lookup runs - real Ansible supports this "double templating"
      # (with a deprecation warning telling authors to switch to an
      # inline expression instead) rather than passing the literal
      # unrendered text to the lookup plugin. Every `evaluate_lookup_*`
      # helper below resolves its path/name/etc. argument via
      # `evaluate(part.strip)`, which for a bare quoted literal
      # (`sole_quoted_literal?`) returns the quotes stripped verbatim -
      # correct for an ordinary string, but wrong here, since the `{{ }}`
      # markers inside are never Jinja-syntax at the *expression* level
      # (only at the *template* level), so nothing else in this
      # evaluator would ever notice or render them.
      #
      # Found via bodsch.tomcat's own `tomcat_checksums: '{{ lookup(
      # "file", "{{ tomcat_local_tmp_directory }}/apache-tomcat-{{
      # tomcat_version }}.tar.gz.sha512").splitlines() | ... }}'` - real
      # ansible-core 2.19.4 downloads and reads the real checksum file;
      # this evaluator's `lookup_file` received the literal path text
      # WITH the unrendered `{{ }}` still in it, failed to find that
      # file, and its own "undefined" fallback then got templated
      # straight into a real `get_url:` checksum comparison ("checksum
      # mismatch: expected undefined, got <real sha512>").
      #
      # Applied once, at the `evaluate_lookup` entry point, rather than
      # in each individual `lookup_file`/`lookup_url`/`lookup_config`/...
      # helper - every lookup type shares the same "an argument may
      # itself carry an unrendered `{{ }}` span" possibility, so fixing
      # it here covers all of them uniformly instead of one at a time.
      private def rerender_double_templated_literal(part : String) : String
        stripped = part.strip
        return part unless literal = sole_quoted_literal?(stripped)
        return part unless literal.includes?("{{") && literal.includes?("}}")

        quote = stripped[0]
        rendered = crinja_renderer.render!(literal)
        "#{quote}#{rendered}#{quote}"
      rescue
        part
      end

      private def evaluate_lookup(args : String) : String
        parts = split_top_level_commas(args).map { |part| rerender_double_templated_literal(part) }
        lookup_type = parts[0]?.try { |part| quoted_string_literal(part.strip) }.try(&.as_s?)

        # Real Ansible accepts a lookup plugin's name either bare
        # ('first_found') or fully-qualified ('ansible.builtin.
        # first_found') - every `when "..."` case below only matches the
        # bare form. Without this, `lookup('ansible.builtin.first_found',
        # params)` (juju4.*'s own idiom across many of its roles) fell
        # through every case to the final "undefined" fallback, breaking
        # `include_vars: "{{ lookup('ansible.builtin.first_found',
        # params) }}"` outright regardless of whether any candidate file
        # actually existed.
        lookup_type = lookup_type.try(&.sub(/^ansible\.(builtin|legacy)\./, ""))

        evaluate_lookup_scalar(lookup_type, parts) ||
          evaluate_lookup_file(lookup_type, parts) ||
          evaluate_lookup_list(lookup_type, parts) ||
          evaluate_lookup_misc(lookup_type, parts) ||
          evaluate_lookup_file_parsers(lookup_type, parts) ||
          "undefined"
      end

      private def evaluate_lookup_scalar(lookup_type : String?, parts : Array(String)) : String?
        case lookup_type
        when "first_found"
          params = parts[1]?.try { |part| resolve_plus_operand(part.strip) }
          return "undefined" unless params
          evaluate_first_found(params)
        when "env"
          # lookup('env', 'VAR_NAME') - real Ansible's own env lookup
          # plugin, reads an environment variable from the CONTROLLER
          # (not the target - this always runs on the controller side,
          # same as first_found above). Entirely unimplemented before -
          # fell through to the `unless lookup_type == "first_found"`
          # guard, always "undefined" regardless of the real env var.
          # Found via ansible-community.ansible-vault's own `vault_
          # version: "{{ lookup('env', 'VAULT_VERSION') | default(
          # '2.0.3', true) }}"` - real Ansible's own env lookup returns
          # an empty string for an unset var (not an error), which is
          # what makes the `default(..., true)` fallback actually kick
          # in; "undefined" is a non-empty string, so default() never
          # replaced it, leaving the literal text "undefined" as the
          # real Vault version used to build the download URL.
          var_name = parts[1]?.try { |part| resolve_plus_operand(part.strip) }.try(&.as_s?)
          var_name ? (ENV[var_name]? || "") : "undefined"
        when "config"
          lookup_config(parts)
        when "url"
          lookup_url(parts)
        when "vars"
          # lookup('vars', 'variable_name') - real Ansible's own vars
          # lookup plugin: an INDIRECT variable lookup, the name itself
          # coming from an expression (commonly a computed string, e.g.
          # `lookup('vars', 'nginx_' + ansible_distribution)`) rather
          # than being written as a literal `{{ }}` reference. Entirely
          # unimplemented before, fell through to "undefined".
          var_name = parts[1]?.try { |part| evaluate(part.strip) }
          return "undefined" unless var_name
          resolved = @lookup.resolve(var_name)
          resolved ? @lookup.format_value(resolved) : "undefined"
        end
      end

      private def lookup_config(parts : Array(String)) : String
        # lookup('config', 'OPTION'[, 'OPTION2', ...], wantlist=True) -
        # real Ansible's own config lookup plugin, returns the current
        # value of one or more ansible.cfg / ANSIBLE_* settings from the
        # CONTROLLER. Multi-arg form with wantlist=True returns a real
        # list (buluma.multi's own `loop: "{{ lookup('config', 'COLOR_OK',
        # 'COLOR_CHANGED', 'COLOR_SKIP', wantlist=True) }}"`, round 190 -
        # previously unimplemented, fell through to "undefined", so the
        # loop bound `item` to nothing and the debug failed with
        # `'item' is undefined`). Defaults match ansible-core 2.19's own
        # DEFAULT_*/COLOR_* constants when no ansible.cfg override is set.
        wantlist = parts[1..].any? { |part| part.strip.downcase.starts_with?("wantlist=true") }
        names = parts[1..].reject(&.strip.downcase.starts_with?("wantlist=")).compact_map { |part|
          quoted_string_literal(part.strip).try(&.as_s?) || evaluate(part.strip).presence
        }
        return "undefined" if names.empty?
        values = names.map { |nval| ansible_config_value(nval) }
        if wantlist || names.size > 1
          values.to_json
        else
          values[0]
        end
      end

      private def lookup_url(parts : Array(String)) : String
        # lookup('url', url_expr, wantlist=True) - real Ansible's own
        # url lookup plugin, fetching a URL from the CONTROLLER (same
        # controller-side rule as env/first_found above). Entirely
        # unimplemented before - fell through to "undefined", so
        # cloudalchemy.prometheus's own checksum-pinning idiom
        # (`lookup('url', '.../sha256sums.txt', wantlist=True) |
        # list`, then looping over each line to find the right
        # architecture's checksum) never populated a real checksum -
        # `checksum:` on the subsequent get_url: task compared against
        # the literal string "undefined", always failing. The url_expr
        # itself is commonly a `+`-concatenation of literals and
        # variables (`'https://...v' + prometheus_version + '/...'`),
        # so it's rendered via the full #evaluate (not
        # #resolve_plus_operand, which only understands a single
        # operand) rather than a bare variable/literal lookup.
        url = parts[1]?.try { |part| evaluate(part.strip) }
        return "undefined" unless url

        # Real Ansible's `lookup()` Jinja function only returns a real
        # LIST when the call site explicitly passes `wantlist=True` -
        # otherwise it comma-joins the plugin's own (always-list)
        # result into a single plain STRING. `fetch_url_lines` always
        # returned the JSON-array form unconditionally (right for
        # cloudalchemy.prometheus's own `wantlist=True) | list` idiom,
        # which this was originally added for), so a call with no
        # `wantlist=True` at all - robertdebock.kubectl's own
        # `kubectl_url: ".../release/{{ lookup('url',
        # kubectl_version_url) }}/bin/..."`, fetching a single-line
        # version file - got the literal text `["v1.31.0"]` spliced
        # into the URL instead of the plain string `v1.31.0`, a 404.
        wantlist = parts[2..].any? { |part| part.strip.downcase.starts_with?("wantlist=true") }
        lines_json = fetch_url_lines(url)
        return lines_json if wantlist

        (JSON.parse(lines_json).as_a?.try(&.map(&.as_s).join(",")) rescue nil) || "undefined"
      end

      private def lookup_vars(parts : Array(String)) : String
        # lookup('vars', 'variable_name') - real Ansible's own vars
        # lookup plugin: an INDIRECT variable lookup, the name itself
        # coming from an expression (commonly a computed string, e.g.
        # `lookup('vars', 'nginx_' + ansible_distribution)`) rather
        # than being written as a literal `{{ }}` reference. Entirely
        # unimplemented before, fell through to "undefined".
        var_name = parts[1]?.try { |part| evaluate(part.strip) }
        return "undefined" unless var_name
        resolved = @lookup.resolve(var_name)
        resolved ? @lookup.format_value(resolved) : "undefined"
      end

      private def evaluate_lookup_file(lookup_type : String?, parts : Array(String)) : String?
        case lookup_type
        when "file"
          lookup_file(parts)
        when "pipe"
          lookup_pipe(parts)
        when "template"
          lookup_template(parts)
        when "password"
          # lookup('password', '/path/to/file [length=N chars=abc...]')
          # - real Ansible's own password lookup plugin: generates a
          # random password ONCE and persists it to *path* (on the
          # CONTROLLER) so repeated runs/lookups return the SAME value;
          # any later run finds the file and just reads it back rather
          # than generating a new one. The whole argument is one
          # space-separated string (path first, then key=value options),
          # not comma-separated params like every other lookup type
          # here - matches real Ansible's own free-form parsing for this
          # specific lookup.
          raw_arg = parts[1]?.try { |part| evaluate(part.strip) }
          return "undefined" unless raw_arg
          evaluate_password_lookup(raw_arg)
        when "dict"
          lookup_dict(parts)
        end
      end

      private def lookup_file(parts : Array(String)) : String
        # lookup('file', path) - reads a file's content from the
        # CONTROLLER (same controller-side rule as env/url/first_found
        # above), stripped of a single trailing newline (real
        # Ansible's own file lookup plugin behavior - it splits on
        # newlines and rejoins with the requested separator, default
        # "\n", which drops exactly one trailing blank line same as a
        # plain `.rstrip()` would for the common no-embedded-blank-
        # lines case this covers).
        path = parts[1]?.try { |part| evaluate(part.strip) }
        return "undefined" unless path
        resolved_path = resolve_lookup_path(path)
        begin
          File.read(resolved_path).chomp
        rescue
          # Real Ansible's `file` lookup plugin RAISES when the file
          # can't be read ("Unable to access the file '<path>': File
          # not found"), failing the whole task's arg finalization
          # rather than continuing with a placeholder - unlike a
          # genuinely-undefined VARIABLE reference, which is lenient by
          # design elsewhere in this evaluator. Falling back to the
          # "undefined" sentinel here instead let a missing file's
          # literal text "undefined" get written straight into real
          # task output - found via andrewrothstein.ssh-user-keygen's
          # own `lookup('file', ssh_user_pubkey)` on a host with no
          # `~/.ssh/id_rsa.pub`: real Ansible fails the task, this
          # engine wrote the string "undefined" into `~/.ssh/
          # authorized_keys` as if it were a real public key. Mirrors
          # the url lookup's own HTTP-failure raise just above (same
          # `rescue ex` in the executor turns this into "Finalization
          # of task args ... failed", matching real Ansible's message
          # shape).
          raise "The lookup plugin 'file' failed: Unable to access the file '#{path}': File not found"
        end
      end

      private def lookup_pipe(parts : Array(String)) : String
        # lookup('pipe', command) - runs *command* via the shell ON
        # THE CONTROLLER (not the target - matches real Ansible's own
        # pipe lookup plugin, which always executes locally) and
        # returns its stdout, stripped of a trailing newline.
        command = parts[1]?.try { |part| evaluate(part.strip) }
        return "undefined" unless command
        begin
          output = IO::Memory.new
          status = Process.run("/bin/sh", ["-c", command], output: output, error: Process::Redirect::Close)
          status.success? ? output.to_s.chomp : "undefined"
        rescue
          "undefined"
        end
      end

      private def lookup_template(parts : Array(String)) : String
        # lookup('template', path[, template_vars=dict(...)]) - renders
        # a local (controller-side) `.j2` file through the same Crinja
        # pipeline `template:` tasks use, against this expression's own
        # vars, and returns the rendered text with one trailing newline
        # stripped (matches real Ansible's own template lookup plugin,
        # which is explicitly documented to strip a single trailing
        # newline the way Jinja2's own template rendering leaves one).
        path = parts[1]?.try { |part| evaluate(part.strip) }
        return "undefined" unless path
        resolved_path = resolve_lookup_path(path)

        # template_vars=dict(...) - real Ansible's own template lookup
        # plugin merges this kwarg's dict into the vars available to
        # the rendered template, ON TOP of (never replacing) the
        # calling context's own vars - the whole point of the kwarg is
        # to hand the template a few extra values (bimdata.ferm's own
        # get_vars.j2, rendered 4 times with a different app_name:/
        # var_type: pair each time via this exact kwarg) without
        # requiring a real Ansible variable of that name to exist.
        # Entirely ignored before - the template rendered with
        # `app_name`/`var_type` undefined, so its own `lookup('varnames',
        # '^' ~ app_name ~ ...)` pattern matched nothing regardless of
        # which of the 4 calls it was, silently producing an empty
        # result for all of them instead of each one's own distinct set.
        template_vars_part = parts[2..].find(&.strip.starts_with?("template_vars="))
        render_vars = @vars
        if template_vars_part
          dict_expr = template_vars_part.strip.sub(/^template_vars=/, "")
          extra = render_via_crinja_value(dict_expr).try(&.as_h?)
          if extra && !extra.empty?
            render_vars = @vars.dup
            extra.each { |key, value| render_vars[key] = value }
          end
        end

        begin
          template_content = File.read(resolved_path)
          # A `#jinja2: key:value, ...` directive on the template's very
          # first line (real Ansible's own per-template Jinja2 config
          # override) is metadata for the renderer, not template
          # content - real Ansible strips it before rendering.
          # TemplateActionPlugin already does this for the `template:`
          # module; this lookup plugin never did, so the directive
          # leaked into the returned text as a literal "#jinja2: ..."
          # line - fatal for bimdata.ferm's own `| from_json` pipeline
          # right after this lookup (its own get_vars.j2 opens with
          # `#jinja2: lstrip_blocks: True`), which saw that line
          # prepended to the real JSON and raised "invalid JSON input".
          first_line_end = template_content.index('\n')
          first_line = first_line_end ? template_content[0...first_line_end] : template_content
          if first_line.strip.starts_with?("#jinja2:")
            template_content = first_line_end ? template_content[(first_line_end + 1)..] : ""
          end

          renderer = render_vars.same?(@vars) ? crinja_renderer : CrinjaRenderer.new(render_vars)
          renderer.render(template_content).chomp
        rescue
          "undefined"
        end
      end

      private def lookup_dict(parts : Array(String)) : String
        # lookup('dict', {'a': 1, 'b': 2}) - real Ansible's own dict
        # lookup plugin: one dict term in, a list of {key:, value:}
        # dicts out (one per top-level key) - identical shape to the
        # dict2items filter. Always returns real JSON array text
        # (not real Ansible's own default comma-joined-scalar
        # behavior) - these list-producing lookups are almost always
        # consumed as a loop: source or piped through | list/|
        # flatten, both of which need a real array, not joined text.
        source = parts[1]?.try { |part| evaluate(part.strip) }
        return "undefined" unless source
        dict = (JSON.parse(source) rescue nil).try(&.as_h?)
        return "undefined" unless dict
        dict.map { |k, v| {"key" => JSON::Any.new(k), "value" => v} }.to_json
      end

      private def lookup_lines(parts : Array(String)) : String
        # lookup('lines', command) - real Ansible's own lines lookup:
        # runs *command* on the CONTROLLER (same as pipe above) but
        # returns its output SPLIT into a list of lines, not one
        # joined string.
        command = parts[1]?.try { |part| evaluate(part.strip) }
        return "undefined" unless command
        begin
          output = IO::Memory.new
          status = Process.run("/bin/sh", ["-c", command], output: output, error: Process::Redirect::Close)
          return "undefined" unless status.success?
          output.to_s.split('\n').reject(&.empty?).to_json
        rescue
          "undefined"
        end
      end

      private def evaluate_lookup_list(lookup_type : String?, parts : Array(String)) : String?
        case lookup_type
        when "list"
          # lookup('list', a, b, c) - real Ansible's own list lookup:
          # returns every term given, as a real list (mainly exists so
          # a caller can always treat the result as a list regardless
          # of how many terms were given).
          parts[1..].map { |part| evaluate_lookup_term(part.strip) }.to_json
        when "items"
          # lookup('items', list1, list2, ...) - real Ansible's own
          # items lookup: flattens the given list terms one level
          # (itertools.chain, not a deep flatten).
          parts[1..].flat_map { |part| lookup_array(evaluate_lookup_term(part.strip)) }.to_json
        when "together"
          # lookup('together', list1, list2, ...) - real Ansible's own
          # together lookup: zips the given lists together (itertools.
          # izip_longest, padding shorter lists with null), returning a
          # list of lists - the classic with_together: parallel-
          # iteration source.
          lists = parts[1..].map { |part| lookup_array(evaluate_lookup_term(part.strip)) }
          size = lists.max_of?(&.size) || 0
          (0...size).map { |i| lists.map { |list| list[i]? || JSON::Any.new(nil) } }.to_json
        when "nested"
          # lookup('nested', list1, list2, ...) - real Ansible's own
          # nested lookup: a nested-loop Cartesian product of the given
          # lists (same shape as the `product` filter, but as lookup
          # terms rather than a piped value) - the classic with_nested:
          # source.
          lists = parts[1..].map { |part| lookup_array(evaluate_lookup_term(part.strip)) }
          result = lists.reduce([[] of JSON::Any]) { |acc, list| acc.flat_map { |row| list.map { |item| row + [item] } } }
          result.to_json
        when "lines"
          lookup_lines(parts)
        when "varnames"
          # lookup('varnames', 'regex1', 'regex2', ...) - real Ansible's
          # own varnames lookup: returns every variable NAME (not
          # value) whose name matches ANY of the given regex patterns.
          patterns = parts[1..].compact_map { |part| quoted_string_literal(part.strip).try(&.as_s?) }.compact_map { |pth| Regex.new(pth) rescue nil }
          @vars.keys.select { |name| patterns.any?(&.matches?(name)) }.to_json
        end
      end

      private def evaluate_lookup_misc(lookup_type : String?, parts : Array(String)) : String?
        case lookup_type
        when "sequence"
          # lookup('sequence', 'start=1 end=5 stride=1 format=web%02d')
          # - real Ansible's own sequence lookup: generates a numeric
          # range (the classic with_sequence: source), formatted via
          # format= (Python %-style, Crystal's String#% is the same
          # printf-family syntax) when given.
          raw_arg = parts[1]?.try { |part| evaluate(part.strip) }
          return "undefined" unless raw_arg
          evaluate_sequence_lookup(raw_arg)
        when "indexed_items"
          # lookup('indexed_items', list) - real Ansible's own
          # indexed_items lookup: [index, item] pairs (Python's
          # enumerate()), the classic with_indexed_items: source.
          source = parts[1]?.try { |part| evaluate_lookup_term(part.strip) }
          return "undefined" unless source
          lookup_array(source).map_with_index { |item, i| [JSON::Any.new(i.to_i64), item] }.to_json
        when "random_choice"
          # lookup('random_choice', list1, list2, ...) - real Ansible's
          # own random_choice lookup: every given term concatenated into
          # one list, then a single random element returned.
          # A single SCALAR result (unlike the always-array lookups
          # above) - formatted via @lookup.format_value rather than
          # .to_json, so a bare `{{ lookup('random_choice', l) }}`
          # renders the plain value text ("only"), not a quoted JSON
          # string literal ("\"only\"").
          items = parts[1..].flat_map { |part| lookup_array(evaluate_lookup_term(part.strip)) }
          return "undefined" if items.empty?
          @lookup.format_value(items.sample)
        when "subelements"
          lookup_subelements(parts)
        end
      end

      private def lookup_subelements(parts : Array(String)) : String
        # lookup('subelements', list_of_dicts, 'subkey', {
        # skip_missing: true}) - real Ansible's own subelements
        # lookup: for each dict, yields [parent_dict, child_item] for
        # every item in parent_dict[subkey] - the classic with_
        # subelements: source (e.g. iterating {user, group} for every
        # group in each user's own `groups:` list).
        source = parts[1]?.try { |part| evaluate_lookup_term(part.strip) }
        subkey = parts[2]?.try { |part| quoted_string_literal(part.strip) }.try(&.as_s?)
        return "undefined" unless source && subkey

        skip_missing = parts[3]?.try { |part| evaluate_lookup_term(part.strip) }.try(&.as_h?).try(&.["skip_missing"]?).try(&.as_bool?) || false
        result = [] of JSON::Any
        lookup_array(source).each do |parent|
          children = parent.as_h?.try(&.[subkey]?)
          if children.nil?
            raise "subelements: '#{subkey}' not found" unless skip_missing
            next
          end
          lookup_array(children).each { |child| result << JSON::Any.new([parent, child]) }
        end
        result.to_json
      end

      private def evaluate_lookup_file_parsers(lookup_type : String?, parts : Array(String)) : String?
        case lookup_type
        when "csvfile"
          # lookup('csvfile', 'key file=data.csv delimiter=, col=1') -
          # real Ansible's own csvfile lookup: finds the row whose first
          # column matches *key*, returns the value at column `col=`
          # (default 1) from that row. No quoted-field support (a
          # narrower CSV parser than Python's own csv module) - real-
          # world use of this lookup is almost always a simple lookup
          # table with no embedded delimiters.
          raw_arg = parts[1]?.try { |part| evaluate(part.strip) }
          return "undefined" unless raw_arg
          evaluate_csvfile_lookup(raw_arg)
        when "ini"
          # lookup('ini', 'value section=section1 file=file.ini') - real
          # Ansible's own ini lookup: reads `value` under `section=`
          # (default DEFAULT) from a controller-side INI file.
          raw_arg = parts[1]?.try { |part| evaluate(part.strip) }
          return "undefined" unless raw_arg
          evaluate_ini_lookup(raw_arg)
        when "unvault"
          # lookup('unvault', 'path/to/vaultfile') - real Ansible's own
          # unvault lookup: decrypts a vault-encrypted FILE (on the
          # controller) using the RUN's own configured vault secret
          # (Vault.password, set once from --vault-password-file/
          # --ask-vault-pass) - distinct from the `unvault` FILTER
          # above, which takes an explicit secret as a filter argument
          # instead.
          path = parts[1]?.try { |part| evaluate(part.strip) }
          password = Vault.password
          return "undefined" unless path && password
          begin
            Vault.decrypt(File.read(path), password)
          rescue
            "undefined"
          end
        else
          # `config`/`inventory_hostnames` deliberately NOT implemented:
          # config reads real ansible-core's OWN configuration system
          # (ansible.cfg + env vars + defaults across every plugin type),
          # which this codebase has no equivalent of at all - there's
          # nothing meaningful to look up. inventory_hostnames needs the
          # full Inventory object (host pattern matching against every
          # group), which ExpressionEvaluator has no access to - it's
          # built fresh per task/vars-context from a plain Hash(String,
          # JSON::Any), never threaded through from TaskExecutor's own
          # @inventory. Revisit inventory_hostnames if a real role turns
          # out to need it - would need @inventory plumbed through the
          # VarSubstitutor/ExpressionEvaluator construction chain.
          nil
        end
      end

      # `query(lookup_type, args)` - real Ansible's list-forcing sibling
      # of `lookup(...)` (see the call site's own comment for why this
      # exists as a separate entry point rather than just an alias).
      # `first_found` is the only lookup type real playbooks are known
      # to actually invoke this way in this codebase's own benchmark
      # history so far - anything else best-effort delegates to
      # #evaluate_lookup and wraps a non-list result in a single-element
      # JSON array (an already-list-shaped result, e.g. `url` with
      # `wantlist=True`, passes through unchanged).
      private def evaluate_query(args : String) : String
        parts = split_top_level_commas(args)
        lookup_type = parts[0]?.try { |part| quoted_string_literal(part.strip) }.try(&.as_s?)

        if lookup_type == "first_found"
          params = parts[1]?.try { |part| resolve_plus_operand(part.strip) }
          return "[]" unless params
          result = evaluate_first_found(params)
          return "[]" if result == "undefined"
          return [result].to_json
        end

        raw = evaluate_lookup(args)
        parsed = (JSON.parse(raw) rescue nil)
        parsed.try(&.as_a?) ? raw : [raw].to_json
      end

      private def evaluate_csvfile_lookup(raw_arg : String) : String
        tokens = raw_arg.strip.split(/\s+/)
        key = tokens[0]?
        return "undefined" unless key

        opts = Hash(String, String).new
        tokens[1..].each do |token|
          k, sep, v = token.partition('=')
          opts[k] = v unless sep.empty?
        end

        file = opts["file"]?
        return "undefined" unless file
        delimiter = opts["delimiter"]? || ","
        col = opts["col"]?.try(&.to_i) || 1

        begin
          File.each_line(file) do |line|
            fields = line.split(delimiter)
            next unless fields[0]?.try(&.strip) == key
            return (fields[col]? || "").strip
          end
        rescue
        end
        "undefined"
      end

      private def evaluate_ini_lookup(raw_arg : String) : String
        tokens = raw_arg.strip.split(/\s+/)
        value_key = tokens[0]?
        return "undefined" unless value_key

        opts = Hash(String, String).new
        tokens[1..].each do |token|
          k, sep, v = token.partition('=')
          opts[k] = v unless sep.empty?
        end

        file = opts["file"]?
        return "undefined" unless file
        wanted_section = opts["section"]? || "DEFAULT"

        begin
          current_section = "DEFAULT"
          File.each_line(file) do |raw_line|
            line = raw_line.strip
            next if line.empty? || line.starts_with?(';') || line.starts_with?('#')
            if line.starts_with?('[') && line.ends_with?(']')
              current_section = line[1..-2]
              next
            end
            next unless current_section == wanted_section
            k, sep, v = line.partition('=')
            return v.strip if sep != "" && k.strip == value_key
          end
        rescue
        end
        "undefined"
      end

      # Renders a single `lookup('list'/'items'/'together'/'nested', ...)`
      # TERM (one comma-separated argument, not the whole call) to its
      # real JSON::Any value - a term is usually a variable reference to
      # a list, but may itself be a literal.
      private def evaluate_lookup_term(part : String) : JSON::Any
        rendered = evaluate(part)
        (JSON.parse(rendered) rescue nil) || JSON::Any.new(rendered)
      end

      private def evaluate_sequence_lookup(raw_arg : String) : String
        tokens, opts = parse_sequence_opts(raw_arg)
        tokens.each do |token|
          key, sep, val = token.partition('=')
          opts[key] = val unless sep.empty?
        end

        start = opts["start"]?.try(&.to_i) || 1
        stride = opts["stride"]?.try(&.to_i) || 1
        count = opts["count"]?.try(&.to_i)
        finish = opts["end"]?.try(&.to_i)
        format = opts["format"]?

        total = count || (finish ? ((finish - start) // stride) + 1 : 1)
        return "undefined" if total < 0

        values = (0...total).map { |i| start + i * stride }
        sequence_formatted_values(values, format)
      end

      # Splits the sequence lookup's raw argument into its remaining
      # tokens and an opts hash, handling the shorthand positional
      # "start-end" form (`lookup('sequence', '1-5')`), real Ansible's
      # own alternate spelling - only when the whole first token has no
      # "=" at all, so it doesn't collide with the key=value form's own
      # values (a format= string could itself contain a literal "-").
      private def parse_sequence_opts(raw_arg : String) : {Array(String), Hash(String, String)}
        tokens = raw_arg.strip.split(/\s+/)
        opts = Hash(String, String).new
        if tokens[0]? && !tokens[0].includes?('=') && (range_match = tokens[0].match(/^(\d+)-(\d+)$/))
          opts["start"] = range_match[1]
          opts["end"] = range_match[2]
          tokens = tokens[1..]
        end
        {tokens, opts}
      end

      private def sequence_formatted_values(values : Array(Int32), format : String?) : String
        formatted = format ? values.map { |v| (format % v) rescue v.to_s } : values.map(&.to_s)
        formatted.to_json
      end

      # lookup('file'|'template', path) both name a CONTROLLER-side path
      # that - inside a role - is conventionally relative to the role's
      # own files/ dir (real Ansible's own behavior; `role_path` is
      # already available as a magic var, same mechanism
      # #resolve_first_found_root above uses). An absolute path, or a
      # relative one outside any role context, passes through unchanged.
      private def resolve_lookup_path(path : String) : String
        return path if path.starts_with?('/')
        role_path = @vars["role_path"]?.try(&.as_s?)
        role_path ? File.join(role_path, "files", path) : path
      end

      # real Ansible's password lookup default charset (ascii_letters +
      # digits + ".,:-_", its own `DEFAULT_PASSWORD_CHARS`) and default
      # length (20).
      PASSWORD_CHARS  = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a + [".", ",", ":", "-", "_"]
      PASSWORD_LENGTH = 20

      private def evaluate_password_lookup(raw_arg : String) : String
        tokens = raw_arg.strip.split(/\s+/)
        path = tokens[0]?
        return "undefined" unless path
        resolved_path = resolve_lookup_path(path)

        length = PASSWORD_LENGTH
        tokens[1..].each do |token|
          if token.starts_with?("length=")
            length = token[7..].to_i? || length
          end
        end

        if File.exists?(resolved_path)
          return File.read(resolved_path).chomp
        end

        password = Array.new(length) { PASSWORD_CHARS.sample }.join
        begin
          dir = File.dirname(resolved_path)
          Dir.mkdir_p(dir) unless Dir.exists?(dir)
          File.write(resolved_path, password + "\n")
        rescue
        end
        password
      end

      # Fetches *url* (a plain GET, no auth/headers - matches what these
      # real playbooks actually need it for: fetching a public checksums
      # file) and returns its body as a JSON array of non-blank lines,
      # matching how cloudalchemy.prometheus's own `wantlist=True) |
      # list` usage then loops over each line looking for one containing
      # a specific filename substring. Real Ansible's own url lookup
      # plugin has richer options (headers, auth, split_lines:) not
      # implemented here - narrowly scoped to what's actually been
      # needed so far, like several other lookup/filter gaps in this
      # file.
      private def fetch_url_lines(url : String, redirects_left : Int32 = 5) : String
        return "undefined" if redirects_left < 0

        response = HTTP::Client.get(url)

        # GitHub (and most CDNs fronting release assets, exactly what
        # this lookup is used for in practice) answers a plain GET with
        # a 302 to a signed, one-shot storage URL - Crystal's
        # `HTTP::Client.get` doesn't follow redirects on its own, so the
        # very first real call this lookup was tested against returned
        # an empty 302 body instead of the checksums file.
        if response.status.redirection? && (location = response.headers["Location"]?)
          resolved = URI.parse(location).absolute? ? location : URI.parse(url).resolve(location).to_s
          return fetch_url_lines(resolved, redirects_left - 1)
        end

        unless response.success?
          # Real Ansible's own url lookup plugin raises a hard
          # AnsibleError (failing the whole enclosing task, e.g. a
          # set_fact:) on ANY non-2xx response - verified against its
          # exact live error message ("Received HTTP error for <url> :
          # HTTP Error <code>: <reason>"). Found benchmarking buluma.
          # victoriametrics's own checksum-lookup task: a stale
          # `victoriametrics_version` default whose GitHub release
          # checksums file has since been removed (404 - a broken-
          # upstream default, not this engine's doing). Silently
          # degrading to "undefined" here (the old behavior) let
          # execution continue into a `with_items:` loop over a single
          # bogus "undefined" item instead of failing right at the
          # lookup, producing a real ok=/skipped= recap divergence from
          # real Ansible even though both engines ultimately fail this
          # broken-upstream role identically overall. A raised
          # exception here propagates up through #evaluate/#substitute
          # to the task executor's own generic rescue, which converts
          # it into a normal failed PluginResult - the same path
          # `subelements:`'s own `raise` (elsewhere in this file)
          # already relies on for "fail the enclosing task", not a new
          # mechanism.
          raise "The lookup plugin 'url' failed: Received HTTP error for #{url} : HTTP Error #{response.status_code}: #{response.status.description}"
        end

        lines = response.body.lines.map(&.strip).reject(&.empty?)
        lines.to_json
      rescue ex : Socket::Error | IO::Error
        # Genuine connection-level failures (DNS resolution, connection
        # refused, timeout) still degrade softly to "undefined" rather
        # than failing outright - only a real HTTP-level error response
        # (raised explicitly above) matches real Ansible's hard-fail
        # behavior; this project has no live evidence either way for
        # the connection-error case, so it's left at its prior,
        # conservative behavior rather than guessed at.
        "undefined"
      end

      # Real Ansible's first_found: the first `files:` entry that exists
      # under any `paths:` entry (both lists, in order - outer loop over
      # files, inner over paths, matching real Ansible's own search
      # order), each entry independently rendered since it commonly still
      # carries its own `{{ }}` markers (linux-system-roles/timesync's
      # `"{{ ansible_facts['distribution'] }}_{{ ansible_facts
      # ['distribution_version'] }}.yml"`) - unlike a bare expression,
      # these came from a task's own `vars:` dict and were never passed
      # through VarSubstitutor#substitute's mustache-span extraction, only
      # this evaluator's bare-expression path, so re-rendering here is the
      # first point either ever sees `{{ }}` syntax.
      #
      # Two real, related bugs found benchmarking geerlingguy.docker/
      # mysql/postgresql/php, which all share this exact idiom
      # (`lookup('first_found', params)` with a task `vars: params:
      # {files: [...], paths: [...]}`), fixed together since both are
      # "a relative paths: entry means role-relative, not cwd-relative":
      #   1. `paths:` omitted entirely used to default unconditionally to
      #      "." (plain cwd) - real Ansible's own default for a role-scoped
      #      first_found is the role's files/templates/vars dirs.
      #   2. `paths: ['vars']` (this idiom's actual common spelling - the
      #      docker/mysql/postgresql roles all give an explicit relative
      #      "vars") was joined straight against cwd too - "vars/Ubuntu.yml"
      #      against the *process's* cwd, essentially never the role dir a
      #      real `ansible-playbook` run resolves it against.
      # Both now go through resolve_first_found_root, which prepends
      # `role_path` (already sitting in @vars as a magic var - see
      # TaskExecutor#build_vars_context) to any relative entry, absolute
      # entries and non-role usage passing through unchanged. Resolves
      # entirely against the controller's own filesystem - real Ansible's
      # first_found always does (it's how role vars files that live on the
      # controller, not the managed host, get found).
      private def evaluate_first_found(params : JSON::Any) : String
        params_hash = params.as_h?
        return "undefined" unless params_hash

        files = lookup_array(params_hash["files"]?)
        paths_raw = params_hash["paths"]?
        paths = paths_raw ? lookup_array(paths_raw) : default_first_found_paths

        renderer = VarSubstitutor.new(vars: @vars, host_name: "localhost")
        rendered_paths = paths.flat_map { |path_entry| resolve_first_found_roots(renderer.substitute(path_entry.as_s? || "")) }

        files.each do |file_entry|
          rendered_file = renderer.substitute(file_entry.as_s? || "")
          rendered_paths.each do |path|
            candidate = File.join(path, rendered_file)
            return candidate if File.exists?(candidate)
          end
        end

        "undefined"
      end

      private def lookup_array(value : JSON::Any?) : Array(JSON::Any)
        value.try(&.as_a?) || [] of JSON::Any
      end

      # Matches the (files, templates, vars) root order TaskExecutor#
      # resolve_first_found_path already uses for the with_first_found:
      # keyword form, for the same result regardless of which of the two
      # real Ansible `first_found` spellings a role happens to use.
      private def default_first_found_paths : Array(JSON::Any)
        [JSON::Any.new("files"), JSON::Any.new("templates"), JSON::Any.new("vars"), JSON::Any.new(".")]
      end

      # A relative first_found `paths:` entry can resolve against EITHER
      # of two different real-Ansible bases depending on the idiom a
      # role happens to use, and there's no way to tell which from the
      # path text alone - both are tried, in this order, first match
      # wins:
      #  1. The current role's own ROOT directory (`role_path`, a magic
      #     var - see TaskExecutor#build_vars_context) - correct for
      #     `paths: ['vars']`/`paths: ['files']` (geerlingguy.docker/
      #     mysql/postgresql/php's own style).
      #  2. The directory of the task file that's DOING the lookup -
      #     approximated here as `role_path/tasks` (the overwhelmingly
      #     common location for a role's own tasks/main.yml; a deeper
      #     included tasks file would need the actual including file's
      #     directory, not available to this evaluator - not chased
      #     further without a real repro needing it) - correct for
      #     `paths: ['../vars']` (buluma.confluence's own style, real
      #     Ansible resolves this relative to tasks/, one level BELOW
      #     role_path, not relative to role_path itself). Found live
      #     benchmarking buluma.confluence (round 165): `paths: ['../
      #     vars']` against `role_path` alone resolved to role_path's
      #     own PARENT's "vars" dir (one level too far up) - never
      #     found the real per-OS vars file real ansible-playbook found
      #     via base 2, so include_vars: always got "undefined".
      # An absolute entry, or any entry when there's no enclosing role,
      # passes through unchanged (base 1 only, base 2 skipped - normalizing
      # `role_path` itself as ".." there would be meaningless without one).
      private def resolve_first_found_roots(path : String) : Array(String)
        return [path] if path.starts_with?("/")
        role_path = @vars["role_path"]?.try(&.as_s?)
        return [path] unless role_path

        [File.join(role_path, path), Path.new(role_path, "tasks", path).normalize.to_s]
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
      # OMIT_SENTINEL) - the marker real Ansible's `omit` leaves behind
      # for a container/parameter to drop rather than render.
      private def omit?(value : JSON::Any) : Bool
        value.as_s? == OMIT_SENTINEL
      end

      private def split_top_level_commas(expr : String) : Array(String)
        state = PlusSplitState.new
        expr.each_char { |char| split_top_level_commas_step(state, char) }
        state.parts << state.current.to_s.strip
        state.parts
      end

      private def split_top_level_commas_step(state : PlusSplitState, char : Char)
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

      private def combine_plus(a : JSON::Any, b : JSON::Any) : JSON::Any
        case {a.raw, b.raw}
        when {Array, Array}
          JSON::Any.new(a.as_a + b.as_a)
        when {String, String}
          JSON::Any.new(a.as_s + b.as_s)
        when {Int64, Int64}
          JSON::Any.new(a.as_i64 + b.as_i64)
        when {Float64, Float64}
          JSON::Any.new(a.as_f + b.as_f)
        else
          JSON::Any.new(@lookup.format_value(a) + @lookup.format_value(b))
        end
      end

      # Finds the first top-level " - " (spaces required - see the
      # `evaluate` call site for why), outside quotes/brackets/parens,
      # and splits *expr* around it. nil if there's no such split point at
      # all (not a subtraction expression).
      private class QuoteDepthTracker
        property depth = 0
        property quote : Char? = nil

        def advance(char : Char)
          if q = quote
            self.quote = nil if char == q
            return
          end
          advance_unquoted(char)
        end

        private def advance_unquoted(char : Char)
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

        value = if walk_part.strip.empty?
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
        left = resolve_plus_operand(left_expr)
        right = resolve_plus_operand(right_expr)
        @lookup.format_value(combine_minus(left, right))
      end

      private def combine_minus(a : JSON::Any, b : JSON::Any) : JSON::Any
        if (a_epoch = datetime_epoch(a)) && (b_epoch = datetime_epoch(b))
          return timedelta(a_epoch - b_epoch)
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
          JSON::Any.new(nil)
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
        value = render_via_crinja_value(expr)
        value ? @lookup.format_value(value) : "undefined"
      rescue
        evaluate_with_filter_fallback(expr)
      end

      private def evaluate_with_filter_fallback(expr : String) : String
        segments = FilterEngine.split_chain(expr)
        var_expr = segments[0]

        value = filter_chain_head_value(var_expr)

        result = segments[1..].reduce(value) { |acc, filter_expr| @filter.apply(acc, filter_expr) }
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
        if var_expr.starts_with?('(') && var_expr.ends_with?(')')
          # A parenthesized sub-expression as the chain's head -
          # dev-sec os_hardening's sysctl merge nests filter chains
          # this way: `((sysctl_config | combine(...)) |
          # combine(...)) | combine(...)`. Recursing (stripping the
          # outer pair) resolves each layer instead of treating the
          # whole parenthesized text as a literal variable name -
          # which always failed the lookup and silently collapsed
          # the entire with_dict: source to nothing.
          rendered = evaluate(var_expr[1..-2].strip)
          return (JSON.parse(rendered) rescue JSON::Any.new(rendered))
        end
        if var_expr.starts_with?("range(") && var_expr.ends_with?(')')
          # `range(1, 11) | list` / `range(1, 11) | ...` - same
          # function-call syntax as the no-filter case in
          # evaluate_expr, just reached via a different path since
          # top_level_pipe? routes anything with a `|` here first.
          return evaluate_range(var_expr[6..-2])
        end
        if var_expr.starts_with?("lookup(") && var_expr.ends_with?(')')
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
          close_idx = matching_close_paren_index(var_expr, 6)
          if close_idx
            lookup_rendered = evaluate_lookup(var_expr[7...close_idx])
            result = (JSON.parse(lookup_rendered) rescue JSON::Any.new(lookup_rendered))
            suffix = var_expr[(close_idx + 1)..]
            result = @lookup.apply_method_suffix(result, suffix) || result unless suffix.empty?
            return result
          end
        end

        nil
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

        # Real Ansible's recursive re-templating: a variable
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
        if value = retemplated_lookup_value(resolved)
          return value
        end

        resolved || JSON::Any.new(nil)
      end
    end
  end
end
