require "json"
require "crinja"
require "../variable_substitutor"

module CrystalPlay
  module VariableSubstitutor
    # CrinjaRenderer - Handles full Jinja2 template rendering using Crinja
    # This includes {% if %}, {% for %}, {% set %}, etc.
    class CrinjaRenderer
      @vars : Hash(String, JSON::Any)
      @template_vars : Hash(String, Crinja::Value)?

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

      # The vendored Crinja shard's expression-lexer mistokenizes a
      # whitespace-trim marker on an OUTPUT tag specifically (`{{- expr
      # }}`/`{{ expr -}}`) - real, valid Jinja2 syntax, and the trim-
      # marker-on-a-BLOCK-tag form (`{%- if x -%}`) works fine, but the
      # expression-tag form gets tokenized as if the `-` were a literal
      # minus OPERATOR followed by a separate `}}` end token, corrupting
      # the whole expression (`'x' -}}` parses as `'x' - <undefined>`,
      # rendering "undefined" instead of "x"). Found via prometheus.
      # prometheus._common's own vars/main.yml: `_common_dependencies:
      # "{% if (...) %}{{ (...) -}}{% else %}{% endif %}"` - real
      # Ansible-written Jinja using `-}}` to suppress the trailing
      # newline the multi-line YAML `\`-folded string otherwise
      # introduces.
      #
      # Worked around here rather than in the vendored shard's own
      # tokenizer (which would need a real lexer-level fix): the trim
      # marker only ever controls surrounding WHITESPACE, never what the
      # expression itself evaluates to, so it's equivalent to physically
      # removing the adjacent template-source whitespace (real Jinja's
      # own lstrip_blocks/trim_blocks mechanism does exactly this at
      # parse time) and handing Crinja a plain, un-trimmed `{{ expr }}`
      # it already tokenizes correctly.
      private def normalize_expression_trim_markers(text : String) : String
        result = String::Builder.new
        i = 0
        n = text.size

        while i < n
          if text[i] == '{' && i + 1 < n && text[i + 1] == '{'
            close = find_expr_close(text, i + 2)
            unless close
              result << text[i]
              i += 1
              next
            end

            inner = text[(i + 2)...close]
            left_trim = inner.starts_with?('-')
            right_trim = inner.ends_with?('-')
            inner = inner[1..].lstrip if left_trim
            inner = inner[0..-2].rstrip if right_trim

            if left_trim
              current = result.to_s
              result = String::Builder.new
              result << current.rstrip
            end
            result << "{{" << inner << "}}"

            i = close + 2
            # Skip forward past any whitespace immediately following the
            # tag when right-trimmed, physically removing it from the
            # source the same way Jinja's own trim would.
            if right_trim
              while i < n && text[i].whitespace?
                i += 1
              end
            end
            next
          end

          result << text[i]
          i += 1
        end

        result.to_s
      end

      # Finds the `}}` that closes an expression tag opened at *start*
      # (just past the `{{`), quote-aware (a literal `}` inside a
      # quoted string doesn't count) - mirrors VarSubstitutor's own
      # find_mustache_close, kept as an independent copy since that one
      # is private to a different class.
      private def find_expr_close(text : String, start : Int32) : Int32?
        i = start
        n = text.size
        quote : Char? = nil

        while i < n
          char = text[i]
          if q = quote
            quote = nil if char == q
          elsif char == '\'' || char == '"'
            quote = char
          elsif quote.nil? && char == '}' && i + 1 < n && text[i + 1] == '}'
            return i
          end
          i += 1
        end

        nil
      end

      # Render a template containing Jinja2 control structures, raising
      # on any failure instead of swallowing it - for a caller (like
      # `ExpressionEvaluator`'s own Crinja-delegation branches, see
      # CRINJA.md's step-5 notes) that wants to fall back to a DIFFERENT
      # rendering strategy on failure, rather than `#render`'s own
      # "give back the original unrendered text" behavior, which would
      # be actively wrong for a caller expecting a real evaluated value.
      def render!(text : String) : String
        # @vars is fixed for the lifetime of a renderer (VarSubstitutor
        # #set_variable constructs a new renderer rather than mutating),
        # so the recursive JSON::Any -> Crinja::Value conversion of the
        # entire variable context is done once per renderer instead of
        # once per render - a task with several templated params renders
        # more than once.
        template_vars = (@template_vars ||= prepare_crinja_vars)

        template = cached_template(normalize_expression_trim_markers(text))
        template.render(template_vars)
      end

      # Render a template containing Jinja2 control structures
      def render(text : String) : String
        render!(text)
      rescue
        # Return original text on failure
        text
      end

      # Prepare variables for Crinja rendering
      #
      # Real Ansible recursively re-templates every variable's value when
      # it's actually used, no matter where - including inside a real
      # .j2 template FILE, not just a plain task-param `{{ }}`. Role
      # `defaults/main.yml` commonly relies on this: geerlingguy.nginx's
      # own `nginx_worker_processes: '"{{ ansible_processor_vcpus |
      # default(ansible_processor_count) }}"'` is a YAML string whose
      # *value* is itself more Jinja - real Jinja2 has no such recursive
      # behavior on its own (a variable's string value is just a string
      # to it), so without this, `{{ nginx_worker_processes }}` inside
      # nginx.conf.j2 rendered the literal, still-unparsed `{{
      # ansible_processor_vcpus | ... }}` text straight into the config
      # file, and nginx's own config parser then choked on it. The plain
      # `{{ }}` evaluator (VarSubstitutor#substitute) already implements
      # exactly this re-templating for task params via its own bounded
      # multi-pass loop - reused here (a plain, non-Crinja
      # VarSubstitutor pass, so no risk of this recursing back into this
      # same render) rather than duplicating that logic.
      # Guards against a genuine infinite-recursion trap distinct from
      # `VarSubstitutor`'s own `@@block_tag_escalation_depth`: that guard
      # bounds the RECURSION DEPTH of `substitute`/`render` calls, but
      # each `prepare_crinja_vars` call at every depth level re-walks
      # ALL of `@vars` (not just the one variable that triggered the
      # recursion), and any OTHER still-templated `{% %}` variable found
      # along the way recurses again the same way - so the total work is
      # exponential in (templated-var count) ^ (escalation depth), not
      # linear. Real bug found benchmarking prometheus.prometheus.
      # node_exporter (round 22): `_common_dependencies`'s own vars/
      # main.yml default is `{% if ... %}{{ ... }}{% else %}{% endif
      # %}` (block tags, no surrounding `{{ }}`) - rendering it re-
      # entered `prepare_crinja_vars`, which re-walked the SAME raw
      # `@vars` hash (unchanged - this is a read-only re-templating
      # pass) and found the SAME `_common_dependencies` still raw,
      # recursing again - with `@@block_tag_escalation_depth`'s cap of
      # 50 and ~20 templated vars in that role's vars/main.yml, this
      # pegged a CPU core indefinitely (observed >30s with zero
      # progress) well before ever reaching the depth-50 exit. A much
      # tighter cap here (re-templating a variable's value more than a
      # couple of levels deep from within another variable's own re-
      # templating pass is already a sign it won't converge) keeps the
      # existing depth-50 guard as the outer safety net while making
      # the common case (one or two levels of indirection) cheap.
      @@prepare_crinja_vars_depth = 0
      MAX_PREPARE_CRINJA_VARS_DEPTH = 3

      private def prepare_crinja_vars : Hash(String, Crinja::Value)
        vars = Hash(String, Crinja::Value).new

        if @@prepare_crinja_vars_depth >= MAX_PREPARE_CRINJA_VARS_DEPTH
          @vars.each { |key, value| vars[key] = json_any_to_crinja_value(value) }
          return finish_crinja_vars(vars)
        end

        substitutor = VarSubstitutor.new(vars: @vars)

        @@prepare_crinja_vars_depth += 1
        begin
          @vars.each do |key, value|
            vars[key] = json_any_to_crinja_value(rerender_nested_templates(value, substitutor))
          end
        ensure
          @@prepare_crinja_vars_depth -= 1
        end

        finish_crinja_vars(vars)
      end

      private def finish_crinja_vars(vars : Hash(String, Crinja::Value)) : Hash(String, Crinja::Value)

        # `vars` - real Ansible's own magic variable exposing the whole
        # current variable scope as a dict, letting a template look up a
        # DYNAMICALLY-COMPUTED variable name (`vars['prefix_' +
        # suffix]`) rather than a fixed one. openstack.ansible-hardening's
        # own audit-rule template does exactly this (`vars['security_
        # rhel7_audit_' + command_sanitized] | bool`, picking which of ~40
        # individually-named enable/disable flags applies to the audit
        # rule currently being rendered) - entirely absent before,
        # "vars is undefined" failed the whole template render outright.
        # A shallow snapshot (not recursively containing itself under its
        # own "vars" key) is enough for every real lookup-by-computed-key
        # usage.
        vars["vars"] = Crinja::Value.new(vars.reduce(Crinja::Dictionary.new) { |dict, (key, value)| dict[Crinja::Value.new(key)] = value; dict })

        # Real Ansible's `omit` magic variable - a bare identifier
        # reference, not a filter/function call, so Crinja has no way to
        # know about it unless it's bound in context like any other var.
        # `CrystalPlay::OMIT_SENTINEL` is the same magic string
        # `FilterEngine`'s own `default(omit)`/ternary-argument handling
        # already produces for the hand-rolled evaluator - binding the
        # SAME sentinel here means an expression routed through Crinja
        # (e.g. `user.groups | default([]) | join(',') or omit`) drops
        # its param the same way, via the same downstream `#substitute_
        # task_params` sentinel-strip check, instead of silently
        # rendering as the literal empty string (`omit` resolving to
        # Undefined -> `""`) - a real, wrong value, not an omitted param.
        vars["omit"] ||= Crinja::Value.new(CrystalPlay::OMIT_SENTINEL)

        vars
      end

      # Real bug found benchmarking geerlingguy.postgresql: its own
      # pg_hba.conf.j2 iterates `postgresql_hba_entries` (a list of
      # dicts) via `{% for client in ... %} ... {{ client.auth_method
      # }} ...{% endfor %}`, where each entry's `auth_method:` field is
      # itself `"{{ postgresql_auth_method }}"` - a role default
      # computed from ANOTHER default, the same recursive-re-templating
      # shape this codebase has already fixed a dozen-odd times over
      # for plain scalar variable values. This is a distinct sub-case
      # none of those fixes covered: #prepare_crinja_vars only ever
      # re-rendered a *top-level* String value - `postgresql_hba_
      # entries` itself is an Array, so it never even reached the
      # `raw.is_a?(String)` check at all, and the literal unrendered
      # `{{ postgresql_auth_method }}` text landed straight into the
      # rendered config file (PostgreSQL then refused to start:
      # "invalid authentication method '{{'"). Real Ansible's own
      # recursive re-templating applies at every level of a nested
      # structure, not just the outermost value - walks Array/Hash
      # values recursively, re-rendering every String leaf that still
      # contains "{{".
      private def rerender_nested_templates(value : JSON::Any, substitutor : VarSubstitutor) : JSON::Any
        CrinjaRenderer.rerender_nested_templates(value, substitutor)
      end

      private def json_any_to_crinja_value(json : JSON::Any) : Crinja::Value
        CrinjaRenderer.json_any_to_crinja_value(json)
      end

      # Exposed as a class method for the same reason
      # #json_any_to_crinja_value is: TemplateActionPlugin has its own
      # separate prepare_*_vars (a genuinely separate Crinja
      # environment - see that method's own comment) that needs this
      # identical recursive-re-render fix, not just this class's.
      def self.rerender_nested_templates(value : JSON::Any, substitutor : VarSubstitutor) : JSON::Any
        case raw = value.raw
        when String
          raw.includes?("{{") ? JSON::Any.new(substitutor.substitute(raw)) : value
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
          Crinja::Value.new(json.as_i)
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
