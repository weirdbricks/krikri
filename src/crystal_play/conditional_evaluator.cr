require "json"
require "./variable_substitutor/filter_engine"
require "./variable_substitutor/variable_lookup"
require "./variable_substitutor/expression_evaluator"
require "./variable_substitutor/crinja_renderer"
require "./vault"
require "./timing_profile"

module CrystalPlay
  # ConditionalEvaluator - Evaluates Ansible when: conditions
  # Supports:
  # - Equality: ==, !=
  # - Comparison: <, >, <=, >=
  # - Boolean: and, or, not
  # - Membership: in
  # - Existence: is defined, is not defined
  # - Truthiness: bare variable names

  module ConditionalEvaluator
    # Precompiled regular expressions for condition parsing.
    # Eliminates runtime regex compilation in hot `when:` and test paths.
    # `version_compare` is real Ansible's older alias for the `version`
    # test and is still accepted by ansible-core 2.19 (verified live,
    # round173). Missing it here was benign while conditionals were
    # lenient - the expression fell through to the generic comparison
    # splitter, which mistook the `>=` INSIDE the quoted operator
    # argument for a real comparison operator and quietly evaluated
    # false. Once 0.9.548 made a bare undefined reference RAISE, that
    # same misparse started hard-failing the task ("'')' is undefined")
    # for the extremely common `x is version_compare(min, '>=')`
    # version-gate idiom.
    REGEX_VERSION_TEST      = /\A(.+?)\s+is\s+version(?:_compare)?\(\s*(.+?)\s*,\s*(.+?)\s*\)\z/
    REGEX_MATCH_SEARCH_TEST = /^(.+?)\s+is\s+(not\s+)?(match|search)\((.+)\)\s*$/
    REGEX_SUBSET_TEST       = /^(.+?)\s+is\s+(not\s+)?(subset|superset|contains)\((.+)\)\s*$/
    REGEX_SAME_FILE_TEST    = /^(.+?)\s+is\s+(not\s+)?same_file\((.+)\)\s*$/
    REGEX_GENERIC_IS_TEST   = /\bis\s+(not\s+)?\w/
    REGEX_BARE_CALL         = /\A\w+\s*\(.*\)\z/
    REGEX_DIGITS            = /\d+/

    # Process-wide compiled regex cache for dynamic `is match(...)` / `is search(...)` patterns.
    @@compiled_regex_cache = Hash(String, Regex).new

    def self.cached_regex(pattern : String, anchored : Bool) : Regex
      key = anchored ? "^(?:#{pattern})" : pattern
      @@compiled_regex_cache[key] ||= Regex.new(key)
    end

    # Evaluate a when: condition against a variable context
    # Returns true if condition passes, false otherwise
    # Raised only from the `strict:` path (changed_when:/failed_when:) when
    # the condition's own value - not one produced by a real boolean
    # operator (==, in, is defined, and/or/not, ...) - resolves to a
    # genuine None/null (e.g. a filter like `regex_search()` finding no
    # match). Real Ansible's changed_when/failed_when (unlike when:, which
    # freely truthy-converts) requires the templated result to already be
    # a literal boolean; a None specifically raises "Conditional result
    # (...) was derived from value of type 'NoneType'. Conditionals must
    # have a boolean result." rather than being silently treated as false.
    class ConditionalBooleanError < Exception
    end

    # Raised only when *raise_undefined* is true (currently: task-level
    # `when:` via Executor#when_passes?, which already wraps this whole
    # call in a rescue that converts it into a real failed-task result -
    # see WhenEvaluationError there) and evaluating the condition reaches
    # a BARE or DOTTED variable reference (the same REGEX_BARE_VAR_REF-
    # shaped grammar VariableSubstitutor's own strict: module-arg check
    # already covers, see its UndefinedVariableError) that resolves to
    # nothing. Deliberately as narrowly scoped as that existing check:
    # only a direct lookup reaching evaluate_value's own "not found" exit
    # raises - a filter/function chain (`foo | default(...)`, `lookup(...)`,
    # any `is <test>`) still falls back to the lenient "undefined" sentinel
    # regardless, since this hand-rolled evaluator's own syntax-coverage
    # gaps already produce that same sentinel for reasons unrelated to the
    # variable genuinely being undefined - conflating the two would turn
    # an evaluator limitation into a spurious task failure (see
    # UndefinedVariableError's own comment in variable_substitutor.cr for
    # the identical reasoning applied there first).
    #
    # Found live via round172's buluma.git_tag (Rocky 9.6): `when:
    # git_remote != '' and git_remote != None` with `git_remote` genuinely
    # undefined (no default, never set). Real Ansible raises ("'git_remote'
    # is undefined") and fails the task (failed=1); this evaluator's
    # lenient `nil != ''`/`nil != None` comparisons both resolved truthy
    # instead, evaluating the whole `when:` as satisfied - the exact
    # "changes final task-pass/fail state" trigger KNOWN_MISSING.md called
    # for revisiting this with. `raise_undefined` is a separate flag from
    # `strict` above (which checks the FINAL result's own type, for
    # changed_when:/failed_when: - unrelated to whether an intermediate
    # operand was undefined) - the two are independent because
    # changed_when:/failed_when: deliberately still get the lenient
    # undefined-operand handling here (not touched by this fix).
    class UndefinedVariableError < Exception
    end

    def self.evaluate(condition : String, vars : Hash(String, JSON::Any), strict : Bool = false, raise_undefined : Bool = false) : Bool
      TimingProfile.measure("controller.conditionals", "controller") do
        evaluate_measured(condition, vars, strict, raise_undefined)
      end
    end

    private def self.evaluate_measured(condition : String, vars : Hash(String, JSON::Any), strict : Bool = false, raise_undefined : Bool = false) : Bool
      # Strip whitespace, then unwrap a fully-parenthesized expression.
      # condition_to_string wraps each list-`when:` clause in parens
      # (`(a != 'x') and (b != 'y')`), and the recursion here hands each
      # `(...)` clause back to evaluate - so a bare `where os_family !=
      # 'Suse'` must be evaluated with its outer parens removed, or the
      # `(` breaks lookup/split (left operand becomes "(os_family "). Only
      # strip when the parens enclose the *entire* remaining expression.
      condition = condition.strip
      # YAML folded (`>`) / literal (`|`) block scalars put REAL newlines
      # (plus runs of indentation spaces) into when:/changed_when:/
      # failed_when:/until: strings whenever a continuation line is more
      # indented than the block's own base indentation (equal-indent lines
      # fold to single spaces, more-indented ones keep their line breaks).
      # Real Ansible evaluates conditions through a real Python/Jinja
      # parser where inter-token whitespace is irrelevant; this
      # hand-rolled evaluator splits on literal " and "/" or "/etc. and
      # so a newline INSIDE an operand silently mis-splits the condition
      # - `mrlesmithjr.network-tweaks`' own `(x is defined and\n  x) and
      # (item.set is defined and\n    item.set)` evaluated FALSE for every
      # loop item while real Ansible ran them (round 189). Collapse every
      # whitespace run OUTSIDE string literals to a single space, before
      # any operator splitting happens.
      condition = normalize_condition_whitespace(condition)
      condition = unwrap_outer_parens(condition)

      # Handle the Python/Jinja2 conditional (ternary) expression `X if
      # COND else Y` - grammatically the LOWEST-precedence construct
      # (lower even than `or`/`and`: `conditional_expression ::= or_test
      # ["if" or_test "else" expression]`), so it must be detected before
      # the `or`/`and` splitting below or a bare `<`/`==`/etc. inside the
      # `X` branch gets misparsed as a top-level comparison spanning the
      # whole ternary (`1 < 2 if true else true` previously hit the `<`
      # comparison check first, splitting into "1 " and " 2 if true else
      # true" - nonsensical). Delegated whole to Crinja (matching the
      # REGEX_BARE_CALL/REGEX_GENERIC_IS_TEST fallbacks just below, both
      # of which exist for the identical reason: don't reimplement a
      # sub-grammar this hand-rolled evaluator was never built to parse)
      # rather than attempting to hand-evaluate the branches - a ternary
      # branch is an arbitrary expression, not necessarily a bare
      # condition. `split_by_operator` is paren/quote-depth aware, so a
      # ternary nested inside parens (`a and (b if c else d)`) is left
      # alone here and only found after the outer parens are unwrapped by
      # recursion. Found via buluma.auditd's own assert.yml: `(auditd_
      # admin_space_left | int < auditd_space_left | int) if (auditd_
      # space_left | string is not match(".*%")) else true` failed
      # outright (misread as a bare truthiness check on the whole
      # unparsed string) while real Ansible passed - even the trivial
      # `true if true else false` was broken, this had no working case.
      if condition.includes?(" if ") && condition.includes?(" else ")
        if_parts = split_by_operator(condition, " if ")
        if if_parts.size == 2
          else_parts = split_by_operator(if_parts[1], " else ")
          if else_parts.size == 2
            rendered = VariableSubstitutor::CrinjaRenderer.new(vars).render("{{ 'True' if (#{condition}) else 'False' }}")
            return rendered.strip == "True"
          end
        end
      end

      # Operator precedence (matching real Python/Jinja2): `or` binds
      # loosest, then `and`, then `not` binds tightest. Splitting on the
      # LOWEST-precedence operator first and recursing into each side is
      # what makes that nest correctly - `a and b or c` splits on `or`
      # into ["a and b", "c"], and the recursive call on "a and b" then
      # finds *its own* top-level `and` and splits that in turn, giving
      # the correct `(a and b) or c` grouping.
      #
      # `not` used to be checked FIRST, before either split - a `not X
      # or Y` condition therefore never reached the `or` split at all;
      # `evaluate` matched the leading "not " and negated the ENTIRE
      # remaining string "X or Y" as one unit (`not (X or Y)` instead of
      # the correct `(not X) or Y`). Found benchmarking geerlingguy.helm:
      # "Download helm." gates on `when: not helm_check.stat.exists or
      # "{{ helm_version }}" not in helm_existing_version.stdout` - with
      # the binary not yet installed, `not helm_check.stat.exists` alone
      # is already true and real Ansible's `or` short-circuits there
      # without ever evaluating the second (undefined-stdout) clause;
      # here the whole `X or Y` got negated as one blob first, discarding
      # short-circuiting entirely and evaluating false, so Download/Copy
      # were skipped outright and helm was never installed.
      #
      # Handle 'or' operator (split and evaluate any part)
      if condition.includes?(" or ")
        parts = split_by_operator(condition, " or ")
        return parts.any? { |part| evaluate(part.strip, vars, strict, raise_undefined) } if split_progressed?(parts, condition)
      end

      # Handle 'and' operator (split and evaluate all parts).
      #
      # The `split_progressed?` guard is load-bearing, not defensive
      # tidiness: `includes?` sees an operator anywhere in the string,
      # but split_by_operator only splits on one at paren depth 0 outside
      # quotes. A condition whose only " and " sits inside quotes -
      # `["a", "b and c"]` - therefore came back as a single part
      # identical to the input, and this line recursed on that same
      # string until the stack blew (observed at ~104k frames deep, on a
      # real playbook). Falling through instead lets the rest of
      # evaluate/evaluate_truthiness deal with it, which terminates.
      if condition.includes?(" and ")
        parts = split_by_operator(condition, " and ")
        return parts.all? { |part| evaluate(part.strip, vars, strict, raise_undefined) } if split_progressed?(parts, condition)
      end

      # Handle 'not' at the beginning - checked last (highest
      # precedence), after both boolean-operator splits above have had
      # a chance to peel off any top-level `and`/`or` first.
      # Deliberately NOT strict here: Python/Jinja's `not x` always
      # produces a real bool regardless of x's own type, so a None-typed
      # operand under `not` is exactly as safe in real Ansible as under
      # crystal's existing truthy conversion - no divergence to guard.
      if condition.starts_with?("not ")
        return !evaluate(condition[4..-1].strip, vars, false, raise_undefined)
      end

      # Handle 'is version(comparison_version, operator)' - Ansible's own
      # test (ansible.builtin.version), not standard Jinja2. Must be
      # checked before the comparison-operator checks just below: the
      # operator argument itself is very often a quoted `'>='`/`'<='`
      # literal (ssh_hardening's own crypto_hostkeys.yml gates 3
      # different set_fact: tasks on `when: sshd_version is version(
      # '5.3', '>=')`-shaped conditions), and `condition.includes?(">=")`
      # would otherwise fire first, splitting the *entire* "X is
      # version('5.3', '>=')" string on that substring as if it were a
      # top-level comparison - a nonsensical parse. Previously entirely
      # unimplemented here (only Crinja, the separate evaluator backing
      # real template files, had a `version` test) - every one of those
      # three when: conditions evaluated false via the generic fallback,
      # so the version-appropriate host key list was never set, leaving
      # a `loop:` over a genuinely undefined variable three tasks later
      # (surfacing as `item` = the literal string "undefined").
      if version_test = condition.match(REGEX_VERSION_TEST)
        return evaluate_version_test(version_test[1], version_test[2], version_test[3], vars, raise_undefined)
      end

      # Handle comparison operators
      if condition.includes?("==")
        return evaluate_comparison(condition, "==", vars, raise_undefined)
      elsif condition.includes?("!=")
        return evaluate_comparison(condition, "!=", vars, raise_undefined)
      elsif condition.includes?("<=")
        return evaluate_comparison(condition, "<=", vars, raise_undefined)
      elsif condition.includes?(">=")
        return evaluate_comparison(condition, ">=", vars, raise_undefined)
      elsif condition.includes?("<")
        return evaluate_comparison(condition, "<", vars, raise_undefined)
      elsif condition.includes?(">")
        return evaluate_comparison(condition, ">", vars, raise_undefined)
      end

      # Handle 'in' / 'not in' operator. `'x' not in list` must be checked
      # as its own token (a leading `not ` followed by ` in `), since the
      # generic `in` splitter would otherwise leave the `not` glued to the
      # left operand (`'x' not` / ` in list`) and never match. dev-sec
      # os_hardening gates tasks on `'"change_user" not in
      # os_security_users_allow'`.
      # Jinja2's `in` TEST (`x is in y` / `x is not in y`, added in
      # Jinja 2.10) is the same containment check as the `in` OPERATOR
      # spelled as a test, so it is normalized to the operator form
      # here - before the two handlers below, which would otherwise
      # split `item is not in ignore` on " not in " and hand
      # evaluate_in a left operand of "item is" ("'item is' is
      # undefined", failing the task outright). Found live benchmarking
      # devsec.hardening.os_hardening, whose user_accounts.yml gates
      # every interactive-user task on `item is not in
      # os_always_ignore_users`; verified against real ansible-core
      # 2.19.4, which skips/runs exactly as the operator form does.
      condition = condition.gsub(" is not in ", " not in ").gsub(" is in ", " in ")

      if condition.includes?(" not in ")
        return !evaluate_in(condition.gsub(" not in ", " in "), vars, raise_undefined)
      end

      # Handle 'in' operator
      if condition.includes?(" in ")
        return evaluate_in(condition, vars, raise_undefined)
      end

      # Handle 'is defined' / 'is not defined' / 'is undefined' / 'is not
      # undefined' - real Jinja2 provides both spellings (`undefined` is
      # simply `defined`'s own negation, not a distinct concept), and
      # real playbooks use both (ssh_hardening's own crypto_ciphers.yml/
      # crypto_macs.yml/crypto_kex.yml default-setting tasks are all
      # gated on `when: ssh_ciphers is undefined`, never `is not
      # defined`). Previously only "is defined"/"is not defined" were
      # recognized - an unrecognized "is undefined" fell through to the
      # generic #evaluate_truthiness path below, which doesn't
      # understand `is` tests at all and evaluated it as always falsy -
      # the task setting the real default value was silently skipped on
      # every run, leaving the variable genuinely undefined by the time
      # a template referenced it (a crash three tasks later, nowhere
      # near this one).
      if condition.includes?(" is not undefined")
        var_name = condition.gsub(" is not undefined", "").strip
        return defined?(vars, var_name)
      elsif condition.includes?(" is undefined")
        var_name = condition.gsub(" is undefined", "").strip
        return !defined?(vars, var_name)
      elsif condition.includes?(" is defined")
        var_name = condition.gsub(" is defined", "").strip
        return defined?(vars, var_name)
      elsif condition.includes?(" is not defined")
        var_name = condition.gsub(" is not defined", "").strip
        return !defined?(vars, var_name)
      end

      # Handle 'is mapping' / 'is sequence' (plus each "is not ..."
      # negation) - real Jinja2's own type tests (a dict/Hash vs. a
      # list/Array), used e.g. as a defaults-sanity assert:
      # `grafana_security is mapping`. Entirely unimplemented before -
      # fell through to #evaluate_truthiness, which has no notion of
      # `is` tests at all and treated the whole "X is mapping" text as
      # an undefined variable lookup, always false - failing the assert
      # regardless of the variable's real type. `sequence` deliberately
      # does NOT match a bare String (Python/Jinja2's own `is sequence`
      # test technically would, since strings are iterable - but every
      # real playbook using this pattern means "is this a list", and
      # matching String too would make `is not sequence` wrongly reject
      # ordinary string variables).
      # 'boolean'/'number'/'string'/'integer'/'float'/'iterable' - the rest
      # of Jinja2's own type tests, alongside mapping/sequence above.
      # Found via robertdebock.bootstrap's own `bootstrap_wait_for_host is
      # boolean` assert (round 18) - entirely unimplemented before, same
      # failure mode as mapping/sequence originally were: fell through to
      # #evaluate_truthiness and always evaluated false, failing the
      # assert on every role that uses this idiom regardless of the
      # variable's real type.
      {"mapping", "sequence", "boolean", "number", "string", "integer", "float", "iterable", "none"}.each do |test_name|
        if condition.includes?(" is not #{test_name}")
          var_name = condition.gsub(" is not #{test_name}", "").strip
          return !matches_type_test?(vars, var_name, test_name)
        elsif condition.includes?(" is #{test_name}")
          var_name = condition.gsub(" is #{test_name}", "").strip
          return matches_type_test?(vars, var_name, test_name)
        end
      end

      # Handle 'is failed' / 'is succeeded' / 'is success' / 'is changed'
      # / 'is skipped' (plus each "is not ..." negation) - real Ansible's
      # own tests on a registered task result, reading the corresponding
      # boolean field out of its result dict. Entirely unimplemented
      # before (fell through to #evaluate_truthiness, which has no
      # notion of `is` tests at all and treated the whole "X is failed"
      # text as an undefined variable lookup - always falsy). Found via
      # ansible-community.ansible-vault's own `when: not vault_installation
      # is failed` (gating "Get installed Vault version" on the previous
      # task's own success) - always evaluated true (the `not` of a
      # falsy fallback), running the version-check command even on a
      # completely fresh host where "Check Vault installation" had
      # genuinely failed and left `.stdout` empty, producing a bogus
      # "-version" command with no vault binary in it at all.
      # "succeeded"/"success"/"successful" are the same test - real
      # Ansible's own TestModule.tests maps all three (plus "failure",
      # "change", "skip" short aliases) to the same underlying checks.
      # "successful" specifically was missing here even though it's the
      # exact spelling `until: result is successful` uses (found via
      # mrlesmithjr.motd's "debian | Installing Pre-Reqs" apt task,
      # round180): falling through with no matching test_name left the
      # `until:` retry loop's own `ConditionalEvaluator.evaluate` call
      # never seeing a recognized test, so it looped the full default 3
      # retries regardless of the first attempt's real success - the
      # package install genuinely succeeded (changed: true) on attempt
      # 1, but retries 2/3 re-ran the now-idempotent apt task and their
      # `changed: false` "already installed" result was what actually
      # got registered/reported, silently losing the real changed status.
      # Ordered so a longer name is checked before any other name that's
      # merely its own prefix ("successful"/"success", "changed"/"change",
      # "skipped"/"skip") - same `includes?`+`gsub` substring-prefix trap
      # as "link_exists" vs "link" above: checking "success" first would
      # match inside "result is successful" too (`" is success"` is a
      # literal substring of `" is successful"`), and the `gsub` then only
      # strips that shorter substring, leaving a mangled var_name ("ful")
      # that never resolves - silently evaluating to false forever.
      {"failed", "failure", "succeeded", "successful", "success", "changed", "change", "skipped", "skip"}.each do |test_name|
        if condition.includes?(" is not #{test_name}")
          var_name = condition.gsub(" is not #{test_name}", "").strip
          return !result_field(vars, var_name, test_name)
        elsif condition.includes?(" is #{test_name}")
          var_name = condition.gsub(" is #{test_name}", "").strip
          return result_field(vars, var_name, test_name)
        end
      end

      # Handle 'is exists' / 'is file' / 'is directory' / 'is link' /
      # 'is link_exists' (plus each "is not ..." negation) - real
      # Ansible's own path-check tests. Like lookup('file', ...), these
      # always check the CONTROLLER's filesystem, never the target's -
      # matches real Ansible's own behavior (these are plain os.path.*
      # wrappers running in the controller's own Python process).
      # "link_exists" MUST be checked before "link" - " is link_exists"
      # contains " is link" as a substring, so testing "link" first
      # would misfire on it (gsub(" is link", "") on "l is link_exists"
      # leaves the mangled var_name "l_exists", always undefined/false).
      {"link_exists", "exists", "file", "directory", "link"}.each do |test_name|
        if condition.includes?(" is not #{test_name}")
          var_name = condition.gsub(" is not #{test_name}", "").strip
          return !matches_path_test?(vars, var_name, test_name)
        elsif condition.includes?(" is #{test_name}")
          var_name = condition.gsub(" is #{test_name}", "").strip
          return matches_path_test?(vars, var_name, test_name)
        end
      end

      # Handle 'is same_file(...)' (plus "is not ..." negation) - real
      # Ansible's own test, os.path.samefile (same device+inode, not
      # just equal path strings - true for two different paths to the
      # same hardlinked file).
      if test_match = condition.match(REGEX_SAME_FILE_TEST)
        var_expr = test_match[1].strip
        negate = !test_match[2]?.nil?
        arg_expr = test_match[3].strip

        path1 = resolve_test_operand(var_expr, vars).try(&.as_s?)
        path2 = resolve_test_operand(arg_expr, vars).try(&.as_s?)
        result = (path1 && path2 && File.exists?(path1) && File.exists?(path2)) ? File.same?(path1, path2) : false
        return negate ? !result : result
      end

      # Handle 'is mount' (plus "is not ..." negation) - real Ansible's
      # own test, real os.path.ismount(). Shells to the real
      # `mountpoint(8)` utility (util-linux, near-universal on Linux)
      # rather than hand-rolling a device/inode stat comparison, same
      # "trust a real system tool" approach dpkg_selections/subversion/
      # known_hosts already take. Runs on the CONTROLLER, same rule
      # every other path-check test here follows.
      if condition.includes?(" is not mount")
        var_name = condition.gsub(" is not mount", "").strip
        return !mount_point?(vars, var_name)
      elsif condition.includes?(" is mount")
        var_name = condition.gsub(" is mount", "").strip
        return mount_point?(vars, var_name)
      end

      # Handle 'is vault_encrypted' / 'is vaulted_file' (plus each "is
      # not ..." negation) - real Ansible's own tests: vault_encrypted
      # checks a STRING value's own content; vaulted_file reads a path
      # (on the CONTROLLER) and checks its content.
      {"vault_encrypted", "vaulted_file"}.each do |test_name|
        if condition.includes?(" is not #{test_name}")
          var_name = condition.gsub(" is not #{test_name}", "").strip
          return !matches_vault_test?(vars, var_name, test_name)
        elsif condition.includes?(" is #{test_name}")
          var_name = condition.gsub(" is #{test_name}", "").strip
          return matches_vault_test?(vars, var_name, test_name)
        end
      end

      # Handle 'is urn' (plus "is not ..." negation) - real Ansible's
      # own test: validates the value is a syntactically well-formed
      # URN (RFC 8141: "urn:<nid>:<nss>").
      if condition.includes?(" is not urn")
        var_name = condition.gsub(" is not urn", "").strip
        return !matches_urn?(vars, var_name)
      elsif condition.includes?(" is urn")
        var_name = condition.gsub(" is urn", "").strip
        return matches_urn?(vars, var_name)
      end

      # Handle 'is started' / 'is finished' / 'is timedout' / 'is
      # reachable' / 'is unreachable' (plus each "is not ..." negation)
      # - real Ansible's own tests on a registered result dict (the
      # `async_status:`/`wait_for_connection:` shape). Deliberately NOT
      # #result_field below - real Ansible's own async_status result
      # (and this codebase's own plugins/async_status.cr) represents
      # `started:`/`finished:` as an INTEGER 0/1, not a JSON bool, and
      # #result_field's `.as_bool?` check silently returns false for
      # any non-bool field - always wrong for the actual real-world
      # shape these two tests exist to check. "reachable" inverts the
      # SAME `unreachable` field real Ansible's own implementation
      # checks, not a separately-tracked "reachable" field.
      {"started", "finished", "timedout", "unreachable"}.each do |test_name|
        if condition.includes?(" is not #{test_name}")
          var_name = condition.gsub(" is not #{test_name}", "").strip
          return !async_field_truthy?(vars, var_name, test_name)
        elsif condition.includes?(" is #{test_name}")
          var_name = condition.gsub(" is #{test_name}", "").strip
          return async_field_truthy?(vars, var_name, test_name)
        end
      end
      if condition.includes?(" is not reachable")
        var_name = condition.gsub(" is not reachable", "").strip
        return async_field_truthy?(vars, var_name, "unreachable")
      elsif condition.includes?(" is reachable")
        var_name = condition.gsub(" is reachable", "").strip
        return !async_field_truthy?(vars, var_name, "unreachable")
      end

      # Handle 'is match(...)' / 'is search(...)' (plus each "is not ..."
      # negation) - real Jinja2's own regex tests: match() anchors at
      # the START of the string only (Python's re.match, NOT a full-
      # string anchor - "latestXYZ" is match("latest") is still true),
      # search() matches anywhere in the string (re.search). Entirely
      # unimplemented before (fell through to #evaluate_truthiness,
      # which has no notion of `is` tests at all and treated the whole
      # "X is match(...)" text as an undefined variable lookup, always
      # falsy). Found via geerlingguy.node_exporter's own `when:
      # node_exporter_version is match("latest") or node_exporter_version
      # is not defined` (deciding whether to resolve "latest" to a real
      # release tag via the GitHub API) - always skipped, leaving
      # node_exporter_version as the literal string "latest" and
      # building a download URL for a release that doesn't exist
      # ("vlatest"/"node_exporter-latest..."), failing the download
      # outright.
      if test_match = condition.match(REGEX_MATCH_SEARCH_TEST)
        var_expr = test_match[1].strip
        negate = !test_match[2]?.nil?
        anchored = test_match[3] == "match"
        pattern = unquote_literal(test_match[4].strip)

        str_value = case value = evaluate_value(var_expr, vars)
                    when String then value
                    when Nil    then ""
                    else             value.to_s
                    end

        matched = !!(str_value =~ cached_regex(pattern, anchored))
        return negate ? !matched : matched
      end

      # Handle 'is subset(...)' / 'is superset(...)' / 'is contains(...)'
      # (plus each "is not ..." negation) - real Ansible's own tests
      # (ansible.builtin, not standard Jinja2), common in `assert:`-heavy
      # hardening roles checking one list/dict against another. Entirely
      # unimplemented before - fell through to the generic fallback
      # below, which has no notion of these test names either and always
      # evaluated the whole condition as an undefined (falsy) bare
      # variable lookup.
      if test_match = condition.match(REGEX_SUBSET_TEST)
        var_expr = test_match[1].strip
        negate = !test_match[2]?.nil?
        test_name = test_match[3]
        arg_expr = test_match[4].strip

        left = resolve_test_operand(var_expr, vars)
        right = resolve_test_operand(arg_expr, vars)

        result = case test_name
                 when "subset"
                   left_arr = left.try(&.as_a?) || [] of JSON::Any
                   right_arr = right.try(&.as_a?) || [] of JSON::Any
                   left_arr.all? { |item| right_arr.includes?(item) }
                 when "superset"
                   left_arr = left.try(&.as_a?) || [] of JSON::Any
                   right_arr = right.try(&.as_a?) || [] of JSON::Any
                   right_arr.all? { |item| left_arr.includes?(item) }
                 else # "contains" - Python's `b in a` for whichever container shape *a* (left) actually is
                   case left.try(&.raw)
                   when Array
                     if l = left
                       l.as_a.includes?(right || JSON::Any.new(nil))
                     else
                       false
                     end
                   when Hash
                     if h = left
                       right.try(&.as_s?).try { |key| h.as_h.has_key?(key) } || false
                     else
                       false
                     end
                   when String
                     if st = left
                       st.as_s.includes?(right.try(&.as_s?) || right.to_s)
                     else
                       false
                     end
                   else
                     false
                   end
                 end

        return negate ? !result : result
      end

      # Generic fallback for any other real Jinja2 `is [not] <test>`
      # built-in this module hasn't special-cased above (`divisibleby`,
      # `even`, `odd`, `equalto`, `sameas`, `escaped`, `callable`, etc) -
      # every specific `is` pattern already handled above (version,
      # defined/undefined, mapping/sequence/etc, match/search) returns
      # early, so reaching here with an " is "/" is not " substring means
      # a genuinely UNHANDLED test name, not a real bare-variable
      # truthiness check. Previously this fell straight into
      # #evaluate_truthiness below, which has no notion of `is` tests at
      # all - the whole condition string ("n is not divisibleby 2") was
      # looked up as if it were a literal (nonexistent) variable NAME,
      # always undefined -> nil -> false, regardless of the real
      # divisibility - not "usually wrong", ALWAYS wrong (both an even
      # and an odd operand evaluated identically to false). Found via
      # robertdebock.nomad's own `nomad_server_bootstrap_expect is not
      # divisibleby 2` assert (verifying an odd bootstrap_expect count).
      # Delegates the whole condition to Crinja (`CrinjaRenderer`, the
      # separate evaluator that already implements every real Jinja2
      # test correctly by construction, verified directly here to
      # produce the right True/False) rather than reimplementing every
      # possible built-in test's own semantics by hand.
      if condition.match(REGEX_GENERIC_IS_TEST)
        rendered = VariableSubstitutor::CrinjaRenderer.new(vars).render("{{ (#{condition}) }}")
        return rendered.strip == "True"
      end

      # Generic fallback for a bare Jinja FUNCTION CALL as the whole
      # condition (`lookup(...)`, `query(...)`, etc.) - #evaluate_value
      # has no notion of function-call syntax at all, so this fell
      # through to #evaluate_truthiness, which resolves the condition
      # text as a variable NAME/literal - the call itself was never
      # actually invoked, so its real return value never factored into
      # the truthiness at all (verified directly: `when: lookup(...)`
      # and `when: not lookup(...)` evaluated to the SAME result
      # regardless of what the lookup actually returned - proof the call
      # wasn't running, not just returning the wrong answer). Found via
      # devsec.hardening.os_hardening's own `when: not lookup('varnames',
      # '^' + item.key + '$')` (deciding whether to skip a `set_fact:`
      # for a name the user already defined, looping every OS-family
      # variable the role loads) - always treated as a no-op, so
      # `auditd_package` (and every other OS-family package/config name)
      # never got promoted from the loaded `os_vars` dict into a real
      # top-level variable, leaving `{{ auditd_package }}` to render this
      # codebase's own "undefined" sentinel and fail the role's very
      # first real task ("Unable to locate package undefined").
      #
      # Delegated to Crinja via an explicit boolean ternary - not just
      # rendering the raw expression, since a Jinja list/dict/string/int
      # result needs real Python truthiness applied to it, not just
      # non-empty-string-ness - rather than reimplementing every lookup
      # plugin's own return shape by hand.
      if condition =~ REGEX_BARE_CALL
        rendered = VariableSubstitutor::CrinjaRenderer.new(vars).render("{{ 'True' if (#{condition}) else 'False' }}")
        return rendered.strip == "True"
      end

      # Handle bare variable (truthiness check)
      evaluate_truthiness(condition, vars, strict, raise_undefined)
    end

    # If *expr* is entirely wrapped in one matching pair of outer parens
    # (`(a and b)` or `(x == 1)`), return the inner expression with the
    # parens removed; otherwise return it unchanged. Quotes and inner
    # parens (e.g. `is version('1.4.0', '<')`) are balanced correctly, so
    # only a paren at the very start matched by one at the very end (with
    # depth returning to 0 only at the end) is stripped.
    private def self.unwrap_outer_parens(expr : String) : String
      return expr unless expr.starts_with?("(")

      depth = 0
      in_quotes = false
      quote_char = ' '
      expr.each_char_with_index do |char, idx|
        if (char == '"' || char == '\'') && (idx == 0 || expr[idx - 1] != '\\')
          if in_quotes && char == quote_char
            in_quotes = false
          elsif !in_quotes
            in_quotes = true
            quote_char = char
          end
        end

        next if in_quotes

        if char == '('
          depth += 1
        elsif char == ')'
          depth -= 1
          # If depth returns to 0 before the final char, the paren at the
          # start is not a full-wrap (the expression has trailing content),
          # so don't unwrap.
          return expr if depth == 0 && idx < expr.size - 1
        end
      end

      # Depth 1 after the loop means the whole expr was `(...)` - unwrap.
      expr[1..-2].strip
    end

    # Whether splitting actually broke the condition down. A single part
    # equal to the original means no real split happened, so recursing on
    # it would not terminate.
    private def self.split_progressed?(parts : Array(String), condition : String) : Bool
      parts.size > 1 || (parts.size == 1 && parts[0].strip != condition.strip)
    end

    # Split condition by operator, respecting parentheses and quotes
    # *condition[i..-1].starts_with?(operator)* allocated a full
    # substring of the remaining condition on every character, and
    # *current += char* reallocated the accumulator on every character -
    # together an O(n^2) scan. Bounded per-char operator comparison (no
    # allocation) plus a String::Builder accumulator, matching the shape
    # FilterEngine.split_chain already uses for the same kind of
    # depth/quote-aware scan.
    private def self.operator_at?(condition : String, index : Int32, operator : String) : Bool
      return false if index + operator.size > condition.size

      operator.each_char.with_index do |operator_char, offset|
        return false unless condition[index + offset] == operator_char
      end
      true
    end

    private def self.split_by_operator(condition : String, operator : String) : Array(String)
      parts = [] of String
      current = String::Builder.new
      paren_depth = 0
      in_quotes = false
      quote_char = ' '
      i = 0

      while i < condition.size
        char = condition[i]

        # Track quotes
        if (char == '"' || char == '\'') && (i == 0 || condition[i - 1] != '\\')
          if in_quotes && char == quote_char
            in_quotes = false
          elsif !in_quotes
            in_quotes = true
            quote_char = char
          end
        end

        # Track parentheses
        if !in_quotes
          if char == '('
            paren_depth += 1
          elsif char == ')'
            paren_depth -= 1
          end
        end

        # Check for operator
        if !in_quotes && paren_depth == 0
          if operator_at?(condition, i, operator)
            parts << current.to_s.strip
            current = String::Builder.new
            i += operator.size
            next
          end
        end

        current << char
        i += 1
      end

      final = current.to_s.strip
      parts << final unless final.empty?
      parts
    end

    # Evaluate comparison operators
    private def self.evaluate_comparison(condition : String, operator : String, vars : Hash(String, JSON::Any), raise_undefined : Bool = false) : Bool
      parts = condition.split(operator, 2)
      return false if parts.size != 2

      left = evaluate_value(parts[0].strip, vars, raise_undefined)
      right = evaluate_value(parts[1].strip, vars, raise_undefined)

      case operator
      when "=="
        values_equal?(left, right)
      when "!="
        !values_equal?(left, right)
      when "<"
        compare_values(left, right) < 0
      when ">"
        compare_values(left, right) > 0
      when "<="
        compare_values(left, right) <= 0
      when ">="
        compare_values(left, right) >= 0
      else
        false
      end
    end

    # Evaluate 'in' operator
    # Resolves *left_expr* (a variable/dotted/filter-chain expression, the
    # same grammar #evaluate_value already handles) and compares it
    # against the quoted-literal *compare_to_expr* using *operator_expr*
    # (also a quoted literal, e.g. `'>='`) - see the call site above for
    # why this needs to run before the generic comparison-operator
    # checks.
    # Reads *test_name* ("failed"/"changed"/"skipped"/"succeeded"/
    # "success") off a registered task result. "succeeded"/"success"
    # aren't real result-dict keys - Ansible doesn't store a positive
    # "it worked" flag, only "failed" - so both spellings are the
    # inverse of "failed" instead. A field genuinely absent (a var that
    # isn't a registered result at all, or a task type whose result
    # never sets "skipped") defaults to false, matching real Ansible's
    # own tests never raising for a missing field.
    private def self.result_field(vars : Hash(String, JSON::Any), var_name : String, test_name : String) : Bool
      result = vars[var_name]?
      return false unless result

      failed = result["failed"]?.try(&.as_bool?) || false
      case test_name
      when "succeeded", "success", "successful"
        !failed
      when "failure"
        failed
      when "change"
        result["changed"]?.try(&.as_bool?) || false
      when "skip"
        result["skipped"]?.try(&.as_bool?) || false
      else
        result[test_name]?.try(&.as_bool?) || false
      end
    end

    # Whether *var_name* (a bare OR dotted/indexed variable reference,
    # e.g. `grafana_security.admin_user`) actually resolves to a real
    # value - `vars.has_key?(var_name)` (the previous, and still correct
    # for a BARE name, implementation) always returns false for a dotted
    # path, since no literal key containing a "." exists in `vars` -
    # `grafana_security.admin_user is not defined` therefore always
    # evaluated true regardless of whether admin_user was actually set,
    # found via cloudalchemy.grafana's own "Fail when grafana admin user
    # isn't set" task.
    private def self.defined?(vars : Hash(String, JSON::Any), var_name : String) : Bool
      resolved =
        if var_name.includes?(".") || var_name.includes?("[")
          VariableSubstitutor::VariableLookup.new(vars).resolve(var_name)
        else
          vars[var_name]?
        end
      return false unless resolved

      # A variable whose own stored value is `{{ }}` text bottoming out
      # at a name set nowhere is undefined, not defined - the same
      # distinction `CrinjaRenderer.convert_var` draws for the Crinja
      # side (see its comment for the full case). This evaluator is
      # independent of that one (see CLAUDE.md - the two Jinja
      # evaluators share no implementation, so this bug class has to be
      # found and fixed once in each), so `when: phpmyadmin_mysql_
      # password is defined` answered True here even after the Crinja
      # side started answering False, and any role gating a
      # set-the-real-default task on `is undefined` skipped it.
      if (raw = resolved.raw).is_a?(String) && VarSubstitutor.new(vars: vars).unresolvable_template?(raw)
        return false
      end

      true
    end

    # Audit pass (2026-08-11, following the ansible-vault/prometheus/
    # grafana rounds finding 5 independent copies of this exact bug):
    # re-renders *value* if its raw form is still a String containing
    # `{{` - real Ansible's recursive re-templating applied to whatever
    # a caller already resolved, rather than duplicating the "strip one
    # {{ }} layer and re-run through ExpressionEvaluator" logic at every
    # call site. Shared within this file only (ComparisonEvaluator and
    # FilterEngine keep their own copies rather than a cross-class
    # shared helper, matching how this bug class has always been fixed
    # here - narrowly, per call site, not via a bigger refactor).
    private def self.rerender_if_templated(vars : Hash(String, JSON::Any), value : JSON::Any?) : JSON::Any?
      return value unless value
      return value unless (raw = value.raw).is_a?(String) && (raw.includes?("{{") || raw.includes?("{%") || raw.includes?("{#"))

      # Same "{%"/"{#" block-tag gap as VariableLookup's own identical
      # copy of this helper (variable_lookup.cr) - see there for the
      # full rationale.
      if raw.includes?("{%") || raw.includes?("{#")
        rendered = VariableSubstitutor::CrinjaRenderer.new(vars).render(raw)
        return (JSON.parse(rendered) rescue nil) || JSON::Any.new(rendered)
      end

      inner = raw.strip
      inner = inner[2..-3].strip if inner.starts_with?("{{") && inner.ends_with?("}}")
      rendered = VariableSubstitutor::ExpressionEvaluator.new(vars).evaluate(inner)
      (JSON.parse(rendered) rescue nil) || JSON::Any.new(rendered)
    end

    # Resolves *var_name* (a bare or dotted variable reference, the same
    # grammar #evaluate_value's own dotted-access branch handles) and
    # checks whether its real JSON type matches "mapping" (Hash) or
    # "sequence" (Array only, not a bare String). Found in the audit
    # pass above, not from a real-host round: a variable whose own raw
    # value is itself unrendered Jinja (e.g. a role default computed
    # from another default) would resolve to a String here, always
    # failing `is mapping`/`is sequence` regardless of what it actually
    # renders to.
    # Resolves an `is subset(...)`/`is superset(...)`/`is contains(...)`
    # operand (either side - the value being tested, or the argument
    # inside the parens) to its real JSON::Any structure - handles a
    # quoted literal, a filter-chain expression (`|`, same
    # ExpressionEvaluator delegation #matches_type_test? uses), and a
    # bare/dotted/indexed variable reference. Does NOT parse a `[...]`
    # list literal (`is subset(['a', 'b'])`) - same pre-existing gap
    # FilterEngine's own union filter has (see its comment); real
    # playbooks almost always pass a variable here instead.
    private def self.resolve_test_operand(expr : String, vars : Hash(String, JSON::Any)) : JSON::Any?
      expr = expr.strip
      if (expr.starts_with?('"') && expr.ends_with?('"')) || (expr.starts_with?('\'') && expr.ends_with?('\''))
        return JSON::Any.new(expr[1..-2])
      end

      if expr.includes?("|")
        rendered = VariableSubstitutor::ExpressionEvaluator.new(vars).evaluate(expr)
        return (JSON.parse(rendered) rescue nil) || JSON::Any.new(rendered)
      end

      value = if expr.includes?(".") || expr.includes?("[")
                VariableSubstitutor::VariableLookup.new(vars).resolve(expr)
              else
                vars[expr]?
              end
      rerender_if_templated(vars, value)
    end

    # 'is exists'/'is file'/'is directory'/'is link'/'is link_exists' -
    # `path` resolves via #resolve_test_operand (same filter-chain/
    # dotted/variable handling every other test here uses).
    private def self.matches_path_test?(vars : Hash(String, JSON::Any), var_expr : String, test_name : String) : Bool
      path = resolve_test_operand(var_expr, vars).try(&.as_s?)
      return false unless path

      case test_name
      when "exists"
        File.exists?(path)
      when "file"
        File.file?(path)
      when "directory"
        Dir.exists?(path)
      when "link"
        File.symlink?(path)
      else # "link_exists" - real os.path.lexists: true even for a broken symlink, unlike "exists" above
        !!File.info?(path, follow_symlinks: false)
      end
    end

    private def self.mount_point?(vars : Hash(String, JSON::Any), var_expr : String) : Bool
      path = resolve_test_operand(var_expr, vars).try(&.as_s?)
      return false unless path
      Process.run("mountpoint", ["-q", path]).success? rescue false
    end

    private def self.matches_vault_test?(vars : Hash(String, JSON::Any), var_expr : String, test_name : String) : Bool
      value = resolve_test_operand(var_expr, vars).try(&.as_s?)
      return false unless value

      content = test_name == "vaulted_file" ? (File.read(value) rescue nil) : value
      content ? Vault.encrypted?(content) : false
    end

    URN_PATTERN = /^urn:[a-zA-Z0-9][a-zA-Z0-9-]{0,31}:[a-zA-Z0-9()+,\-.:=@;$_!*'%\/?#]+$/i

    private def self.matches_urn?(vars : Hash(String, JSON::Any), var_expr : String) : Bool
      value = resolve_test_operand(var_expr, vars).try(&.as_s?)
      !!(value && URN_PATTERN.matches?(value))
    end

    # `started`/`finished`/`timedout`/`unreachable` fields are a plain
    # INTEGER 0/1 in real Ansible's own async_status/wait_for_connection
    # result shape (and this codebase's own plugins/async_status.cr) -
    # not a JSON bool like #result_field's own `.as_bool?` check
    # assumes. Truthy for either a real bool `true` or a non-zero
    # number, matching real Python truthiness for the values these
    # fields actually take.
    private def self.async_field_truthy?(vars : Hash(String, JSON::Any), var_name : String, field : String) : Bool
      result = vars[var_name]?
      return false unless result
      field_value = result[field]?
      return false unless field_value

      case raw = field_value.raw
      when Bool  then raw
      when Int64 then raw != 0
      else            false
      end
    end

    # Quote-aware whitespace normalization for condition strings - see
    # evaluate's own comment for the YAML folded-scalar motivation.
    # Whitespace INSIDE single/double-quoted string literals is preserved
    # byte-for-byte (a comparison against a multi-word literal is
    # unaffected); only inter-token whitespace runs are collapsed to one
    # space. Backslash escapes inside quotes don't terminate the quote.
    private def self.normalize_condition_whitespace(condition : String) : String
      return condition unless condition.includes?('\n') || condition.includes?('\t') || condition.includes?("  ")

      String.build do |buf|
        in_quote = false
        quote_char = ' '
        escaped = false
        pending_space = false
        condition.each_char do |ch_blk|
          if in_quote
            buf << ch_blk
            if escaped
              escaped = false
            elsif ch_blk == '\\'
              escaped = true
            elsif ch_blk == quote_char
              in_quote = false
            end
            next
          end
          if ch_blk == '"' || ch_blk == '\''
            buf << ' ' if pending_space
            pending_space = false
            in_quote = true
            quote_char = ch_blk
            buf << ch_blk
          elsif ch_blk.whitespace?
            pending_space = true
          else
            buf << ' ' if pending_space
            pending_space = false
            buf << ch_blk
          end
        end
      end
    end

    private def self.matches_type_test?(vars : Hash(String, JSON::Any), var_name : String, test_name : String) : Bool
      # var_name may itself be a filter-chain expression, not a bare
      # variable reference - e.g. `java_version | int is number`
      # (robertdebock.java's own assert.yml, round 45). The bare
      # hash/dotted-path lookup below has no notion of a `|` filter
      # pipe at all, so `vars["java_version | int"]?` (the literal
      # string, pipe included) always misses - undefined, always
      # failing the type test regardless of what the filtered value
      # actually is. Route anything containing a filter pipe through
      # ExpressionEvaluator instead, the same "evaluate then
      # JSON.parse the result" pattern rerender_if_templated already
      # uses just above for re-rendering an already-resolved value.
      if var_name.includes?("|")
        # Route through CrinjaRenderer#evaluate_value! (structured, not
        # render-then-parse): a filter chain whose final value is Python
        # None - regex_search with no match, as of the round-189 fix -
        # must reach the type test as JSON null, not as the empty STRING
        # the String-rendering bridge turned it into (JSON.parse("")
        # raised, the rescue substituted JSON::Any.new(""), and
        # `(x | regex_search(...)) is not none` was TRUE for a no-match,
        # failing a succeeding task - buluma.cve_2024_3094's own
        # list-form failed_when). evaluate_value! returns nil for
        # UNDEFINED (a genuinely missing variable), which falls back to
        # the old render-then-parse path below for that case.
        structured = begin
          VariableSubstitutor::CrinjaRenderer.new(vars).evaluate_value!(var_name)
        rescue
          nil
        end
        if structured
          value = structured
        else
          rendered = VariableSubstitutor::ExpressionEvaluator.new(vars).evaluate(var_name)
          value = (JSON.parse(rendered) rescue nil) || JSON::Any.new(rendered)
        end
      else
        value = if var_name.includes?(".") || var_name.includes?("[")
                  VariableSubstitutor::VariableLookup.new(vars).resolve(var_name)
                else
                  vars[var_name]?
                end
        value = rerender_if_templated(vars, value)
      end
      return false unless value

      case test_name
      when "mapping"
        value.raw.is_a?(Hash)
      when "sequence"
        value.raw.is_a?(Array)
      when "boolean"
        value.raw.is_a?(Bool)
      when "number", "integer", "float"
        # Jinja2's own `number` matches both int and float; `integer`/
        # `float` are narrower Jinja2 tests for just one or the other.
        # JSON::Any stores whole numbers as Int64 and fractional ones as
        # Float64, matching Ansible's own YAML/JSON type inference.
        case test_name
        when "integer"
          value.raw.is_a?(Int64)
        when "float"
          value.raw.is_a?(Float64)
        else
          value.raw.is_a?(Int64) || value.raw.is_a?(Float64)
        end
      when "string"
        value.raw.is_a?(String)
      when "iterable"
        value.raw.is_a?(Array) || value.raw.is_a?(Hash) || value.raw.is_a?(String)
      when "none"
        # Jinja2's `none`/`null` test - real Python `None`/YAML `null`,
        # distinct from "undefined" (a key that isn't present at all).
        # Found via robertdebock.mysql's own `mysql_bind_address is not
        # none` assert (round 18) - entirely unimplemented before, same
        # failure mode every other type test here originally had: fell
        # through to #evaluate_truthiness, always false, so `is not none`
        # on a real, correctly-set string default failed the assert.
        value.raw.nil?
      else
        false
      end
    end

    private def self.evaluate_version_test(left_expr : String, compare_to_expr : String, operator_expr : String, vars : Hash(String, JSON::Any), raise_undefined : Bool = false) : Bool
      left = evaluate_value(left_expr.strip, vars, raise_undefined).to_s
      # The compare-to argument may be a VARIABLE, not just a quoted
      # literal - `x is version(role_min_version, '>=')` is the standard
      # version-gate idiom in real roles. Previously this was only
      # unquoted, so a variable argument stayed the literal string
      # "role_min_version" and got version-compared as garbage (which,
      # depending on the name, silently produced either answer).
      # Live-verified against ansible-core 2.19.12 (round173): a var
      # compare-to resolves and compares exactly like the equivalent
      # literal. The operator argument is left as a literal - real
      # playbooks always spell it inline ('>=', 'ge', ...), and
      # resolving it would make an unquoted `ge` look like a variable.
      compare_to_raw = compare_to_expr.strip
      compare_to = if quoted_literal?(compare_to_raw)
                     unquote_literal(compare_to_raw)
                   else
                     evaluate_value(compare_to_raw, vars, raise_undefined).to_s
                   end
      operator = unquote_literal(operator_expr.strip)
      cmp = compare_versions(left, compare_to)

      case operator
      when "==", "="
        cmp == 0
      when "!="
        cmp != 0
      when "<", "lt"
        cmp < 0
      when "<=", "le"
        cmp <= 0
      when ">", "gt"
        cmp > 0
      when ">=", "ge"
        cmp >= 0
      else
        false
      end
    end

    private def self.quoted_literal?(expr : String) : Bool
      (expr.starts_with?('\'') && expr.ends_with?('\'')) ||
        (expr.starts_with?('"') && expr.ends_with?('"'))
    end

    private def self.unquote_literal(expr : String) : String
      if (expr.starts_with?('\'') && expr.ends_with?('\'')) || (expr.starts_with?('"') && expr.ends_with?('"'))
        expr[1..-2]
      else
        expr
      end
    end

    # Splits a version string into its numeric components (`"8.9p1"` ->
    # `[8, 9, 1]`, ignoring the non-digit "p" separator) and compares two
    # such lists lexicographically, treating a missing trailing
    # component as 0. Duplicated (not shared) from JinjaFilters.
    # compare_versions in jinja_filters.cr - that file requires "crinja"
    # for its own Value/filter registration machinery, too heavy a
    # dependency to pull into this evaluator (used by every `when:`
    # regardless of whether any template rendering is even involved) for
    # ten lines of arithmetic.
    private def self.compare_versions(a : String, b : String) : Int32
      a_parts = a.scan(REGEX_DIGITS).map(&.[0].to_i)
      b_parts = b.scan(REGEX_DIGITS).map(&.[0].to_i)
      [a_parts.size, b_parts.size].max.times do |i|
        a_val = a_parts[i]? || 0
        b_val = b_parts[i]? || 0
        cmp = a_val <=> b_val
        return cmp unless cmp == 0
      end
      0
    end

    private def self.evaluate_in(condition : String, vars : Hash(String, JSON::Any), raise_undefined : Bool = false) : Bool
      # #split_by_operator (already used above for and/or) is quote- and
      # paren-depth-aware; a plain `condition.split(" in ", 2)` is not,
      # so a quoted literal that happens to contain the word "in" as
      # its own word - `'already in peer list' not in probe2.stdout`,
      # a real geerlingguy.glusterfs-cluster peer-probe idempotency
      # check (`gluster peer probe` prints exactly that phrase for an
      # already-probed peer) - split at the FIRST " in " it found,
      # which was the one INSIDE the quoted string ("already[ in ]peer
      # list"), not the real `in` operator - producing a nonsensical
      # item/container pair and silently evaluating changed_when as
      # true on every single run, never converging.
      parts = split_by_operator(condition, " in ")
      return false if parts.size < 2

      item = evaluate_value(parts[0].strip, vars, raise_undefined)
      container = evaluate_value(parts[1..].join(" in ").strip, vars, raise_undefined)

      # Check if item is in container (string or array). Every array
      # value this evaluator ever produces - whether from a literal
      # `[0, 3, 4]` or a real variable - is Array(String), since
      # evaluate_value/json_any_to_value both stringify every element
      # (Array(String) is the only array shape this method's own return
      # type allows). `item` itself, though, keeps its real type (an
      # Int64 for something like a registered command's `.rc`) - so
      # comparing it against the container unstringified
      # (`container.includes?(item)`) compared an Int64 against String
      # elements, which Crystal's `==` never treats as equal, so
      # membership always came back false. `failed_when: result.rc not
      # in [0, 3, 4]` (openstack.ansible-hardening's own kdump-service
      # check, "not in" is `!evaluate_in`) therefore always evaluated
      # true regardless of the real rc, hard-failing a task real
      # Ansible treats as a legitimate rc=3/4 success and halting the
      # rest of the play for that host.
      if container.is_a?(String)
        container.includes?(item.to_s)
      elsif container.is_a?(Array)
        container.includes?(item.to_s)
      else
        false
      end
    end

    # Real Ansible's own escape hatch for the strict-boolean-conditional
    # rule it introduced in 2.19; this project's benchmark harness has
    # set it on the real-Ansible side since round 20, so honouring it
    # here keeps both engines comparable under the same environment.
    def self.allow_broken_conditionals? : Bool
      value = ENV["ANSIBLE_ALLOW_BROKEN_CONDITIONALS"]?
      return false unless value
      ["true", "yes", "1", "on"].includes?(value.strip.downcase)
    end

    # Evaluate truthiness of a value
    private def self.evaluate_truthiness(condition : String, vars : Hash(String, JSON::Any), strict : Bool = false, raise_undefined : Bool = false) : Bool
      # Real Ansible/Python `bool([])` and `bool({})` are both False -
      # but #evaluate_value's own return union (String | Int64 | Bool |
      # Nil | Array(String)) has no Hash case at all (an empty Hash's
      # own #to_s, "{}", is a non-empty STRING - always truthy under the
      # String case below) and every Array collapses to Array(String)
      # with no truthiness case in the `case` below either (silently
      # falling through to the unconditional `else -> true`). Checked
      # directly against the resolved JSON::Any (VariableLookup#resolve,
      # the same simple/dotted/indexed resolver {{ }} substitution
      # already uses) before ever going through that lossy conversion.
      # Found in the audit pass following the Crinja `Value#truthy?`
      # fix (same bug class - empty-container truthiness - in a
      # completely separate, hand-rolled evaluator this codebase also
      # maintains): `when: my_list` with `my_list: []` (or `my_dict:
      # {}`) always ran the task, verified directly against real
      # Python's own `bool([])`/`bool({})`.
      if resolved = VariableSubstitutor::VariableLookup.new(vars).resolve(condition)
        case raw = resolved.raw
        when Hash
          if strict && !allow_broken_conditionals?
            raise ConditionalBooleanError.new(
              "Conditional result (#{raw.empty? ? "False" : "True"}) was derived from value of type 'dict'. " \
              "Conditionals must have a boolean result.")
          end
          return !raw.empty?
        when Array
          if strict && !allow_broken_conditionals?
            raise ConditionalBooleanError.new(
              "Conditional result (#{raw.empty? ? "False" : "True"}) was derived from value of type 'list'. " \
              "Conditionals must have a boolean result.")
          end
          return !raw.empty?
        end
      end

      value = evaluate_value(condition, vars, raise_undefined)

      # ansible-core 2.19 requires a conditional to end in a REAL
      # boolean: anything else fails the task with "Conditional result
      # (X) was derived from value of type 'T'. Conditionals must have a
      # boolean result." - even the very common bare-truthy-variable
      # idiom (`when: some_string`, `when: some_int`). Differentialed
      # over six shapes against 2.19.4: only a genuine bool passes.
      #
      # `ANSIBLE_ALLOW_BROKEN_CONDITIONALS` turns it back off, exactly as
      # it does there - which is also what keeps this project's own
      # benchmark harness comparable, since it has set that variable for
      # the real-Ansible side since round 20.
      if strict && !allow_broken_conditionals?
        case raw_value = value
        when Bool
          # The only shape real Ansible accepts.
        when String
          # "undefined" is this codebase's own unresolved-lookup
          # sentinel, reported below as the NoneType it stands for.
          unless raw_value == "undefined"
            raise ConditionalBooleanError.new(
              "Conditional result (#{raw_value.empty? ? "False" : "True"}) was derived from value of type 'str'. " \
              "Conditionals must have a boolean result.")
          end
        when Int32, Int64
          raise ConditionalBooleanError.new(
            "Conditional result (#{raw_value == 0 ? "False" : "True"}) was derived from value of type 'int'. " \
            "Conditionals must have a boolean result.")
        when Array
          raise ConditionalBooleanError.new(
            "Conditional result (#{raw_value.empty? ? "False" : "True"}) was derived from value of type 'list'. " \
            "Conditionals must have a boolean result.")
        end
      end

      case value
      when Bool
        value
      when String
        # "undefined" - this codebase's own sentinel for an unresolved
        # lookup/filter result (e.g. `regex_search()`'s own "no match"
        # return, per its own doc comment) - must be FALSY here, matching
        # real Jinja2's `Undefined`/Python's `None` (`bool(None)` is
        # False). Found via robertdebock.mount's own handler condition
        # `when: mount_requests | regex_search("swap")`: no "swap"
        # anywhere in `mount_requests` correctly produced the "undefined"
        # sentinel, but this String case only special-cased "false"/
        # "False" - a non-empty, not-literally-"false" string is truthy
        # by the general rule, so the handler fired unconditionally
        # regardless of whether `mount_requests` actually mentioned swap.
        if strict && value == "undefined"
          raise ConditionalBooleanError.new(
            "Conditional result (False) was derived from value of type 'NoneType'. " \
            "Conditionals must have a boolean result.")
        end
        !value.empty? && value != "false" && value != "False" && value != "undefined"
      when Int32, Int64
        value != 0
      when Nil
        raise ConditionalBooleanError.new(
          "Conditional result (False) was derived from value of type 'NoneType'. " \
          "Conditionals must have a boolean result.") if strict
        false
      else
        true
      end
    end

    # Evaluate a value (variable lookup or literal)
    private def self.evaluate_value(expr : String, vars : Hash(String, JSON::Any), raise_undefined : Bool = false) : String | Int64 | Bool | Nil | Array(String)
      expr = expr.strip

      # Handle quoted strings
      if (expr.starts_with?('"') && expr.ends_with?('"')) ||
         (expr.starts_with?('\'') && expr.ends_with?('\''))
        return expr[1..-2]
      end

      # Handle booleans
      if expr == "true" || expr == "True"
        return true
      elsif expr == "false" || expr == "False"
        return false
      end

      # The Python/Jinja2 `None`/`none` literal - a real keyword, not a
      # variable reference, so it must be recognized BEFORE the
      # raise_undefined check below or a condition as ordinary as `myvar
      # == None` would spuriously raise "'None' is undefined" (the bare-
      # word grammar this literal happens to share with a real variable
      # name is otherwise indistinguishable). Previously this had no
      # explicit case at all - it fell through to the plain "undefined
      # variable" lookup below, which returned `nil` for the same reason
      # a genuinely-missing variable did (there's essentially never a
      # real variable actually named `None`/`none`) - accidentally
      # correct for comparisons, but only because raise_undefined didn't
      # exist yet to tell the two apart.
      return nil if expr == "None" || expr == "none"

      # Handle numbers
      if int_val = expr.to_i64?
        return int_val
      end

      # A bare float literal (`5.1`) on one side of a comparison, e.g.
      # `when: zsh_version.stdout | float < 5.1` (buluma.p10k's own
      # minimum-version gate). This method's return union has no Float64
      # case, so the literal is returned as a String instead - safe here
      # because #compare_values already falls back to a numeric parse of
      # `to_s` for either side, so a String holding "5.1" compares
      # correctly against a real Int64/Float-rendered-as-String operand.
      # Previously fell through to the dotted-path guard just below,
      # which only excludes float literals from the DOTTED lookup branch
      # (correctly) but doesn't itself resolve them - execution continued
      # to the plain "vars.has_key?" lookup, found no variable literally
      # named "5.1", and raised "'5.1' is undefined" under raise_undefined
      # - a real bug, not a hypothetical one: found live via
      # buluma.p10k's own ZSH-version check, which real Ansible evaluates
      # fine (integer literals already worked; only non-integer numeric
      # literals were missing this case).
      return expr if expr.to_f64?

      # A filter chain (`mylist | length > 0`, or a bare `when: mylist |
      # length` truthiness check), a parenthesized sub-expression
      # (possibly with trailing dotted/indexed access - dev-sec
      # os_hardening's own password-ageing assert: `( expiry_date.stdout |
      # trim | to_datetime(...) - ansible_facts.date_time.date |
      # to_datetime(...) ).days == 60`), or a top-level `-`/`*`/`/`
      # arithmetic operator - delegates to ExpressionEvaluator, the same
      # evaluator {{ }} substitution uses and the only one of the two
      # that understands nested filter calls inside a parenthesized
      # operand, datetime subtraction, `*`/`/`/`//` arithmetic, and
      # dotted access on a sub-expression's *result* (not just on a
      # plain variable). Previously this module had its own separate,
      # far less capable filter-chain-only handling here, which - among
      # other gaps - had no concept of `|` nested inside an unclosed
      # paren at all, so a condition shaped like the one above always
      # evaluated to undefined. `*`/`/` specifically were missing from
      # this guard even after ExpressionEvaluator itself gained
      # arithmetic support - found via geerlingguy.swap's own
      # check-size.yml doing its own `{{ stat.size / 1024 / 1024 }}`
      # comparison as a bare `when:`/`assert:`-style value, not just
      # inside `{{ }}` template interpolation. A bare `(` anywhere (not
      # just a leading one) also needs routing here - real bug found
      # benchmarking robertdebock.squid (round 48): its own assert.yml
      # has `squid_cache_dir.split(" ")[0] in [...]`, a Python-style
      # `.split(...)` METHOD call (not a `| split` filter) followed by
      # indexing. `{{ squid_cache_dir.split(" ")[0] }}` alone already
      # rendered correctly through ExpressionEvaluator (the `{{ }}`
      # path), but this bare (unwrapped) `assert: that:` condition fell
      # through to the naive dotted/indexed-access splitter below
      # instead, which has no concept of a parenthesized method call at
      # all - it just tried (and failed) to treat `split(" ")` as a
      # literal, nonexistent hash key, always undefined.
      if expr.includes?("|") || expr.includes?("(") || expr.includes?(" - ") || expr.includes?("~") ||
         expr.includes?("*") || expr.includes?("/")
        # A filter chain fed by a genuinely undefined variable is fatal
        # for a `when:`/`assert:` in real Ansible exactly as a bare
        # undefined reference is ("Error while evaluating conditional:
        # 'nope' is undefined" for `when: nope | length > 0`, verified
        # against ansible-core 2.19.4) - the strict path below only ever
        # reached the BARE-lookup branches, so anything with a filter in
        # it stayed lenient and silently skipped the task. Same
        # allowlist-driven check the templating and loop-source entry
        # points use; `nope | default(...)` stays lenient, as it must.
        if raise_undefined && (undefined_name = CrystalPlay.undefined_filter_chain_source(expr, vars))
          raise UndefinedVariableError.new("'#{undefined_name}' is undefined")
        end

        evaluator = VariableSubstitutor::ExpressionEvaluator.new(vars)
        rendered = evaluator.evaluate(expr)

        # #evaluate's own output is Python/Jinja2-repr text ("True"/
        # "False", capitalized - matching what a real `{{ }}` span
        # renders), not JSON - so a filter chain that resolves to a
        # boolean (`x | bool`, `x is defined`, ...) must be recognized
        # here BEFORE the JSON.parse fallback below, or it silently
        # becomes the STRING "True"/"False" instead of a real Bool.
        # Found via andrewrothstein.docker_engine's own reconfigure
        # handler: `when: [docker_engine_manage_service | bool,
        # docker_engine_config_reload | bool, ...]` - JSON.parse("True")
        # raises (not valid JSON), so the fallback wrapped the literal
        # text "True" in a JSON::Any::String, and the strict boolean
        # check two callers up then hard-failed the handler with
        # "Conditional result (True) was derived from value of type
        # 'str'" even though every operand really was boolean - a
        # regression introduced by 0.9.612's strict-conditional check
        # tightening what used to be silently-accepted truthy text.
        return true if rendered == "True"
        return false if rendered == "False"

        parsed = (JSON.parse(rendered) rescue nil)
        return json_any_to_value(parsed || JSON::Any.new(rendered))
      end

      # Handle the empty-dict literal (`when: my_dict == {}`) - a dict
      # variable's own left-hand resolution falls through to
      # #json_any_to_value's `else: value.to_s` branch (this function's
      # return type has no Hash case at all, so a Hash raw value is
      # stringified to compact JSON, e.g. `"{}"` for an empty Hash - see
      # the `check_json_any.cr` probe that verified `JSON::Any.new(Hash
      # (String, JSON::Any).new).to_s == "{}"` exactly). Without this
      # branch, the literal `{}` on the right side fell all the way
      # through to "not a variable" -> nil, so `dict_var == {}` compared
      # a String against nil and was always false - found via
      # prometheus.prometheus.alertmanager's own preflight check `when:
      # alertmanager_route == {}` (alertmanager_route defaults to `{}`),
      # which should fail the play (no route configured) but instead
      # silently skipped. Only the empty-literal shape is special-cased,
      # not general dict-literal parsing (`{'a': 1}` in a `when:` is not
      # a pattern seen in any role benchmarked so far).
      return "{}" if expr == "{}"

      # Handle arrays (simple list syntax). An empty literal `[]`'s inner
      # text is "", and `"".split(',')` returns `[""]` (one empty-string
      # element), not `[]` - without this guard, `mylist != []` compared
      # a real empty array against a bogus 1-element array and always
      # evaluated true (and `mylist == []` always evaluated false),
      # found via willshersystems.sshd's own `when: sshd_trusted_user_ca_
      # keys_list != []` guard always passing regardless of the real
      # (empty-by-default) list.
      if expr.starts_with?('[') && expr.ends_with?(']')
        inner = expr[1..-2].strip
        return [] of String if inner.empty?

        items = inner.split(',').map(&.strip)
        return items.map { |item|
          val = evaluate_value(item, vars, raise_undefined)
          val.is_a?(String) ? val : val.to_s
        }
      end

      # Dotted and/or indexed variable access (e.g. result.rc,
      # stat_result.stat.exists, ansible_facts.getent_passwd[item][1] -
      # dev-sec os_hardening's own way of pulling a getent entry's UID
      # field, gating every account-management task in that role) -
      # previously only the {{ }}-wrapped ComparisonEvaluator path
      # supported this at all, and even the dotted-only case here never
      # understood a trailing `[...]` (treating "getent_passwd[item][1]"
      # as one literal, nonexistent hash key). Delegates to
      # VariableLookup#resolve, the same chained dotted+indexed resolver
      # {{ }} substitution uses. Guarded against float literals ("1.5")
      # also containing a "." - those aren't variable paths, and the
      # first segment of a real one ("result") won't itself parse as a
      # float.
      if (expr.includes?(".") || expr.includes?("[")) && !expr.to_f64?
        parts = expr.split(/[.\[]/)
        if !parts.empty? && vars.has_key?(parts[0])
          # Same recursive-re-templating gap as the bare "Variable
          # lookup" case just below (which already has this fix) -
          # found in the audit pass, not a real-host round: a dotted
          # path (`result.stdout`, `x.y`) whose resolved value's own
          # raw form is itself still unrendered Jinja was returned
          # as-is, un-rendered.
          resolved = rerender_if_templated(vars, VariableSubstitutor::VariableLookup.new(vars).resolve(expr))
          return json_any_to_value(resolved) if resolved
          raise UndefinedVariableError.new("'#{expr}' is undefined") if raise_undefined
          return nil
        end
      end

      # Variable lookup
      if vars.has_key?(expr)
        value = vars[expr]

        # Real Ansible's recursive re-templating: a variable whose own
        # raw value is itself unrendered Jinja (a role default defined in
        # terms of another default, e.g. ansible-community.ansible-vault's
        # `vault_enterprise: "{{ lookup('env', 'VAULT_ENTERPRISE') |
        # default(false, true) }}"`) must be evaluated before its
        # truthiness is checked - otherwise the raw, non-empty template
        # text itself is treated as a truthy string, so `vault_enterprise`
        # always evaluated true regardless of the real (false) default.
        if (raw = value.raw).is_a?(String) && raw.includes?("{{")
          evaluator = VariableSubstitutor::ExpressionEvaluator.new(vars)
          inner = raw.strip
          inner = inner[2..-3].strip if inner.starts_with?("{{") && inner.ends_with?("}}")
          rendered = evaluator.evaluate(inner)
          parsed = (JSON.parse(rendered) rescue nil)
          json_any_to_value(parsed || JSON::Any.new(rendered))
        else
          json_any_to_value(value)
        end
      else
        # Undefined variable - real Ansible raises here (see
        # UndefinedVariableError above) when this evaluate_value call
        # ultimately traces back to a task-level `when:` (raise_undefined
        # true); every other caller keeps the long-standing lenient nil.
        raise UndefinedVariableError.new("'#{expr}' is undefined") if raise_undefined
        nil
      end
    end

    # Resolves a simple, dotted, and/or indexed expression (the head of a
    # filter chain, e.g. "mylist", "result.stdout" in "result.stdout |
    # trim", or "ansible_facts.getent_passwd[item][1]" in "...|int") to
    # its raw JSON::Any value - delegates to VariableLookup#resolve, the
    # same chained dotted+indexed resolver {{ }} substitution uses.
    private def self.resolve_json(expr : String, vars : Hash(String, JSON::Any)) : JSON::Any?
      # Same recursive-re-templating gap as #evaluate_value's own two
      # copies above - found in the audit pass, not a real-host round.
      rerender_if_templated(vars, VariableSubstitutor::VariableLookup.new(vars).resolve(expr.strip))
    end

    # Converts a resolved JSON::Any into the same union evaluate_value
    # already returns for a bare variable lookup.
    private def self.json_any_to_value(value : JSON::Any) : String | Int64 | Bool | Nil | Array(String)
      case value.raw
      when String
        value.as_s
      when Int64, Int32
        # Same overflow bug class as VariableLookup#format_value: `#as_i`
        # always narrows through Int32 first, raising `OverflowError` for
        # any real Int64 value outside Int32's range (byte-scale disk/
        # memory facts) even though the final target type here IS Int64.
        # `value.raw.as(Int64 | Int32).to_i64` reads the correctly-typed
        # union member directly, no narrowing round-trip.
        value.raw.as(Int64 | Int32).to_i64
      when Float64
        value.as_f.to_s
      when Bool
        value.as_bool
      when Nil
        nil
      when Array
        value.as_a.map(&.to_s)
      else
        value.to_s
      end
    end

    # Compare two values (for <, >, <=, >=)
    # `==`/`!=`: a raw match first, then a numeric-string fallback - see
    # ComparisonEvaluator#values_equal? (the {{ }}-side counterpart to
    # this bare when:/assert:-condition evaluator) for why: a value that
    # went through a filter chain/parenthesized sub-expression may come
    # back as a real Int64 while the other side is a quoted string
    # literal (or vice versa) purely as an artifact of this codebase's
    # string-heavy evaluation pipeline, not because the two values are
    # actually different.
    private def self.values_equal?(left : String | Int64 | Bool | Nil | Array(String), right : String | Int64 | Bool | Nil | Array(String)) : Bool
      return true if left == right

      left_num = numeric_or_nil(left)
      right_num = numeric_or_nil(right)
      !left_num.nil? && !right_num.nil? && left_num == right_num
    end

    private def self.numeric_or_nil(value : String | Int64 | Bool | Nil | Array(String)) : Float64?
      case value
      when Int64  then value.to_f64
      when String then value.to_f64?
      else             nil
      end
    end

    private def self.compare_values(left : String | Int64 | Bool | Nil | Array(String),
                                    right : String | Int64 | Bool | Nil | Array(String)) : Int32
      # Try numeric comparison first
      if left.is_a?(Int64) && right.is_a?(Int64)
        return left <=> right
      end

      # Try to parse as numbers
      if left_num = left.to_s.to_i64?
        if right_num = right.to_s.to_i64?
          return left_num <=> right_num
        end
      end

      # Neither side parsed as an integer - try float (`zsh_version.stdout
      # | float < 5.1`: the left side is a real Float64-valued string from
      # the `float` filter, the right a bare float literal). Checked only
      # after the integer attempt above so two genuine integers still
      # compare via Int64 <=> (avoids any float-precision surprise on
      # large values) exactly as before this case was added.
      left_f = left.to_s.to_f64?
      right_f = right.to_s.to_f64?
      if left_f && right_f
        # Float64#<=> returns Int32 | Nil (nil only for a NaN operand,
        # which a real version/numeric literal from a playbook never is)
        # - the `|| 0` is unreachable in practice, just satisfying the
        # method's declared Int32 return type.
        return (left_f <=> right_f) || 0
      end

      # Fall back to string comparison
      left.to_s <=> right.to_s
    end
  end
end
