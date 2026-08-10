require "json"
require "../conditional_evaluator"
require "./comparison_evaluator"
require "./filter_engine"
require "./array_slicer"
require "./variable_lookup"
require "../variable_substitutor"
module CrystalPlay
  module VariableSubstitutor
    # ExpressionEvaluator - Orchestrates evaluation of all expression types
    # Delegates to specialized evaluators based on expression type
    class ExpressionEvaluator
      @vars : Hash(String, JSON::Any)
      @comparison : ComparisonEvaluator
      @filter : FilterEngine
      @slicer : ArraySlicer
      @lookup : VariableLookup
      
      def initialize(@vars : Hash(String, JSON::Any))
        @comparison = ComparisonEvaluator.new(@vars)
        @filter = FilterEngine.new(@vars)
        @slicer = ArraySlicer.new(@vars)
        @lookup = VariableLookup.new(@vars)
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
      def evaluate(expr : String) : String
        if ternary = split_ternary(expr)
          evaluate_ternary(ternary)
        elsif ternary_no_else = split_ternary_no_else(expr)
          evaluate_ternary_no_else(ternary_no_else)
        else
          evaluate_expr(expr)
        end
      end

      private def evaluate_expr(expr : String) : String
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
        return expr.downcase if expr == "true" || expr == "false" || expr == "True" || expr == "False"

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
          return @lookup.format_value(evaluate_range(expr[6..-2]))
        end

        # Check for comparison operators FIRST (before filters)
        if has_comparison?(expr)
          return @comparison.evaluate(expr)
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
          return evaluate_leading_paren(paren)
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
          return @lookup.nested(expr)
        end

        # Simple variable lookup
        @lookup.simple(expr)
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
        return @lookup.format_value(parse_literal_array(expr)) if literal_array_expr?(expr)
        return @slicer.slice(expr) if expr.includes?("[:") || expr.includes?(":]")
        @lookup.indexed(expr)
      end

      # Returns nil (not a String) when *expr* is neither a dict literal
      # nor `[`-bearing at all, so evaluate_expr's caller knows to fall
      # through to the plain `.`/simple-lookup checks instead.
      private def evaluate_bracket_or_dict_expr(expr : String) : String?
        return evaluate_dict_literal(expr) if literal_dict_expr?(expr)
        return evaluate_bracket_expr(expr) if expr.includes?("[")
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
        if_idx = top_level_keyword_index(expr, " if ")
        return nil unless if_idx

        else_idx = top_level_keyword_index(expr, " else ", if_idx + 4)
        return nil unless else_idx

        truthy = expr[0...if_idx].strip
        cond = expr[(if_idx + 4)...else_idx].strip
        falsy = expr[(else_idx + 6)..].strip
        return nil if truthy.empty? || cond.empty? || falsy.empty?

        {truthy, cond, falsy}
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
        if_idx = top_level_keyword_index(expr, " if ")
        return nil unless if_idx

        truthy = expr[0...if_idx].strip
        cond = expr[(if_idx + 4)..].strip
        return nil if truthy.empty? || cond.empty?

        {truthy, cond}
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
          elsif "[({".includes?(char)
            depth += 1
          elsif "])}".includes?(char)
            depth -= 1
          elsif depth == 0 && expr[i, keyword.size]? == keyword
            return i
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
        literal = quoted_string_literal(expr) || numeric_literal(expr)
        return literal if literal

        return parse_literal_array(expr) if expr.starts_with?('[') && expr.ends_with?(']')

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

        @lookup.resolve(expr) || JSON::Any.new(nil)
      end

      private def quoted_string_literal(expr : String) : JSON::Any?
        return nil if expr.size < 2
        return nil unless expr[0] == expr[-1] && (expr[0] == '\'' || expr[0] == '"')
        JSON::Any.new(expr[1..-2])
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
      private def evaluate_lookup(args : String) : String
        parts = split_top_level_commas(args)
        lookup_type = parts[0]?.try { |part| quoted_string_literal(part.strip) }.try(&.as_s?)

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
        else
          "undefined"
        end
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
        rendered_paths = paths.map { |path_entry| resolve_first_found_root(renderer.substitute(path_entry.as_s? || "")) }

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

      # A relative first_found `paths:` entry resolves against the
      # current role's own directory (`role_path`, set as a magic var
      # whenever the current task came from a role - see
      # TaskExecutor#build_vars_context), not the process's cwd. An
      # absolute entry, or any entry when there's no enclosing role,
      # passes through unchanged.
      private def resolve_first_found_root(path : String) : String
        return path if path.starts_with?("/")
        role_path = @vars["role_path"]?.try(&.as_s?)
        role_path ? File.join(role_path, path) : path
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
          h[key] = resolve_plus_operand(val_part.strip)
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

        elements = split_top_level_commas(inner).map { |elem| resolve_plus_operand(elem) }
        JSON::Any.new(elements)
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
          when '\'', '"'           then self.quote = char
          when '(', '[', '{'       then self.depth += 1
          when ')', ']', '}'       then self.depth -= 1
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
        segments = FilterEngine.split_chain(expr)
        var_expr = segments[0]

        value = if var_expr.starts_with?('(') && var_expr.ends_with?(')')
                  # A parenthesized sub-expression as the chain's head -
                  # dev-sec os_hardening's sysctl merge nests filter chains
                  # this way: `((sysctl_config | combine(...)) |
                  # combine(...)) | combine(...)`. Recursing (stripping the
                  # outer pair) resolves each layer instead of treating the
                  # whole parenthesized text as a literal variable name -
                  # which always failed the lookup and silently collapsed
                  # the entire with_dict: source to nothing.
                  rendered = evaluate(var_expr[1..-2].strip)
                  JSON.parse(rendered) rescue JSON::Any.new(rendered)
                elsif var_expr.starts_with?("range(") && var_expr.ends_with?(')')
                  # `range(1, 11) | list` / `range(1, 11) | ...` - same
                  # function-call syntax as the no-filter case in
                  # evaluate_expr, just reached via a different path since
                  # top_level_pipe? routes anything with a `|` here first.
                  evaluate_range(var_expr[6..-2])
                elsif var_expr.starts_with?("lookup(") && var_expr.ends_with?(')')
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
                  lookup_rendered = evaluate_lookup(var_expr[7..-2])
                  (JSON.parse(lookup_rendered) rescue JSON::Any.new(lookup_rendered))
                elsif literal = quoted_string_literal(var_expr)
                  # A quoted string literal as the chain's head
                  # (`{{ 'foo' | upper }}`, `{{ mysql_log_error | dirname
                  # }}`'s own sibling pattern with a literal instead of a
                  # variable) - previously fell to the plain-lookup else
                  # branch below, treating the literal text (quotes
                  # included) as a variable NAME to resolve, always
                  # undefined.
                  literal
                elsif var_expr.includes?("[")
                  # Array slicing (`list[0:2]`) and plain indexing
                  # (`list[0]`) aren't resolved to JSON::Any directly here
                  # (ArraySlicer/VariableLookup#indexed both still only
                  # return pre-formatted Strings) - fall back to the
                  # existing String-returning path and re-parse it, rather
                  # than duplicating that logic. "undefined" isn't valid
                  # JSON, so it maps to a real JSON null.
                  rendered = evaluate(var_expr)
                  JSON.parse(rendered) rescue JSON::Any.new(rendered)
                else
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
                  if resolved && (raw = resolved.raw).is_a?(String) && raw.includes?("{{")
                    inner = raw.strip
                    inner = inner[2..-3].strip if inner.starts_with?("{{") && inner.ends_with?("}}")
                    rendered = evaluate(inner)
                    JSON.parse(rendered) rescue JSON::Any.new(rendered)
                  else
                    resolved || JSON::Any.new(nil)
                  end
                end

        result = segments[1..].reduce(value) { |acc, filter_expr| @filter.apply(acc, filter_expr) }
        @lookup.format_value(result)
      end
    end
  end
end
