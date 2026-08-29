require "../timing_profile"
require "json"
require "crinja"
require "../variable_substitutor"

module CrystalPlay
  module VariableSubstitutor
    # CrinjaRenderer - Handles full Jinja2 template rendering using Crinja
    # This includes {% if %}, {% for %}, {% set %}, etc.
    class CrinjaRenderer
      @vars : Hash(String, JSON::Any)
      @template_context : Crinja::Context?

      def initialize(@vars : Hash(String, JSON::Any))
      end

      # One Crinja environment for the whole process, built on first use.
      # The configuration applied to it is two hardcoded literals that
      # never vary, yet `Crinja.new` was previously paid on *every*
      # `{% %}` render - roughly half the cost of the most expensive
      # thing the substitutor does.
      #
      # Reusing one environment across renders is safe because
      # `Template#render` calls `env.with_scope(bindings)`, which pushes a
      # *child* Context, merges only that render's bindings into it, and
      # restores the former context in an `ensure` - so no variable, and
      # no top-level `{% set %}`, leaks from one render into the next.
      #
      # The invariant this does rely on: rendering never yields the
      # fiber. Crinja's parse/render path is pure CPU with no I/O, and
      # under Crystal's cooperative scheduling only one fiber runs at any
      # instant, so concurrent hosts (--forks) can never interleave two
      # renders and swap each other's context out mid-flight. If a filter
      # or function that performs I/O is ever added, this must become
      # per-fiber (see OutputRouting for that pattern) rather than global.
      @@env : Crinja?

      private def shared_env : Crinja
        if existing = @@env
          return existing
        end

        env = Crinja.new
        env.config.trim_blocks = true
        env.config.lstrip_blocks = false
        @@env = env
      end

      # Crinja parses eagerly in `Template.new` (see `Crinja#from_string`
      # -> `Template#initialize`'s `run_parser` default) - #render
      # previously called `shared_env.from_string(...)` fresh on every
      # single call, re-lexing and re-parsing the SAME task-param Jinja
      # source every time that param got substituted (2-4x per task per
      # host, per this class's own `@template_vars` caching comment
      # above - the exact same "once per renderer, not once per render"
      # motivation applies here). `Template` is documented as immutable
      # once built and `#render(bindings)` takes fresh bindings each
      # call, so a template parsed once is safe to reuse for every
      # subsequent render with different `@vars` - including across
      # different `VarSubstitutor`/`CrinjaRenderer` instances, hence
      # process-wide like `@@env` above (same instances, same input, same
      # renderer output - not re-templated dependent on host-specific
      # data at this layer, so a template built for one host applies
      # unchanged to any other). Bounded in practice by the number of
      # DISTINCT task-param template strings in a playbook (this receives
      # the raw, not-yet-substituted param text - typically dozens to a
      # few hundred across a whole run), not per-host or per-loop-
      # iteration, so no eviction needed.
      #
      # Measured via `scripts/crinja_corpus/bench_evaluators.cr`: even
      # WITHOUT this cache, raw Crinja already renders faster than this
      # codebase's hand-rolled `ExpressionEvaluator` for most tested
      # expression shapes; with it, Crinja is 2-9x faster across the
      # board (e.g. `flag and foo == 'bar'`: 727ns vs 5806ns/call) -
      # see CRINJA.md's "Decision 3" section for what this means for the
      # dual-evaluator convergence question.
      #
      # Same single-fiber-at-a-time safety argument as `@@env` above
      # applies to this `||=` read-check-write: Crinja's render path
      # never yields the fiber, so under Crystal's cooperative
      # scheduling no two `--forks` hosts can ever interleave a
      # read/write race on this Hash.
      @@template_cache = Hash(String, Crinja::Template).new

      private def cached_template(source : String) : Crinja::Template
        @@template_cache[source] ||= shared_env.from_string(source)
      end

      # Render a template containing Jinja2 control structures, raising
      # on any failure instead of swallowing it - for a caller (like
      # `ExpressionEvaluator`'s own Crinja-delegation branches, see
      # CRINJA.md's step-5 notes) that wants to fall back to a DIFFERENT
      # rendering strategy on failure, rather than `#render`'s own
      # "give back the original unrendered text" behavior, which would
      # be actively wrong for a caller expecting a real evaluated value.
      def render!(text : String) : String
        TimingProfile.measure("controller.crinja", "controller.crinja") do
          render_measured!(text)
        end
      end

      private def render_measured!(text : String) : String
        # @vars is fixed for the lifetime of a renderer (VarSubstitutor
        # #set_variable constructs a new renderer rather than mutating),
        # so the lazy per-key JSON::Any -> Crinja::Value conversion (see
        # #build_lazy_context) is set up once per renderer instead of
        # once per render - a task with several templated params renders
        # more than once. Each render gets its own fresh CHILD context
        # (parented to the shared lazy one) so a template's own `{% set
        # %}` bindings never leak into a later render off the same
        # renderer - see #build_lazy_context's own comment for why a
        # bare Context (not a Hash) is passed to #render here.
        parent_context = (@template_context ||= build_lazy_context)
        child_context = Crinja::Context.new(parent_context)

        # Trim markers on OUTPUT tags (`{{- expr }}`/`{{ expr -}}`) used to
        # be worked around by pre-normalizing the source here (the removed
        # `normalize_expression_trim_markers`); the fork's lexer now
        # tokenizes them correctly natively (crystal-play-0.9.5 and
        # earlier), so the raw source is handed straight to Crinja.
        template = cached_template(text)
        template.render(child_context)
      end

      # Render a template containing Jinja2 control structures
      def render(text : String) : String
        render!(text)
      rescue
        # Return original text on failure
        text
      end

      # Evaluates *expr* (bare Jinja expression text, no surrounding
      # `{{ }}`) and returns its RAW structured result as `JSON::Any`
      # (nil for a genuinely undefined result - the same nilable
      # convention `VariableLookup#resolve`/`#resolve_simple`/etc.
      # already use) instead of `#render!`'s always-a-String output.
      #
      # `#render!` goes through `Template#render`, which always produces
      # a String via `Crinja::Finalizer#stringify` - fine for a FINAL
      # `{{ }}` substitution, but wrong for a caller (like
      # `ExpressionEvaluator`'s Crinja-delegation branches) that needs to
      # hand the result to something else expecting structured data
      # (another filter, a `.get()` call, a nested nested expression) or
      # that wants to format an Array/Hash result through THIS
      # codebase's own `VariableLookup#format_value` (its JSON-compact
      # style, not Crinja's Python-repr `Finalizer` style) so the
      # existing internal "render sub-expression to a String, `JSON.
      # parse` it back into structured data" round trip used throughout
      # `expression_evaluator.cr`/`filter_engine.cr`/`comparison_
      # evaluator.cr`/`variable_lookup.cr` keeps working unchanged - see
      # CRINJA.md's step-5 "general filter-chain dispatch" notes for the
      # full investigation that found this was necessary (a naive
      # `format_value` Python-repr rewrite broke that round trip outright
      # since Python-repr text isn't valid JSON).
      #
      # Parses via `Crinja::Parser::ExpressionLexer`/`ExpressionParser`
      # directly (bypassing `Template`/`from_string` entirely - there is
      # no template TAG here, just a bare expression) and
      # `Crinja::Environment#evaluate(ast_node, bindings) : Value`
      # (`lib/crinja/src/environment.cr:106-108`), the overload that
      # returns the raw `Value` rather than a stringified result -
      # mirrors the fork's own `spec_helper.cr#evaluate_expression_raw`
      # test helper, which uses the identical parse-then-evaluate
      # sequence for the same reason (getting at the raw value, not
      # Crinja's own stringified rendering of it).
      def evaluate_value!(expr : String) : JSON::Any?
        # A bare expression (no surrounding template, no tags) can never
        # contain a `{% set %}`, so - unlike #render! above - there is no
        # leak risk in evaluating directly against the shared lazy parent
        # context rather than a fresh per-call child.
        parent_context = (@template_context ||= build_lazy_context)
        ast = cached_expression(expr)
        value = shared_env.evaluate(ast, parent_context)
        return nil if value.undefined?

        CrinjaRenderer.elide_omitted(CrinjaRenderer.crinja_value_to_json_any(value))
      end

      # Real Ansible's `omit` inside a CONTAINER removes that entry
      # rather than leaving a placeholder in it - verified against
      # ansible-core 2.19.4: `{{ [1, v_omit, 3] }}` renders `[1, 3]` and
      # `{{ {'a': 1, 'b': v_omit} }}` renders `{"a": 1}`. Crinja builds
      # such a literal itself (this is the raw-value path every bracket/
      # dict expression takes), so it sees `omit` as the ordinary string
      # this engine represents it with, and kept it - the literal
      # sentinel text then landed in whatever the list/dict fed.
      #
      # ExpressionEvaluator's own literal-array/dict builders need the
      # same treatment separately: the two evaluators share no
      # implementation, so this bug class has to be fixed once in each
      # (see CLAUDE.md). Only containers are touched here - a bare
      # scalar `omit` must survive intact this far, since that is what
      # tells the caller to drop a whole parameter.
      def self.elide_omitted(value : JSON::Any) : JSON::Any
        case raw = value.raw
        when Array
          JSON::Any.new(raw.reject { |item| item.as_s? == CrystalPlay::OMIT_SENTINEL }
            .map { |item| elide_omitted(item) })
        when Hash
          kept = Hash(String, JSON::Any).new
          raw.each do |key, item|
            next if item.as_s? == CrystalPlay::OMIT_SENTINEL
            kept[key] = elide_omitted(item)
          end
          JSON::Any.new(kept)
        else
          value
        end
      end

      @@expression_cache = Hash(String, Crinja::AST::ExpressionNode).new

      private def cached_expression(expr : String) : Crinja::AST::ExpressionNode
        @@expression_cache[expr] ||= begin
          lexer = Crinja::Parser::ExpressionLexer.new(shared_env.config, expr)
          parser = Crinja::Parser::ExpressionParser.new(lexer)
          parser.parse
        end
      end

      # Convert Crinja::Value to JSON::Any - the reverse direction of
      # #json_any_to_crinja_value below. Exposed as a class method for
      # the same reason that one is (shareable with any other Crinja
      # environment this codebase spins up).
      def self.crinja_value_to_json_any(value : Crinja::Value) : JSON::Any
        case raw = value.raw
        when Int32, Int64
          JSON::Any.new(raw.to_i64)
        when Float64
          JSON::Any.new(raw)
        when String, Crinja::SafeString
          JSON::Any.new(raw.to_s)
        when Bool
          JSON::Any.new(raw)
        when Nil
          JSON::Any.new(nil)
        when Crinja::Dictionary
          hash = Hash(String, JSON::Any).new
          raw.each { |k, v| hash[k.to_s] = crinja_value_to_json_any(v) }
          JSON::Any.new(hash)
        when Array(Crinja::Value)
          JSON::Any.new(raw.map { |item| crinja_value_to_json_any(item) })
        when Crinja::TimeDelta
          # A bare `to_datetime(...) - to_datetime(...)` timedelta
          # result (not followed by `.days`/.total_seconds() in the same
          # expression) - mirror the hand-rolled timedelta()'s structured
          # shape so a downstream hand-rolled `.days`/`.seconds` Hash-key
          # member access on it still works.
          JSON::Any.new({
            "days"          => JSON::Any.new(raw.days),
            "seconds"       => JSON::Any.new(raw.seconds % 86_400),
            "microseconds"  => JSON::Any.new(0_i64),
            "total_seconds" => JSON::Any.new(raw.total_seconds),
          })
        else
          # Time/Crinja::Object/Callable/Iterator - none of this
          # codebase's own converged constructs produce these; falls
          # back to Crinja's own stringification rather than crashing.
          JSON::Any.new(Crinja::Finalizer.stringify(raw))
        end
      end

      # Build the lazy Crinja context backing this renderer's variable
      # scope. Real Ansible recursively re-templates every variable's
      # value when it's actually used, no matter where - including
      # inside a real .j2 template FILE, not just a plain task-param
      # `{{ }}`. Role `defaults/main.yml` commonly relies on this:
      # geerlingguy.nginx's own `nginx_worker_processes: '"{{
      # ansible_processor_vcpus | default(ansible_processor_count)
      # }}"'` is a YAML string whose *value* is itself more Jinja - real
      # Jinja2 has no such recursive behavior on its own (a variable's
      # string value is just a string to it), so without this, `{{
      # nginx_worker_processes }}` inside nginx.conf.j2 rendered the
      # literal, still-unparsed `{{ ansible_processor_vcpus | ... }}`
      # text straight into the config file, and nginx's own config
      # parser then choked on it. The plain `{{ }}` evaluator
      # (VarSubstitutor#substitute) already implements exactly this
      # re-templating for task params via its own bounded multi-pass
      # loop - reused here (a plain, non-Crinja VarSubstitutor pass, so
      # no risk of this recursing back into this same render) rather
      # than duplicating that logic.
      #
      # Used to eagerly walk and convert the WHOLE of `@vars` up front
      # (`prepare_crinja_vars`/`finish_crinja_vars`, see git history) -
      # O(all vars) per renderer regardless of how many variables a
      # given template actually reads. `LazyCrinjaContext` below instead
      # converts one key at a time, on first access, memoizing into its
      # own `scope` (a plain `Crinja::Context` IS a
      # `Util::ScopeMap(String, Crinja::Value)` - see that class's own
      # `#[]`/`#has_key?`, the only two methods anything in `lib/crinja`
      # ever calls on a context; `keys`/`values`/`entries` are never
      # used, checked directly via `grep -rn
      # 'context\.keys\|context\.entries\|context\.values' lib/crinja/src`)
      # - so a template reading a handful of variables out of a
      # thousand-entry context now does O(handful) conversion work, not
      # O(thousand). Parented off `shared_env.context` (the process-wide
      # environment's own root context, normally empty) rather than
      # `nil`, matching what `Environment#with_scope(bindings)` used to
      # build for us before this change.
      private def build_lazy_context : Crinja::Context
        LazyCrinjaContext.new(@vars, VarSubstitutor.new(vars: @vars), shared_env.context)
      end

      # Guards against a genuine infinite-recursion trap distinct from
      # `VarSubstitutor`'s own `@@block_tag_escalation_depth`: that guard
      # bounds the RECURSION DEPTH of `substitute`/`render` calls, but
      # (back when this was `#prepare_crinja_vars`, walking the whole of
      # `@vars` eagerly) each recursion level re-walked ALL of `@vars`,
      # not just the one variable that triggered it - so total work was
      # exponential in (templated-var count) ^ (escalation depth), not
      # linear. Real bug found benchmarking prometheus.prometheus.
      # node_exporter (round 22): `_common_dependencies`'s own vars/
      # main.yml default is `{% if ... %}{{ ... }}{% else %}{% endif
      # %}` (block tags, no surrounding `{{ }}`) - rendering it re-
      # entered the whole-hash walk, which found the SAME
      # `_common_dependencies` still raw and recursed again - with
      # `@@block_tag_escalation_depth`'s cap of 50 and ~20 templated
      # vars in that role's vars/main.yml, this pegged a CPU core
      # indefinitely (observed >30s with zero progress) well before ever
      # reaching the depth-50 exit.
      #
      # Now that conversion happens per-KEY on first access
      # (`LazyCrinjaContext#convert` below) rather than per whole-hash
      # walk, this guard brackets one key's conversion instead of all of
      # them - strictly tighter than before (a recursion that used to
      # burn through N variables' worth of work per depth level now
      # burns through 1), so the existing cap of 3 stays just as safe,
      # not looser.
      @@prepare_crinja_vars_depth = 0
      MAX_PREPARE_CRINJA_VARS_DEPTH = 3

      # Converts one `@vars` entry to its final `Crinja::Value`, applying
      # the same recursive re-templating `#rerender_nested_templates`
      # always did, bounded by the depth guard above. Called from
      # `LazyCrinjaContext#convert` - kept here (not on that class)
      # because it needs `@@prepare_crinja_vars_depth`, a CrinjaRenderer
      # class variable shared across every renderer/context in the
      # process, matching the guard's own "process-wide, not
      # per-instance" reasoning (see `VarSubstitutor`'s identical
      # `@@block_tag_escalation_depth` comment).
      def self.convert_var(raw_value : JSON::Any, substitutor : VarSubstitutor, name : String = "") : Crinja::Value
        if @@prepare_crinja_vars_depth >= MAX_PREPARE_CRINJA_VARS_DEPTH
          return json_any_to_crinja_value(raw_value)
        end

        # A variable whose own stored value is `{{ }}` text bottoming out
        # at a name set nowhere (`phpmyadmin_mysql_password: "{{
        # mysql_root_password }}"` with no `mysql_root_password`
        # anywhere) is UNDEFINED, not "defined, with the seven-character
        # value `undefined`" - which is what the lenient re-render below
        # otherwise hands Crinja, since `VarSubstitutor#substitute`
        # renders any unresolved lookup as that literal sentinel text.
        # Crinja then saw an ordinary non-empty string: `| default('x')`
        # returned "undefined" instead of "x", `is defined` was True
        # where real Ansible says False, and `when: v | default('') !=
        # ''` ran a task real Ansible skips.
        #
        # Handing back a real `Crinja::Undefined` instead lets Crinja's
        # OWN undefined semantics answer all three, which is exactly
        # what they exist for - no sentinel string doing double duty.
        # The complementary half (a STRICT caller - module-arg
        # finalization - failing the task rather than rendering
        # anything) is `VarSubstitutor#raise_if_nested_value_undefined`,
        # which fires before this conversion is ever reached.
        if (raw = raw_value.raw).is_a?(String) && substitutor.unresolvable_template?(raw)
          return Crinja::Value.new(Crinja::Undefined.new(name))
        end

        @@prepare_crinja_vars_depth += 1
        begin
          json_any_to_crinja_value(rerender_nested_templates(raw_value, substitutor))
        ensure
          @@prepare_crinja_vars_depth -= 1
        end
      end

      # Real bug found benchmarking geerlingguy.postgresql: its own
      # pg_hba.conf.j2 iterates `postgresql_hba_entries` (a list of
      # dicts) via `{% for client in ... %} ... {{ client.auth_method
      # }} ...{% endfor %}`, where each entry's `auth_method:` field is
      # itself `"{{ postgresql_auth_method }}"` - a role default
      # computed from ANOTHER default, the same recursive-re-templating
      # shape this codebase has already fixed a dozen-odd times over
      # for plain scalar variable values. This is a distinct sub-case
      # none of those fixes covered: only a *top-level* String value
      # used to get re-rendered - `postgresql_hba_entries` itself is an
      # Array, so it never even reached the `raw.is_a?(String)` check at
      # all, and the literal unrendered `{{ postgresql_auth_method }}`
      # text landed straight into the rendered config file (PostgreSQL
      # then refused to start: "invalid authentication method '{{'").
      # Real Ansible's own recursive re-templating applies at every
      # level of a nested structure, not just the outermost value -
      # walks Array/Hash values recursively, re-rendering every String
      # leaf that still contains "{{".
      #
      # Exposed as a class method for the same reason
      # #json_any_to_crinja_value is: TemplateActionPlugin has its own
      # separate prepare_*_vars (a genuinely separate Crinja
      # environment - see that method's own comment) that needs this
      # identical recursive-re-render fix, not just this class's.
      def self.rerender_nested_templates(value : JSON::Any, substitutor : VarSubstitutor) : JSON::Any
        case raw = value.raw
        when String
          if raw.includes?("{{")
            rendered = substitutor.substitute(raw)
            stripped = raw.strip
            if stripped.starts_with?("{{") && stripped.ends_with?("}}")
              # A nested-template variable whose ENTIRE value (no other
              # literal characters around it) is a `{{ }}` expression
              # can itself render to a real array/dict
              # (`docker_pip_packages: "{{
              # _docker_pip_packages[ansible_facts['os_family']] |
              # default(...) }}"`, robertdebock.docker's own vars/main.
              # yml) - substitutor.substitute always returns a formatted
              # STRING, so without re-parsing back to JSON here every
              # such variable silently became a String-typed Crinja
              # value forever after (`docker_pip_packages | length`
              # measured the STRING's character count instead of the
              # list's element count, and the `| length > 0` when: guard
              # on the role's own conditional "Install docker pip
              # packages" task always passed even for the empty-list
              # Debian case, then `ansible.builtin.pip: name: "[]"`
              # tried to install a literal package named "[]"). Every
              # other rerender call site in this codebase
              # (VariableLookup#rerender_if_templated, ExpressionEvaluator's
              # own bare-lookup/filter-chain-head fallback) already does
              # this JSON.parse-back step; this one (feeding Crinja's
              # own vars context) was the one gap.
              #
              # Restricted to a PURE `{{ }}` value (nothing else around
              # it) rather than any string containing "{{" anywhere -
              # geerlingguy.nginx's own `nginx_worker_processes: '"{{
              # ansible_processor_vcpus | default(...) }}"'` has literal
              # double-quote characters OUTSIDE the `{{ }}` span,
              # deliberately, so its rendered value stays the literal
              # 3-character string `"1"` in the .conf file - reparsing
              # THAT as JSON would strip the quotes real Ansible keeps,
              # a regression this same restriction (`raw.strip` must be
              # entirely one `{{ }}` span) is what
              # VariableLookup#rerender_if_templated already uses to
              # draw the same line.
              #
              # Only attempt the parse-back when the rendered text is
              # container-SHAPED (`[...]`/`{...}`) - real Ansible's
              # default (non-jinja2_native) templating renders a `{{ }}`
              # expression to plain text and does NOT re-infer a scalar
              # type from it: a role default like `bind_python_version:
              # "{{ bind_default_python_version }}"` where the referenced
              # var is the quoted YAML STRING "3" stays the string "3"
              # through any number of indirections in real Ansible - it
              # never becomes the integer 3. Blindly JSON-parsing EVERY
              # rendered scalar here silently reinterpreted any purely
              # numeric-looking string ("3", "0700", a version string
              # missing its middle segment...) as a real number, breaking
              # `==`/`!=` string comparisons against a quoted literal
              # elsewhere (`bind_python_version == '3'` went from True to
              # False - the comparison operands ended up Int64(3) vs
              # String("3"), which real Jinja/Python correctly refuses to
              # treat as equal). Found via buluma.bind's own vars/Debian.
              # yml: `(bind_python_version == '3') | ternary(...)` always
              # picked the FALSE branch, installing the removed python2-
              # era `python-netaddr`/`python-dnspython` package names
              # instead of `python3-*` on every real Debian/Ubuntu target.
              if rendered.strip.starts_with?('[') || rendered.strip.starts_with?('{')
                (JSON.parse(rendered) rescue nil) || JSON::Any.new(rendered)
              else
                JSON::Any.new(rendered)
              end
            else
              JSON::Any.new(rendered)
            end
          else
            value
          end
        when Array
          JSON::Any.new(raw.map { |item| rerender_nested_templates(item, substitutor) })
        when Hash
          JSON::Any.new(raw.transform_values { |item| rerender_nested_templates(item, substitutor) })
        else
          value
        end
      end

      # Convert JSON::Any to Crinja::Value.
      #
      # Exposed as a class method because TemplateActionPlugin needs the
      # exact same coercion and used to carry a verbatim copy of it.
      # (Only the *converter* is shared: that plugin's Crinja environment
      # genuinely must stay separate, since its trim_blocks/lstrip_blocks
      # come from the task's own template: params and therefore vary per
      # task - unlike this class's, whose config is invariant and so can
      # be one process-wide instance.)
      def self.json_any_to_crinja_value(json : JSON::Any) : Crinja::Value
        case json.raw
        when String
          Crinja::Value.new(json.as_s)
        when Int64
          # as_i is Int32-only, raises "Arithmetic overflow" for a value
          # like a large uid rendered via a real .j2 template - see
          # playbook_parser.cr's own identical fix for the same root
          # cause. Crinja::Value's own Raw type already includes Int64
          # directly (Number), no further conversion needed.
          Crinja::Value.new(json.as_i64)
        when Float64
          Crinja::Value.new(json.as_f)
        when Bool
          Crinja::Value.new(json.as_bool)
        when Nil
          Crinja::Value.new(nil)
        when Hash
          hash = Hash(String, Crinja::Value).new
          json.as_h.each do |key, value|
            hash[key] = json_any_to_crinja_value(value)
          end
          Crinja::Value.new(hash)
        when Array
          array = json.as_a.map { |item| json_any_to_crinja_value(item) }
          Crinja::Value.new(array)
        else
          Crinja::Value.new(json.to_s)
        end
      end
    end
  end
end
