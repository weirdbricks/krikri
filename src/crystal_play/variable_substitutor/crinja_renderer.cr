require "json"
require "crinja"
require "../crinja_hash_ext"
require "../crinja_string_ext"
require "../crinja_trim_blocks_ext"
require "../crinja_ternary_expr_ext"
require "../crinja_logic_ext"
require "../crinja_in_operator_ext"
require "../crinja_undefined_filter_ext"
require "../crinja_namespace_ext"
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

      # Render a template containing Jinja2 control structures
      def render(text : String) : String
        # @vars is fixed for the lifetime of a renderer (VarSubstitutor
        # #set_variable constructs a new renderer rather than mutating),
        # so the recursive JSON::Any -> Crinja::Value conversion of the
        # entire variable context is done once per renderer instead of
        # once per render - a task with several templated params renders
        # more than once.
        template_vars = (@template_vars ||= prepare_crinja_vars)

        template = shared_env.from_string(normalize_expression_trim_markers(text))
        template.render(template_vars)
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
      private def prepare_crinja_vars : Hash(String, Crinja::Value)
        vars = Hash(String, Crinja::Value).new
        substitutor = VarSubstitutor.new(vars: @vars)

        @vars.each do |key, value|
          vars[key] = json_any_to_crinja_value(rerender_nested_templates(value, substitutor))
        end

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
