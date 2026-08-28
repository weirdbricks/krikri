require "json"
require "./variable_substitutor/expression_evaluator"
require "./variable_substitutor/comparison_evaluator"
require "./variable_substitutor/filter_engine"
require "./variable_substitutor/array_slicer"
require "./variable_substitutor/variable_lookup"
require "./variable_substitutor/crinja_renderer"
require "./variable_substitutor/lazy_crinja_context"

module CrystalPlay
  # Sentinel a rendered param value is compared against to detect real
  # Ansible's `omit` magic variable (`{{ item.proto | default(omit) }}` -
  # konstruktoid-hardening's "Allow outgoing specified ports" task uses
  # exactly this to drop `proto:` for loop items that don't specify one).
  # Real Ansible's `omit` causes the *parameter itself* to be dropped from
  # the module call entirely, not set to some placeholder value - can't be
  # represented as a plain rendered string, so FilterEngine's `default`
  # resolves a bare `omit` argument to this unique marker instead, and
  # #substitute_task_params (the one place that assembles a task's final
  # param hash) strips any key whose fully-substituted value equals it.
  OMIT_SENTINEL = "__crystal_ansible_omit__"

  # Raised only from #substitute's `strict:` path (module-arg/param
  # finalization - see #substitute_task_params) when a `{{ }}` span whose
  # ENTIRE content is a plain variable reference (`foo`, `foo.bar`,
  # `foo['bar'][0]` - no filters/operators/function calls) resolves to
  # nothing. Real Ansible's Jinja2 templating is strict-undefined by
  # default for module-arg rendering and raises in exactly this shape of
  # case ("'foo' is undefined"); this engine otherwise renders a missing
  # lookup as the literal string "undefined" and continues (a deliberate,
  # pervasive leniency used throughout the rest of the templating/
  # conditional-evaluation code, see ConditionalEvaluator's own comments -
  # NOT changed here). Deliberately narrow: only a *bare* reference is
  # checked here, not any expression using a filter/function/operator -
  # those still go through the lenient evaluator regardless of `strict:`,
  # since this hand-rolled evaluator's own known syntax-coverage gaps
  # (documented throughout expression_evaluator.cr) already fall back to
  # the same "undefined" sentinel for reasons that have nothing to do
  # with the variable genuinely being undefined, and conflating the two
  # would turn an evaluator limitation into a spurious task failure.
  class UndefinedVariableError < Exception
  end

  # Conservative "pure variable reference" shape - letters/digits/
  # underscore, `.field` and `[0]`/`['key']` access only. No spaces,
  # pipes, parens, quotes outside of a bracket index, or keywords - those
  # all indicate a real expression, not a plain lookup, and stay on the
  # lenient path.
  REGEX_BARE_VAR_REF = /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*|\[(?:-?\d+|'[^']*'|"[^"]*")\])*\z/

  # The only filters real Ansible lets a genuinely UNDEFINED value reach
  # without failing the task. Everything else in Jinja2/Ansible raises on
  # `AnsibleUndefined` - differentialed against the local ansible-core
  # 2.19.4 with `msg: "{{ nope | <filter> }}"` over 24 filters
  # (dict2items, items2dict, list, first, join, length, string, bool,
  # int, ternary, flatten, map, select, unique, sort, lower, trim,
  # to_json, combine, count, min, mandatory all FAIL; only these three
  # succeed), so a tolerant ALLOWLIST is the accurate model here, not a
  # denylist of the handful of filters a benchmark round happened to hit.
  UNDEFINED_TOLERANT_FILTERS = Set{"default", "d", "type_debug"}

  # Same identifier-class regex as REGEX_BARE_VAR_REF but anchored for
  # substring matches inside `{% %}` block-tag conditions. The full
  # anchor isn't right for the block-tag use - we need to find every
  # bare reference in the condition, not just ones that span the
  # whole string.
  SCAN_STRICT_BLOCK_TAG_REF = /\b([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*|\[(?:-?\d+|'[^']*'|"[^"]*")\])*)\b/

  # Jinja keywords and tests - identifiers the `{% %}` block-tag
  # strict scan must NEVER flag, even when they appear in a
  # `{% if %}` condition. Includes the basic block keywords
  # (`if`/`else`/`endif`/etc.), the boolean operators (`and`/`or`/
  # `not`/`in`/`is`), the constant literals (`true`/`false`/`none`),
  # the Jinja2 test names that follow `is` (`is defined`, `is
  # mapping`, `is failed`, `is iterable`, etc.), and Ansible's
  # task-result tests (`is changed`/`is failed`/`is success`/etc.).
  # Tuned against the round-194 andrewrothstein.openjdk
  # openjdk_app==`<literal>` shape; `is defined`/`is failed` are
  # the common two that need not flag.
  SCAN_STRICT_BLOCK_TAG_KEYWORDS = Set{
    "if", "elif", "else", "endif", "for", "endfor",
    "set", "endset", "include", "extends", "block",
    "endblock", "macro", "endmacro", "filter", "endfilter",
    "call", "endcall", "in", "is", "not", "and", "or",
    "true", "false", "none", "recursive", "loop", "self",
    "super", "caller", "args", "kwargs", "varargs",
    "import", "from", "as", "with", "without",
    "scoped", "endscoped", "autoescape", "endautoescape",
    "raw", "endraw", "do", "enddo",
    "case", "when", "endcase", "default",
    "applymacro", "endapplymacro",
    "defined", "undefined", "divisibleby",
    "even", "odd", "mapping", "sequence", "number",
    "string", "boolean", "integer", "float",
    "iterable", "callable", "sameas", "lower", "upper",
    "eq", "ne", "lt", "le", "gt", "ge",
    "failed", "changed", "succeeded", "success", "skipped", "reachable",
  }

  # Jinja2/Ansible built-in filter names - a filter invocation never
  # means "look up this identifier as a var". The same allowlist
  # shape as UNDEFINED_TOLERANT_FILTERS but more complete (the
  # tolerant set is only the subset of filters that pass undefined
  # through; this one is the set of filter NAMES the strict
  # block-tag scan must not treat as a var). Includes the
  # `ansible.builtin.X` collection-prefixed forms used in real
  # playbooks (`ansible.builtin.default`, etc.) - stripped of
  # the prefix by the bare-ref regex's own `\.` step, but only if
  # the form is a filter invocation; bare `ansible.builtin.foo` is
  # still a var lookup, so the whole allowlist is needed either
  # way.
  SCAN_STRICT_BLOCK_TAG_BUILTIN_FILTERS = Set{
    "abs", "attr", "batch", "capitalize", "center", "count", "d",
    "default", "dictsort", "e", "escape", "escapejs", "filesizeformat",
    "first", "float", "forceescape", "format", "groupby", "indent",
    "int", "items", "join", "last", "length", "list", "lower",
    "map", "max", "min", "pprint", "random", "reject", "rejectattr",
    "replace", "reverse", "round", "safe", "select", "selectattr",
    "slice", "sort", "string", "striptags", "sum", "title", "tojson",
    "trim", "truncate", "unique", "upper", "urlencode", "urlize",
    "wordcount", "wordwrap", "xmlattr", "as_json", "as_yaml",
    "b64decode", "b64encode", "sha1", "sha256", "md5", "flatten",
    "combine", "items2dict", "dict2items", "to_datetime", "from_json",
    "from_yaml", "to_yaml", "to_nice_yaml", "to_nice_json", "from_csv",
    "regex_search", "regex_findall", "regex_replace", "product",
    "log", "permutations", "combinations", "extract", "type_debug",
    "shuffle", "comment", "password_hash", "b32decode",
    "b32encode", "human_readable", "human_to_bytes", "to_bytes",
    "subelements", "start_with", "end_with", "match", "search",
    "ipaddr", "ipwrap", "bool", "checksum", "shorthash", "hash",
    "mandatory", "match_regex", "search_regex", "ternary",
  }

  # Returns the offending variable name when *expr* is a filter chain
  # whose SOURCE is a genuinely undefined bare variable reference and
  # whose FIRST filter is not one of UNDEFINED_TOLERANT_FILTERS - i.e.
  # exactly the shape real Ansible hard-fails - and nil otherwise.
  #
  # Why this exists (round185, buluma.environment's `loop: "{{
  # environment_list | dict2items }}"`, with no default anywhere in the
  # role): the strict-undefined machinery only ever looked at BARE
  # `{{ var }}` references, so the moment an undefined value flowed
  # through any filter it stopped being strict - and FilterEngine's own
  # `as_hash`/`as_array` helpers independently coerced the missing value
  # to `{}`/`[]` before anything upstream could notice. The task then
  # produced zero loop items and silently no-op'd where real Ansible
  # fails ("dict2items requires a dictionary, got ...AnsibleUndefined").
  #
  # Only the FIRST filter is consulted, which is what real Ansible does
  # too: `x | default([]) | dict2items` is fine (default consumes the
  # undefined - the legitimate, extremely common idiom), while
  # `x | dict2items | default([])` still fails, because dict2items has
  # already raised by the time default is reached.
  #
  # Deliberately narrow in the same spirit as REGEX_BARE_VAR_REF: the
  # source has to be a plain variable reference that is genuinely absent
  # from *vars* (a straight lookup, no evaluation), so none of this
  # evaluator's documented expression-syntax gaps can turn into a
  # spurious task failure here.
  def self.undefined_filter_chain_source(expr : String, vars : Hash(String, JSON::Any)) : String?
    return nil unless expr.includes?('|')

    parts = VariableSubstitutor::FilterEngine.split_chain(expr)
    return nil unless parts.size >= 2

    source = parts[0].strip
    # Same carve-out as raise_if_strict_undefined: `omit` is a magic
    # bareword, not a variable anyone ever sets.
    return nil if source == "omit"
    return nil unless source.matches?(REGEX_BARE_VAR_REF)

    first_filter = parts[1].strip.lchop("ansible.builtin.")
    paren = first_filter.index('(')
    filter_name = (paren ? first_filter[0, paren] : first_filter).strip
    return nil if UNDEFINED_TOLERANT_FILTERS.includes?(filter_name)

    return nil if VariableSubstitutor::VariableLookup.new(vars).resolve(source)
    source
  end

  # A chained-subscript/dot expression that ultimately resolves to
  # nothing (the inner-most lookup misses, the entire expression
  # renders to the literal text "undefined") - `pkg_upgrade_update_
  # cmds[ansible_distribution_major_version]["update"]` on Rocky 9.6,
  # where ansible_distribution_major_version is "9" but the role's
  # vars/RedHat.yml only has keys "7" and "8", is the canonical case
  # found in round-194's andrewrothstein.pkg-upgrade. Used by
  # raise_if_strict_undefined's chained-subscript branch (which has
  # to decide whether the inner expression ultimately renders to
  # "undefined" without itself recursing into substitute_impl). The
  # detection is the same one ExpressionEvaluator's lenient render
  # path uses: just evaluate the expression and check whether the
  # rendered string is exactly "undefined" - the sentinel this
  # codebase hands back from any missing inner-most bare-ref lookup.
  # Doesn't apply to the bare-ref or filter-chain shapes the OTHER
  # raise_if_strict_undefined branches already cover.
  def self.expression_resolves_to_undefined?(expr : String, vars : Hash(String, JSON::Any)) : Bool
    rendered = VariableSubstitutor::ExpressionEvaluator.new(vars).evaluate(expr)
    rendered == "undefined"
  end

  # VariableSubstitutor - Main class for variable substitution
  # Uses modular components from variable_substitutor/ directory
  class VarSubstitutor
    @vars : Hash(String, JSON::Any)
    @host_name : String
    getter vars
    # SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #20 (the 74% slice):
    # the constructor's `vars.dup` was the single largest allocation in
    # the templating path (~74% of per-call bytes per the item-20
    # profile). It's now lazy: `@vars_owned`/`@magic_vars_added` track
    # whether we've actually needed to dup + insert magic vars yet, and
    # `#ensure_owned!` / `#ensure_magic_vars!` trigger only on first
    # mutation/read-of-magic-vars. A `substitute(text)` that returns on
    # the no-placeholder early-exit never dup's @vars at all.
    @facts : Hash(String, JSON::Any)
    @vars_owned : Bool
    @magic_vars_added : Bool
    # Both are built on first use rather than in the constructor. A
    # VarSubstitutor is constructed 2-4x per task per host (when:,
    # execute_task_once, apply_changed_failed_when, delegate_to:), but
    # the overwhelmingly common case is a task whose params contain no
    # placeholders at all - `substitute` returns on the `includes?("{{")`
    # early exit and reaches neither component. Eagerly constructing them
    # meant ~98% of the cost of that case was the constructor, not the
    # substitution: ExpressionEvaluator alone builds four more objects
    # (ComparisonEvaluator, FilterEngine, ArraySlicer, VariableLookup).
    #
    # Behavior-preserving: both hold a reference to the same @vars hash
    # (they never copy it), so building one later observes exactly the
    # same variables it would have seen at construction time.
    @evaluator : VariableSubstitutor::ExpressionEvaluator?
    @renderer : VariableSubstitutor::CrinjaRenderer?

    # Guards the `{%`/`{#` escalation in #substitute against genuine
    # infinite recursion: CrinjaRenderer#prepare_crinja_vars pre-renders
    # any `{{`-containing variable value via a *fresh* VarSubstitutor
    # (see that method's own comment - "no risk of this recursing back
    # into this same render", which held only for a value containing
    # `{{` alone). A value containing BOTH `{{` AND a block tag (`{%`/
    # `{#`) escalates straight to `renderer.render` here, which calls
    # prepare_crinja_vars again on the *same* @vars, which builds
    # *another* fresh VarSubstitutor for the same still-unrendered
    # value, forever - real bug found benchmarking cloudalchemy.
    # grafana's own `grafana_package: "grafana{% if ... %}-rpi{% endif
    # %}{{ (grafana_version != 'latest') | ternary(...) }}"` (vars/
    # debian.yml - unconditional role vars, not a default), which
    # crashed the whole engine with a stack overflow instead of failing
    # one task. `@vars` is fixed for a renderer's lifetime and rendering
    # never yields the fiber (CrinjaRenderer's own shared_env comment),
    # so a single process-wide counter - not a per-instance one, since
    # each recursion level constructs a brand new VarSubstitutor/
    # CrinjaRenderer pair - is the correct guard here.
    @@block_tag_escalation_depth = 0
    MAX_BLOCK_TAG_ESCALATION_DEPTH = 50

    # SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #18: `TaskExecutor`
    # constructs a `VarSubstitutor` from an already-`Hash(String,
    # JSON::Any)` `vars_context` at 28+ call sites - every `when:`,
    # param substitution, `changed_when:`/`failed_when:`, delegate_to:
    # resolution, and (the item's own focus) once per loop iteration.
    # The general `initialize` below exists for callers that may still
    # be handing over mixed `String | JSON::Any` values and needs a
    # per-key `case`/`when` to coerce each one - real, necessary work
    # for THAT input shape, but pure waste when the input is already
    # exactly `Hash(String, JSON::Any)` (every `TaskExecutor` call site,
    # checked directly via `vars_context`'s own declared type), where a
    # plain bulk `Hash#dup` produces an identical result without walking
    # every entry through a type-dispatch branch and rebuilding the hash
    # key-by-key. Still a full `.dup`, not a bare reference - `#add_
    # magic_variables` below mutates `@vars` in place
    # (`inventory_hostname`/`ansible_hostname`/`ansible_host`), so
    # aliasing the caller's own hash would leak that mutation back into
    # it; `.dup` keeps the identical "private copy" semantics the
    # general path already has, just built via one bulk copy instead of
    # N individual inserts.
    def initialize(vars : Hash(String, JSON::Any),
                   host_name : String? = nil,
                   facts : Hash(String, JSON::Any) = {} of String => JSON::Any)
      @vars = vars
      @host_name = host_name || @vars["inventory_hostname"]?.try(&.as_s?) || "localhost"
      @facts = facts
      @vars_owned = false
      @magic_vars_added = false
    end

    def initialize(vars : Hash(String, String | JSON::Any) = {} of String => String | JSON::Any,
                   host_name : String? = nil,
                   facts : Hash(String, JSON::Any) = {} of String => JSON::Any)
      # Convert all vars to JSON::Any
      @vars = Hash(String, JSON::Any).new
      vars.each do |key, value|
        @vars[key] = case value
        when JSON::Any
          value
        when String
          JSON::Any.new(value)
        else
          JSON.parse(value.to_json)
        end
      end

      # A caller that already has the real per-host vars_context (every
      # normal task-dispatch call site does) but omits host_name: - as
      # several internal re-render helpers do, e.g. CrinjaRenderer#
      # prepare_crinja_vars's own inner VarSubstitutor - used to silently
      # default to the LITERAL string "localhost" here, clobbering
      # `vars["inventory_hostname"]` (already correctly set to the real
      # host by TaskExecutor#build_vars_context) with the wrong value for
      # the lifetime of this instance. Any var whose own raw value
      # referenced `{{ inventory_hostname }}` (or another magic var) and
      # needed re-templating through one of these no-host_name: call
      # sites baked in "localhost" instead of the real host - found via
      # robertdebock.common's own `common_hostname: "{{ inventory_
      # hostname }}"` default, silently setting every host's hostname to
      # "localhost" via prepare_crinja_vars. Falling back to whatever's
      # already in vars (only defaulting to the literal "localhost" if
      # even that's missing, e.g. a genuinely-empty vars hash in a unit
      # spec) fixes every such call site at once without needing to
      # thread host_name: through each of them individually.
      @host_name = host_name || @vars["inventory_hostname"]?.try(&.as_s?) || "localhost"

      # This constructor builds a fresh @vars from scratch, so the
      # aliasing concern #18/#20 raise doesn't apply: we own this hash
      # from the start, no dup ever needed.
      @facts = facts
      @vars_owned = true
      @magic_vars_added = false
    end

    # Lazy: dup @vars the first time we need to mutate it. Preserves
    # the aliasing-safety contract #18 documents - if anything ever
    # needs to write to @vars, this runs first and dups before
    # mutating. Subsequent calls are a no-op.
    private def ensure_owned!
      return if @vars_owned
      @vars = @vars.dup
      @vars_owned = true
    end

    # Lazy: build the ExpressionEvaluator / CrinjaRenderer only after
    # magic variables have been added to @vars. The dup happens here if
    # and only if any of these private getters is reached, which is the
    # case for every templated substitute() call - but explicitly NOT
    # the case for a substitute() that returns on the no-placeholder
    # early-exit, which is the win #20 targets.
    private def evaluator : VariableSubstitutor::ExpressionEvaluator
      @evaluator ||= begin
        ensure_magic_vars!
        VariableSubstitutor::ExpressionEvaluator.new(@vars)
      end
    end

    private def renderer : VariableSubstitutor::CrinjaRenderer
      @renderer ||= begin
        ensure_magic_vars!
        VariableSubstitutor::CrinjaRenderer.new(@vars)
      end
    end

    # Magic variables, using the same precedence TaskExecutor#
    # build_vars_context applies, so a bare `when:` and a `{{ }}`
    # expression can never disagree about what they mean.
    #
    # Only `inventory_hostname` is unconditional - it *is* the inventory
    # name and nothing else defines it. The other two are fallbacks:
    #
    # - `ansible_host` is the connection address. An inventory line like
    #   `web1 ansible_host=192.0.2.55` must win; overwriting it with the
    #   inventory name was wrong (verified against ansible-core 2.19.4:
    #   it reports 192.0.2.55) and, in vars_context, would also redirect
    #   PluginManager#get_connection_host to the wrong machine.
    # - `ansible_hostname` is a *fact* - the target's own hostname, which
    #   is frequently not the inventory name at all (ansible-core reports
    #   the real hostname). A gathered fact must win over this fallback.
    #
    # Lazy: only fires when first needed (evaluator/renderer build).
    # #ensure_owned! runs first, so this can safely mutate @vars
    # without aliasing back to the caller.
    private def ensure_magic_vars!
      return if @magic_vars_added
      ensure_owned!
      @vars["inventory_hostname"] = JSON::Any.new(@host_name)
      @vars["ansible_hostname"] ||= JSON::Any.new(@host_name)
      @vars["ansible_host"] ||= JSON::Any.new(@host_name)

      @facts.each do |key, value|
        @vars["ansible_#{key}"] = value
      end
      @magic_vars_added = true
    end
    
    # Raised when a template renders a vault blob none of the supplied
    # secrets could open. Vault.maybe_decrypt_json leaves such a value
    # encrypted rather than failing the parse, so the failure lands here,
    # at the point of USE - matching real Ansible, which runs a playbook
    # carrying a prod-only vault var quite happily on a dev box until
    # something actually references it.
    class UndecryptableVaultError < Exception
    end

    # `output:` marks the FINAL, user-facing rendering of a value - a
    # module argument, a debug message, anything whose text a human or a
    # target host actually sees. Only there is a container rendered in
    # Python's `repr` form (`['a', 'b']`, matching real Ansible);
    # every INTERNAL caller leaves it false and keeps the JSON-compact
    # form, because this engine renders sub-expressions to text and
    # `JSON.parse`es them back all over the place (loop sources,
    # with_fileglob, nested-template re-rendering, the `omit` sentinel
    # sweep) and Python-repr text is not valid JSON. See
    # CrinjaRenderer#evaluate_value!'s comment for the same trap found
    # from the other side.
    def substitute(text : String, strict : Bool = false, output : Bool = false, native : Bool = false) : String
      rendered = substitute_impl(text, strict, output, native)
      if rendered.includes?("$ANSIBLE_VAULT")
        # Real Ansible distinguishes the two cases in its message:
        # nothing supplied at all, versus supplied secrets none of which
        # fit. Verified against ansible-core 2.19.4.
        detail =
          if Vault.vault_ids.empty? && Vault.password.nil?
            "Attempting to decrypt but no vault secrets found."
          else
            "Decryption failed (no vault secrets were found that could decrypt)."
          end
        raise UndecryptableVaultError.new("Attempt to use undecryptable variable: #{detail}")
      end
      rendered
    end

    # native (set_fact native_containers) helper: a BARE variable/dotted
    # reference whose value is a JSON scalar (int/float/bool) keeps its
    # native JSON text instead of the evaluator's stringification -
    # real Ansible's `{{ int_var }}` inside a native container preserves
    # the int, and buluma.ara_api's own reconciled configuration then
    # wrote `DATABASE_CONN_MAX_AGE: 0` / `DEBUG: false` where this engine
    # wrote strings `"0"` / `"False"` (Django then crashed on
    # `float + str`, round 190). Anything else (filters, literals,
    # strings, containers - containers already arrive as JSON text)
    # falls back to the ordinary evaluator.
    private def native_scalar(expr : String, evaluator) : String?
      return nil unless expr.matches?(VariableSubstitutor::ExpressionEvaluator::REGEX_PLAIN_REFERENCE)
      value = begin
        VariableSubstitutor::VariableLookup.new(@vars).resolve(expr)
      rescue
        nil
      end
      return nil unless value
      case value.raw
      when Int64, Float64, Bool
        value.to_s
      else
        nil
      end
    end

    private def substitute_impl(text : String, strict : Bool = false, output : Bool = false, native : Bool = false) : String
      # A task param whose ENTIRE value is block-tag Jinja with no `{{
      # }}` interpolation anywhere at all (`{% if x %}a{% else %}b{%
      # endif %}`, no braces-braces span) - real, valid Ansible/Jinja2
      # syntax (prometheus.prometheus._common's own `_common_dependencies`
      # default, a role var computed entirely from `{% if %}`/`{% else
      # %}`/`{% endif %}` block tags) - previously short-circuited here
      # before ever reaching the "{%"/"{#" branch below, since this guard
      # only ever checked for "{{". The whole param stayed completely
      # unrendered, its literal block-tag text passed straight to a
      # shell command as a package name.
      return text unless text.includes?("{{") || text.includes?("{%") || text.includes?("{#")

      if text.includes?("{%") || text.includes?("{#")
        return text if @@block_tag_escalation_depth >= MAX_BLOCK_TAG_ESCALATION_DEPTH
        # strict: pre-render scan for undefined bare references inside
        # `{% %}` block conditions. Crinja's lenient default
        # `Undefined` makes `undefined == "jre"` quietly return
        # false in `{% if openjdk_app == "jre" %}`, so the block
        # renders to the false branch instead of raising - which is
        # the round-194 andrewrothstein.openjdk divergence (the
        # stat task's `path: "{{ openjdk_install_subdir }}"` arg
        # finalization succeeds on crystal where real ansible
        # raises "Finalization of task args for 'ansible.builtin.
        # stat' failed: 'openjdk_app' is undefined"). The scan
        # itself is narrow (bare-identifier-class references only,
        # with Jinja keywords/filter names/loop-vars/string-literal
        # contents all carved out) and runs BEFORE Crinja is
        # invoked, so the renderer never sees the bad input. See
        # scan_strict_block_tags_for_undefined's own comment for
        # why this isn't solved by passing a strict undefined class
        # to Crinja instead.
        scan_strict_block_tags_for_undefined(text) if strict
        @@block_tag_escalation_depth += 1
        begin
          return renderer.render(text)
        ensure
          @@block_tag_escalation_depth -= 1
        end
      end

      # SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #20 (narrow sub-scope):
      # the previous `inner.strip` allocated a new String for every `{{ }}`
      # span, even when there was no whitespace to strip (e.g. `{{var}}` -
      # common after the `-` trim-marker handling in #expand_mustache_spans
      # already removed any leading/trailing "-"). The hand-rolled
      # ExpressionEvaluator#evaluate internally strips what it needs
      # (split_ternary/split_ternary_no_else/.looks_like_condition? all call
      # `.strip` themselves before use), so passing the un-stripped inner
      # through here is safe. Real Ansible evaluates `{{ var }}` and
      # `{{var}}` identically, so this is behavior-preserving by
      # construction.
      result = expand_mustache_spans(text) do |inner|
        stripped = inner.empty? || (!inner[0].whitespace? && !inner[-1].whitespace?) ? inner : inner.strip
        raise_if_strict_undefined(stripped) if strict
        if native && (nv = native_scalar(stripped, evaluator))
          nv
        else
          output ? evaluator.evaluate_output(stripped) : evaluator.evaluate(stripped)
        end
      end

      # Ansible re-templates a rendered result that still contains "{{" -
      # this happens whenever a variable's own value is itself a template
      # string, e.g. dev-sec os_hardening's include_tasks loop items whose
      # fields are defaults like `mode: "{{ os_mnt_dev_dir_mode }}"`:
      # `{{ mount.mode }}` renders to that literal string on the first
      # pass, and needs a second pass to become the real "0755". Bounded
      # (and stops as soon as a pass makes no further progress) so a value
      # that can never fully resolve, or one that legitimately contains a
      # literal "{{", doesn't loop forever.
      #
      # A leftover "{%"/"{#" (not just "{{") needs the same re-pass, but
      # routed through the FULL Crinja renderer, not another mustache-
      # span-only pass - expand_mustache_spans has no concept of block
      # tags at all. Real bug found benchmarking githubixx.ansible_role_
      # wireguard: `wireguard_remote_directory`'s own default value is a
      # multi-line `{%- if ... -%}...{%- elif ... -%}...{%- endif -%}`
      # block (no `{{ }}` inside at all) - a task param like `dest: "{{
      # wireguard_remote_directory }}/{{ wireguard_conf_filename }}"`
      # fetched that raw block-tag text as a plain string (format_value
      # doesn't template it) and, since the outer loop only ever checked
      # for leftover "{{", never got a second pass to actually evaluate
      # it - the literal, unparsed "{%- if ... %}" text became the real
      # `dest:` path, so the config was never actually written anywhere
      # real, and the wg-quick service failed to start ("config file
      # does not exist") with no obvious tie back to this.
      # Round 191 (gantsign.helm) - recursive re-templating must only
      # apply to leftover templates that ORIGINATED IN A VARIABLE'S OWN
      # VALUE. Real Ansible renders a task argument in a single Jinja2
      # pass and never re-scans the rendered OUTPUT; its documented
      # recursion happens when a *variable lookup* resolves to a string
      # that is itself a template (the variable's value gets templated
      # as part of resolving it). A task arg whose own expression is a
      # QUOTED LITERAL containing brace text - helm's
      # `--template {{ "'{{ if .Version }}{{ .Version }}{{ else }}...
      # {{ end }}'" }}` - evaluates to Go-template text that MUST pass
      # through verbatim; re-scanning it here parsed `{{ else }}` as a
      # Jinja tag and failed with "'else' is undefined" while real
      # ansible ran the command fine. So: only enter the re-pass loop
      # below when at least one span of the ORIGINAL text resolves, via
      # a variable lookup, to a raw value that is itself a template
      # (the os_hardening include_tasks case this loop was built for).
      # Literal-origin leftovers stay verbatim, exactly like Jinja2.
      pending_re_template = re_template_from_variable?(text)
      depth = 0
      while pending_re_template && (result.includes?("{{") || result.includes?("{%") || result.includes?("{#")) && depth < 5
        next_result = if result.includes?("{%") || result.includes?("{#")
                        # strict: same scan as the top-level
                        # substitute_impl branch - this re-templating
                        # loop also has a {% %} path that bypasses
                        # raise_if_strict_undefined, and the
                        # round-194 andrewrothstein.openjdk case
                        # hits it specifically: openjdk_install_
                        # subdir is itself a {% if openjdk_app %}
                        # -templated string, the first pass looks it
                        # up and returns the still-`{{ }}`-bearing
                        # raw value, the re-templating pass then
                        # routes through this {% %} branch to
                        # Crinja. Without the strict scan here,
                        # Crinja's lenient default would silently
                        # treat the undefined-in-`{% if %}` as
                        # false and render the path anyway.
                        scan_strict_block_tags_for_undefined(result) if strict
                        break if @@block_tag_escalation_depth >= MAX_BLOCK_TAG_ESCALATION_DEPTH
                        @@block_tag_escalation_depth += 1
                        begin
                          renderer.render(result)
                        ensure
                          @@block_tag_escalation_depth -= 1
                        end
                      else
                        expand_mustache_spans(result) do |inner|
                          stripped = inner.strip
                          raise_if_strict_undefined(stripped) if strict
                          if native && (nv = native_scalar(stripped, evaluator))
                            nv
                          else
                            output ? evaluator.evaluate_output(stripped) : evaluator.evaluate(stripped)
                          end
                        end
                      end
        break if next_result == result
        result = next_result
        depth += 1
      end

      result
    end

    # strict: helper for the `{% %}` block-tag path - the round-194
    # openjdk case (andrewrothstein.openjdk on Ubuntu 22.04) had its
    # vars/main.yml define openjdk_install_subdir as
    # `{{ openjdk_install_dir }}/{% if openjdk_app == "jre" %}-jre{%
    # endif %}suffix` and the stat task's `path: "{{ openjdk_install_
    # subdir }}"` finalize-args render. Real ansible-core 2.19's
    # strict Jinja2 environment raises on the `openjdk_app` undefined
    # in the if-condition and the whole task aborts with rc=2 at
    # "Finalization of task args for 'ansible.builtin.stat' failed:
    # 'openjdk_app' is undefined". Crystal's Crinja-based render is
    # lenient: the `{% if openjdk_app == "jre" %}` block silently
    # treats `undefined == "jre"` as false, the value renders, the
    # stat task succeeds, the `when: not result.stat.exists` block
    # runs, and two more tasks fail with the same `openjdk_app`
    # undefined (round-194 marathon, role 5).
    #
    # raise_if_strict_undefined only fires for the `{{ }}` path - the
    # `{% %}` path is separate, since substitute_impl routes `{% %}`
    # straight to Crinja for performance. This scan bridges the gap.
    # String literals are stripped first so a `== "jre"` RHS isn't
    # itself flagged; a `for X in Y` loop variable is skipped via
    # the `loop_var` carve-out; the bare-ref scan uses the same
    # identifier shape as REGEX_BARE_VAR_REF.
    private def scan_strict_block_tags_for_undefined(text : String) : Nil
      i = 0
      while i < text.size
        # Scan forward from i to the next `{%` block-tag opener (NOT
        # `{{`, which is an expression span handled elsewhere). The
        # previous cursor init broke out of the loop the instant
        # text[i..i+1] wasn't `{%`, so a text that STARTS with a `{{`
        # span before its `{%` blocks (openjdk_install_subdir =
        # "{{ openjdk_install_dir }}/jdk...{% if openjdk_app %}")
        # never had its later `{% if %}` scanned at all.
        open_at = text.index("{%", i)
        break unless open_at
        close = text.index("%}", open_at + 2)
        break unless close
        i = open_at + 2
        inner = text[i...close]
        stripped = inner.strip

        # if/elif is a condition, for has a loop var before `in`,
        # set has a set-target before `=`. else/endif/etc. have
        # nothing to scan, skip.
        loop_var : String? = nil
        cond : String
        if stripped.starts_with?("for ")
          tail = stripped.sub(/^for\s+/, "")
          in_idx = tail.index(" in ")
          if in_idx
            loop_var = tail[0...in_idx].strip
            cond = tail[(in_idx + 4)..].strip
          else
            cond = tail
          end
        elsif stripped.starts_with?("set ")
          eq_idx = stripped.index('=')
          if eq_idx
            loop_var = stripped[4...eq_idx].strip
            cond = stripped[(eq_idx + 1)..].strip
          else
            cond = stripped
          end
        elsif stripped.starts_with?("if ") || stripped.starts_with?("elif ")
          cond = stripped.sub(/^(if|elif)\s+/, "")
        else
          i = close + 2
          next
        end

        cond_no_strings = strip_string_literals(cond)

        cond_no_strings.scan(SCAN_STRICT_BLOCK_TAG_REF) do |m|
          ident = m[0]
          next if SCAN_STRICT_BLOCK_TAG_KEYWORDS.includes?(ident)
          next if SCAN_STRICT_BLOCK_TAG_BUILTIN_FILTERS.includes?(ident)
          next if @vars.has_key?(ident)
          next if loop_var == ident
          # A bare identifier immediately preceded by `|` is a
          # filter invocation - the filter's own strictness
          # handling decides whether undefined-source is fatal.
          idx = cond_no_strings.index(ident)
          if idx && idx > 0 && cond_no_strings[idx - 1] == '|'
            next
          end
          raise UndefinedVariableError.new("'#{ident}' is undefined")
        end
        i = close + 2
      end
    end

    # Removes every single- and double-quoted string literal from
    # *text* so the bare-ref scan above doesn't treat their contents
    # as variable references. The regex's `(?:\\.|(?!\1).)*` middle
    # part consumes a backslash-and-anything as one character
    # (right for "the next character is escaped"). Sufficient for
    # the real-ansible-playbook shapes the openjdk regression
    # covered, and the alternative (writing a real Jinja2 lexer)
    # is far heavier than this fix needs.
    private def strip_string_literals(text : String) : String
      result = text.dup
      loop do
        m = result.match(/(['"])((?:\\.|(?!\1).)*)\1/)
        break unless m
        result = result.sub(m[0], "")
      end
      result
    end

    # strict: helper - raises UndefinedVariableError when *inner* (a single
    # `{{ }}` span's full content, already stripped) is a BARE variable
    # reference (see REGEX_BARE_VAR_REF) that resolves to nothing. Any
    # other shape (filters, operators, function calls, literals) is left
    # alone regardless of strict: - see UndefinedVariableError's own
    # comment for why that's deliberate, not a gap in this check.
    private def raise_if_strict_undefined(inner : String) : Nil
      unless inner.matches?(REGEX_BARE_VAR_REF)
        # Not a bare reference - but a filter chain STARTING from an
        # undefined bare reference is just as strictly fatal in real
        # Ansible as the bare reference itself (see
        # CrystalPlay.undefined_filter_chain_source).
        if undefined_name = CrystalPlay.undefined_filter_chain_source(inner, @vars)
          raise UndefinedVariableError.new("'#{undefined_name}' is undefined")
        end
        # A chained-subscript/dot expression whose actual lookup would
        # fail - `pkg_upgrade_update_cmds[ansible_distribution_major_
        # version]["update"]` is the canonical case (round 194's
        # andrewrothstein.pkg-upgrade on Rocky 9.6: the role's vars/RedHat.
        # yml only has keys for ansible_distribution_major_version 7
        # and 8, so the second subscript misses, the whole expression
        # resolves to nil, and on real ansible the `when: ... is defined`
        # check evaluates False - so the task is SKIPPED, never run).
        # REGEX_BARE_VAR_REF deliberately rejects unquoted identifiers
        # inside the brackets (only `-?\d+` and `'...'`/`"..."` literal
        # keys are recognized as a bare ref) precisely to keep a
        # `dict[dynamic_var]` lookup from being misread as a flat
        # `dict.dynamic_var` reference, but the *strict* path here needs
        # to actually attempt the resolution rather than skip it. The
        # leading `[A-Za-z_]` requirement on the first character rules
        # out Jinja LITERAL expressions (list literals `['docker']` and
        # dict literals `{'a': 1}` both start with `[` and aren't
        # variable references at all - robertdebock.docker's own
        # `docker_pip_packages: "{{ ['docker'] }}"` would otherwise hit
        # this branch and the lookup would fail and the whole list
        # literal would be misreported as undefined).
        #
        # Tried VariableLookup.resolve here first, but it has its own
        # limit on nested-dynamic-key lookups (the
        # `_docker_pip_packages[ansible_facts['os_family']]` shape
        # robertdebock.docker uses, where the bracket contains another
        # full chained-subscript, returns nil even when the whole
        # chain resolves correctly) - false negative would mark
        # docker's working `docker_pip_packages: "{{ ... }}"` as
        # undefined and silently drop the install task. Tried wrapping
        # the inner in a `{{ }}` and re-calling substitute_impl, but
        # the substitute_impl -> raise_if_strict_undefined recursion
        # is unbounded (a strict probe of the inner triggers the same
        # probe on the inner-of-the-inner, ad infinitum). The
        # actually-correct detection of "this whole expression
        # ultimately resolves to nothing" is the same one
        # ExpressionEvaluator already does in its lenient path: run the
        # expression and see whether the rendered output is the literal
        # text "undefined" (the sentinel for an undefined bare ref in
        # the inner-most lookup). For pkg-upgrade's
        # `pkg_upgrade_update_cmds[ansible_distribution_major_version]
        # ["update"]` on Rocky 9, ansible_distribution_major_version
        # resolves to "9", the dict lookup misses, and the inner-most
        # fallback renders the bare-name "undefined" - the whole
        # expression's text is therefore the 9-character string
        # "undefined". For docker's
        # `_docker_pip_packages[ansible_facts['os_family']]` on Debian,
        # every level resolves, the final value is the list ["docker"],
        # and ExpressionEvaluator's stringify returns its real text.
        if inner.matches?(/\A[A-Za-z_]/) &&
           (inner.includes?('.') || inner.includes?('[')) &&
           !inner.includes?('(') && !inner.includes?('|') &&
           CrystalPlay.expression_resolves_to_undefined?(inner, @vars)
          raise UndefinedVariableError.new("'#{inner}' is undefined")
        end
        # Every other shape (literals, function calls, operators,
        # filter chains whose source is defined, ...) is left alone
        # regardless of strict: - see UndefinedVariableError's own
        # comment for why that's deliberate, not a gap in this check.
        return
      end
      # `omit` is real Ansible's magic bareword for "drop this parameter
      # entirely", not a variable anyone ever sets - so a bare
      # `{{ omit }}` looked undefined to this check and FAILED the task,
      # where real Ansible renders it (to empty text mid-string, or to a
      # dropped parameter when it is the whole value). Verified against
      # ansible-core 2.19.4: `msg: "[{{ omit }}]"` prints "[]".
      return if inner == "omit"
      resolved = VariableSubstitutor::VariableLookup.new(@vars).resolve(inner)
      raise UndefinedVariableError.new("'#{inner}' is undefined") unless resolved
      raise_if_nested_value_undefined(resolved)
    end

    # A resolved value that is ITSELF unrendered `{{ }}` text (a role
    # default computed from another variable - `phpmyadmin_mysql_
    # password: "{{ mysql_root_password }}"`, buluma.phpmyadmin's own
    # defaults/main.yml) is only as defined as whatever it bottoms out
    # at. Real Ansible templates recursively and reports the INNERMOST
    # missing name ("'mysql_root_password' is undefined", pointing at
    # the defaults file, not at the task's own `{{ phpmyadmin_mysql_
    # password }}`), because its Jinja2 rendering is one strict pass
    # over the whole chain rather than a lenient inner render feeding a
    # strict outer one.
    #
    # Without this, the outer check above saw a perfectly real @vars
    # entry, passed, and the inner re-render (CrinjaRenderer#rerender_
    # nested_templates -> #substitute, LENIENT) collapsed the missing
    # innermost name to this codebase's literal "undefined" sentinel
    # text - baked in as if it were legitimate content, so the task
    # succeeded with the string "undefined" as, in that role's case,
    # phpMyAdmin's real MySQL password. The leniency itself is correct
    # and load-bearing everywhere else (`default()`, `is defined`, an
    # ordinarily-unset variable); what was wrong is that the STRICT
    # caller's strictness stopped at the first level instead of
    # following the chain.
    #
    # Recursion is via #substitute's own `strict:` path (not a
    # hand-rolled walk), so every shape it already handles - a partial
    # string `prefix-{{ x }}-suffix`, several spans in one value, a
    # chain several levels deep - is covered here identically, and its
    # existing depth guards bound the recursion.
    private def raise_if_nested_value_undefined(value : JSON::Any) : Nil
      raw = value.raw
      return unless raw.is_a?(String) && raw.includes?("{{")
      substitute_impl(raw, true)
    end

    # Public form of the same probe, for the Crinja-context conversion
    # side (`CrinjaRenderer.convert_var`) - see its call site for why
    # that path needs to ASK rather than raise: it hands the answer to
    # Crinja as a real `Undefined`, whose own `default()`/`is defined`
    # semantics are what a lenient caller wants, instead of failing a
    # task the lenient caller never wanted failed.
    def unresolvable_template?(raw : String) : Bool
      return false unless raw.includes?("{{")
      substitute_impl(raw, true)
      false
    rescue UndefinedVariableError
      true
    end

    # Finds each `{{ ... }}` span in *text* and replaces it with the
    # block's return value, tracking brace depth (and quotes) inside the
    # expression so a literal `{}`/`{a: 1}` dict argument - e.g.
    # `default({})`, `combine({})` - doesn't get mistaken for the span's
    # own closing `}}`. The previous implementation used
    # `/\{\{([^}]+)\}\}/`, whose `[^}]+` cannot match *any* `}` character
    # at all, so an expression containing an inner `}` (from a dict
    # literal) could never find a valid close and was left completely
    # unrendered.
    # Round 191 (gantsign.helm) - does *text* contain a mustache span
    # that resolves, via a variable lookup, to a raw value that is
    # itself a template (contains `{{`/`{%`/`{#`)? Only such spans make
    # real Ansible's recursive re-templating apply to a task argument's
    # rendered output; brace text produced by an evaluated LITERAL (a
    # quoted string in the task itself, e.g. helm's Go-template arg)
    # stays verbatim. Narrow on purpose: bare/dotted/bracketed refs
    # (`{{ x }}`, `{{ a.b[0] }}`) and simple `x | filter` chains whose
    # head is such a ref - the shapes every variable-origin recursion
    # bug so far (os_hardening include_tasks, wireguard block-tag
    # defaults) has taken.
    private def re_template_from_variable?(text : String) : Bool
      found = false
      expand_mustache_spans(text) do |inner|
        unless found
          expr = inner.strip
          expr = expr.split("|").first.strip if expr.includes?("|")
          if expr.matches?(/\A[A-Za-z_][A-Za-z0-9_.\[\]"']*\z/)
            if (v = VariableSubstitutor::VariableLookup.new(@vars).resolve(expr)) && (raw = v.raw).is_a?(String) &&
               (raw.includes?("{{") || raw.includes?("{%") || raw.includes?("{#"))
              found = true
            end
          end
        end
        inner
      end
      found
    end

    private def expand_mustache_spans(text : String, & : String -> String) : String
      result = String::Builder.new
      i = 0
      n = text.size
      while i < n
        if i + 1 < n && text[i] == '{' && text[i + 1] == '{'
          close_at = find_mustache_close(text, i + 2)
          if close_at
            inner = text[(i + 2)...close_at]
            # A `{{ expr -}}`/`{{- expr }}` whitespace-trim marker (real,
            # valid Jinja2 syntax on an expression tag, not just a block
            # tag) - this plain mustache-only scanner originally had no
            # concept of trim markers at all, so a leading/trailing "-"
            # was passed straight into the expression body (`'x'-`
            # instead of `'x'`), corrupting it into a dangling
            # arithmetic operator that resolved to "undefined". Stripping
            # the marker character here fixes the corrupted expression;
            # the surrounding-whitespace TRIM EFFECT the marker also
            # implies is applied below, once the marker's presence is
            # known.
            lstrip_marker = inner.lstrip.starts_with?('-')
            rstrip_marker = inner.rstrip.ends_with?('-')
            inner = inner.lstrip.lchop('-') if lstrip_marker
            inner = inner.rstrip.rchop('-') if rstrip_marker

            # `{{- expr }}`: strip trailing whitespace already written to
            # the builder (real Jinja2 strips back to, and including, the
            # preceding newline). Found via andrewrothstein.temurin's own
            # multi-line `|-` YAML block scalar building a download
            # filename out of `{{ part -}}` / `_{{ part -}}` spans, one
            # per line, relying on the trim markers to collapse the
            # block's own line breaks into a single-line string - without
            # this, every line break survived into the literal filename/
            # URL, breaking the download outright.
            if lstrip_marker
              buffered = result.to_s
              trimmed = buffered.rstrip
              result = String::Builder.new
              result << trimmed
            end

            rendered = yield inner
            result << rendered

            # `{{ expr -}}`: skip leading whitespace (through the next
            # newline) in the literal text immediately following the
            # closing `}}`, matching Jinja2's own `-%}`/`-}}` behavior.
            if rstrip_marker
              j = close_at + 2
              while j < n && text[j].ascii_whitespace?
                j += 1
              end
              i = j
              next
            end

            i = close_at + 2
            next
          end
        end
        result << text[i]
        i += 1
      end
      result.to_s
    end

    # Scans from *start* (just past the opening `{{`) for the `}}` that
    # closes this expression, treating any `{`/`}` that appears inside a
    # quoted string or inside a balanced `{...}` sub-expression as part of
    # the expression body rather than the terminator. Returns the index of
    # the first `}` of the closing `}}`, or nil if none is found.
    private def find_mustache_close(text : String, start : Int32) : Int32?
      state = MustacheScanState.new
      j = start
      n = text.size
      while j < n
        return j if state.closes_at?(text, j)
        j += 1
      end
      nil
    end

    # Per-character scan state for #find_mustache_close - split out so the
    # scanning loop itself stays a single branch, and the "is this `}` the
    # real close, an inner literal `}`, or the start of a nested `{...}`"
    # decision lives in one place.
    #
    # SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #20 (narrow sub-scope):
    # a `struct` (not `class`) so it lives on the stack in
    # #find_mustache_close's caller frame instead of being a per-call heap
    # allocation. The mutating methods (`closes_at?`, `brace_closes?`) work
    # correctly because #find_mustache_close holds `state` as a local
    # variable (not a temporary), which is exactly the case Crystal's
    # struct-method-mutates-caller semantics applies to.
    private struct MustacheScanState
      property depth = 0
      property quote : Char? = nil

      def closes_at?(text : String, j : Int32) : Bool
        char = text[j]
        if q = quote
          self.quote = nil if char == q
          return false
        end

        case char
        when '\'', '"'
          self.quote = char
          false
        when '{'
          self.depth += 1
          false
        when '}'
          brace_closes?(text, j)
        else
          false
        end
      end

      private def brace_closes?(text : String, j : Int32) : Bool
        if depth > 0
          self.depth -= 1
          false
        else
          j + 1 < text.size && text[j + 1] == '}'
        end
      end
    end

    def substitute_hash(hash : Hash(String, String)) : Hash(String, String)
      result = Hash(String, String).new
      hash.each { |k, v| result[substitute(k)] = substitute(v) }
      result
    end

    def substitute_array(array : Array(String)) : Array(String)
      array.map { |item| substitute(item) }
    end

    def set_variable(name : String, value : String | JSON::Any)
      ensure_owned!
      @vars[name] = value.is_a?(JSON::Any) ? value : JSON::Any.new(value)
      # Invalidate rather than eagerly rebuild - same semantics, and the
      # next `substitute` rebuilds only whichever component it actually
      # needs. Nulling the renderer is what drops its memoized
      # JSON::Any -> Crinja::Value conversion of the old variable set,
      # so this must stay in step with CrinjaRenderer's @template_vars.
      @evaluator = nil
      @renderer = nil
    end

    def get_vars : Hash(String, JSON::Any)
      @vars
    end

    def has_variable?(name : String) : Bool
      @vars.has_key?(name)
    end
  end
end
