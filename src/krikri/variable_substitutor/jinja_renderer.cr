require "../timing_profile"
require "json"
require "../variable_substitutor"
require "../python_filter_runner"
require "../python_lookup_runner"
require "../jinja_host_context"
require "./jinja_var_resolver"
require "../krikri_jinja_filters"

module Krikri
  module VariableSubstitutor
    # Raised for an unknown `is <test>` TEST name - the test-side sibling
    # of FilterEngine::UnknownFilterError. Real Jinja2/ansible-core
    # validates test names against the registered test set at template
    # COMPILE time and refuses the task with "No test named 'x'." (a
    # TemplateAssertionError, verified against ansible-core 2.19 via
    # sunfoxcz.dkim's own `dkim_domains is not list` - there is a `list`
    # FILTER and an `is iterable` test, but no `is list` TEST).
    class UnknownTestError < Exception
    end

    # Renders and evaluates task-param Jinja (`{{ }}` and `{% %}`) on the
    # shared krikri-jinja engine, against a lazily prepared variable scope
    # (JinjaVarResolver).
    class JinjaRenderer
      @vars : Hash(String, JSON::Any)
      # When true, string-literal escapes are decoded (vanilla Jinja
      # semantics) instead of passed through verbatim. Only the
      # conditional/assert path sets this; inline task-param `{{ }}`
      # templating keeps it false, matching real ansible-core (its inline
      # lexer doubles backslashes; `when:` expressions decode normally).
      @decode : Bool

      def initialize(@vars : Hash(String, JSON::Any), @decode : Bool = false)
      end

      # True if *name* resolves as a filter on the shared engine, including
      # a collection-qualified name (`ansible.builtin.ternary`) by its
      # trailing segment, as a render would resolve it.
      def self.known_filter?(name : String) : Bool
        KrikriJinja.default_known_filter?(name) || KrikriJinja.default_known_filter?(collection_member(name))
      end

      # The test-side twin of #known_filter?, for ConditionalEvaluator's
      # compile-time test-name pre-pass (an unknown `is <name>` in a
      # `when:` must hard-fail even when and/or short-circuiting never
      # reaches that clause).
      def self.known_test?(name : String) : Bool
        KrikriJinja.default_known_test?(name) || KrikriJinja.default_known_test?(collection_member(name))
      end

      private def self.collection_member(name : String) : String
        name.count('.') >= 2 ? name.rpartition('.')[2] : name
      end

      # Parsed once per distinct template source and reused: the source is
      # the raw, not-yet-substituted task-param text (dozens to a few
      # hundred distinct strings per run, never per host or loop item), a
      # parsed node is immutable, and every render gets fresh variables.
      # Separate caches for the decoding and verbatim literal modes, since
      # that choice is made at parse time.
      @@jinja_template_cache = Hash(String, KrikriJinja::Nodes::TemplateNode).new
      @@jinja_decode_template_cache = Hash(String, KrikriJinja::Nodes::TemplateNode).new

      private def cached_template(source : String) : KrikriJinja::Nodes::TemplateNode
        cache = @decode ? @@jinja_decode_template_cache : @@jinja_template_cache
        cache[source] ||= KrikriJinja::Parser.parse(source, jinja_options)
      end

      private def jinja_options : KrikriJinja::LexerOptions
        KrikriJinja::LexerOptions.new(
          trim_blocks: true, lstrip_blocks: false, verbatim_expression_strings: !@decode
        )
      end

      # Render a template containing Jinja2 control structures, raising
      # on any failure instead of swallowing it - for a caller (like
      # `ExpressionEvaluator`'s own delegation branches) that wants to
      # fall back to a DIFFERENT rendering strategy on failure, rather
      # than `#render`'s own "give back the original unrendered text"
      # behavior, which would be actively wrong for a caller expecting a
      # real evaluated value.
      def render!(text : String) : String
        TimingProfile.measure("controller.jinja", "controller.jinja") do
          render_measured!(text)
        end
      end

      private def render_measured!(text : String) : String
        # The lazy variable scope is built once per renderer (@vars is
        # fixed for a renderer's lifetime) and shared with #evaluate_value!;
        # each render gets its own context, so a template's `{% set %}`
        # never leaks into a later render off the same renderer.
        #
        # Real Ansible's Templar always exposes `environment` as a Jinja
        # global mapped to the controller's OS environment (`os.environ`),
        # not the task/play `environment:` keyword. Set per render so it
        # reflects the live ENV (GROG.debug-variable's `{{ environment |
        # to_nice_json }}` debug idiom).
        environment = ENV.to_h.transform_values { |value| KrikriJinja::AnyValue.new(value) }
        KrikriJinja.default_engine.render_parsed(
          cached_template(text), {"environment" => KrikriJinja::AnyValue.new(environment)},
          resolver: jinja_resolver, undefined: KrikriJinja::Undefined.new(nil, chainable: true),
          host_context: jinja_host_context
        )
      end

      # Render a template containing Jinja2 control structures
      def render(text : String) : String
        render!(text)
      rescue e : KrikriJinja::TemplateError
        # An unknown FILTER or TEST name must never degrade to the
        # original unrendered text here: real Jinja2/Ansible hard-fails
        # the task at compile time ("No filter named 'X'." / "No test
        # named 'X'.", TemplateAssertionErrors), while the
        # swallow-to-original-text fallback below turned an unknown name
        # inside a `{% %}`-bearing value into silently-wrong downstream
        # output (sunfoxcz.dkim's `dkim_domains is not list`, where real
        # Ansible fails immediately with "No test named 'list'.").
        # Every other failure keeps the lenient give-back-the-text
        # behavior (a lenient-undefined `{% if %}` is deliberate here).
        if test_name = self.class.unknown_feature_name(e, "test")
          raise UnknownTestError.new("No test named '#{test_name}'.")
        end
        if filter_name = KrikriJinjaFilters.unknown_filter_name(e)
          # One last chance before the hard failure: a role-local (or
          # playbook-adjacent) `filter_plugins/*.py` may define it - real
          # Ansible loads those on the controller at template-compile
          # time. Registered on the shared engine, then rendered once
          # more; still unknown means registration did not take.
          if KrikriJinjaFilters.ensure_shared_python_filter(filter_name, @vars)
            begin
              return render!(text)
            rescue ex : KrikriJinja::TemplateError
              raise ex unless KrikriJinjaFilters.unknown_filter_name(ex)
            end
          end
          raise FilterEngine::UnknownFilterError.new("No filter named '#{filter_name}'.")
        end
        text
      rescue e : Krikri::FirstFoundLookupError | Krikri::PipeLookupError | Krikri::PythonLookupRunner::LookupError
        # Same reasoning as the unknown-filter case above: first_found's own
        # no-match failure is a hard task failure in real Ansible, never the
        # lenient give-back-the-text fallback (which turned it into the
        # "undefined" sentinel string at whatever consumer came next).
        # PipeLookupError likewise - a non-zero pipe-command exit is real
        # Ansible's hard task failure, never silent text passthrough.
        # PythonLookupRunner::LookupError likewise - a custom lookup plugin
        # that RAN and raised is real Ansible's own task failure (only an
        # unavailable mechanism degrades, and it degrades inside the
        # dispatch, never as this exception).
        raise e
      rescue
        # Return original text on failure
        text
      end

      # The test (or filter) name a krikri-jinja "unknown test" error names.
      def self.unknown_feature_name(error : KrikriJinja::TemplateError, kind : String) : String?
        message = error.message || return nil
        return nil unless message.includes?("unknown #{kind}")
        message.split('"')[1]?
      end

      # Evaluates *expr* (bare Jinja expression text, no surrounding
      # `{{ }}`) and returns its RAW structured result as `JSON::Any`
      # (nil for a genuinely undefined result - the same nilable
      # convention `VariableLookup#resolve`/`#resolve_simple`/etc.
      # already use) instead of `#render!`'s always-a-String output.
      #
      # `#render!` always produces a String - fine for a FINAL `{{ }}`
      # substitution, but wrong for a caller (like `ExpressionEvaluator`'s
      # delegation branches) that hands the result to something expecting
      # structured data, or that formats an Array/Hash result through this
      # codebase's own `VariableLookup#format_value` (its JSON-compact
      # style) so the internal "render sub-expression to a String,
      # `JSON.parse` it back" round trip keeps working.
      #
      # Evaluated by krikri-jinja against the same lazy variable scope the
      # task-param path always had (JinjaVarResolver), with Ansible's
      # chainable lenient undefined and the inline-literal escape handling
      # #shared_env picks (verbatim for task params, decoded for
      # `when:`/`assert:`).
      #
      # An unknown filter gets one chance to be a role-local (or
      # playbook-adjacent) `filter_plugins/*.py` filter: it is registered
      # on the shared engine and the evaluation retried once. Anything else
      # is re-raised untouched so the caller's own fallback engages.
      # Without this gate a delegated chain's unknown-filter error reached
      # the hand-rolled fallback, whose suffix walk collapsed the whole
      # expression to "undefined" - diodonfrost.vagrant's `{{
      # (vagrant_index.content | from_json).versions | list |
      # sort_versions | last }}` (role-local filter_plugins/
      # sort_versions.py) rendered the literal string "undefined" into a
      # download URL while real ansible-playbook resolved 2.4.3.
      def evaluate_value!(expr : String) : JSON::Any?
        evaluate_value_once!(expr)
      rescue e : KrikriJinja::TemplateError
        name = KrikriJinjaFilters.unknown_filter_name(e)
        raise e unless name && KrikriJinjaFilters.ensure_shared_python_filter(name, @vars)
        evaluate_value_once!(expr)
      end

      # Parsed once per distinct expression source (task-param template
      # strings number in the dozens to hundreds per run, never per host or
      # loop item) and reused: a parsed node is immutable, and every
      # evaluation gets fresh variables. Separate caches for the decoding
      # and verbatim literal modes, since that choice is made at parse time.
      @@jinja_expression_cache = Hash(String, KrikriJinja::Nodes::ExprNode).new
      @@jinja_decode_expression_cache = Hash(String, KrikriJinja::Nodes::ExprNode).new
      @jinja_resolver : JinjaVarResolver?
      @jinja_host_context : JinjaHostContext?

      private def jinja_resolver : JinjaVarResolver
        @jinja_resolver ||= JinjaVarResolver.new(@vars, VarSubstitutor.new(vars: @vars))
      end

      private def jinja_host_context : JinjaHostContext
        @jinja_host_context ||= JinjaHostContext.new(@vars)
      end

      private def evaluate_value_once!(expr : String) : JSON::Any?
        cache = @decode ? @@jinja_decode_expression_cache : @@jinja_expression_cache
        node = cache[expr] ||= KrikriJinja.parse_expression(
          expr, KrikriJinja::LexerOptions.new(verbatim_expression_strings: !@decode)
        )
        value = KrikriJinja.default_engine.evaluate_parsed(
          node, resolver: jinja_resolver,
          undefined: KrikriJinja::Undefined.new(nil, chainable: true), host_context: jinja_host_context
        )
        return nil if value.raw.is_a?(KrikriJinja::Undefined)

        JinjaRenderer.elide_omitted(KrikriJinja.to_json_any(value))
      end

      # Real Ansible's `omit` inside a CONTAINER removes that entry
      # rather than leaving a placeholder in it - verified against
      # ansible-core 2.19.4: `{{ [1, v_omit, 3] }}` renders `[1, 3]` and
      # `{{ {'a': 1, 'b': v_omit} }}` renders `{"a": 1}`. The engine builds
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
          JSON::Any.new(raw.reject { |item| item.as_s? == Krikri::OMIT_SENTINEL }
            .map { |item| elide_omitted(item) })
        when Hash
          kept = Hash(String, JSON::Any).new
          raw.each do |key, item|
            next if item.as_s? == Krikri::OMIT_SENTINEL
            kept[key] = elide_omitted(item)
          end
          JSON::Any.new(kept)
        else
          value
        end
      end

      # Guards against a genuine infinite-recursion trap distinct from
      # `VarSubstitutor`'s own `@@block_tag_escalation_depth`: that guard
      # bounds the RECURSION DEPTH of `substitute`/`render` calls, but
      # (back when variable preparation walked the whole of
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
      # (`JinjaVarResolver#resolve`) rather than per whole-hash
      # walk, this guard brackets one key's conversion instead of all of
      # them - strictly tighter than before (a recursion that used to
      # burn through N variables' worth of work per depth level now
      # burns through 1), so the existing cap of 3 stays just as safe,
      # not looser.
      @@prepare_vars_depth = 0
      MAX_PREPARE_VARS_DEPTH = 3

      # A variable's value after recursive re-templating, or nil when it is
      # undefined - what JinjaVarResolver hands the engine for *name*.
      def self.prepare_var(raw_value : JSON::Any, substitutor : VarSubstitutor, name : String = "") : JSON::Any?
        # Resolved-value carve-out (0.9.1267 gap, same one
        # re_template_from_variable?/raise_if_strict_undefined apply):
        # a name published by build_vars_context as execution-resolved
        # (register:/set_fact:) holds VERBATIM content, not a template
        # level - the re-render below re-scanned brace text that real
        # ansible-core never re-scans on a resolved fact/module result
        # (a set_fact value containing literal `{{ ... }}` rendered to
        # the "undefined" sentinel / an undefined value here instead of
        # passing through as-is).
        if VarSubstitutor.resolved_var_name?(substitutor.host_name, name.split(/[\.\[]/, 2)[0])
          return raw_value
        end

        if @@prepare_vars_depth >= MAX_PREPARE_VARS_DEPTH
          return raw_value
        end

        # A variable whose own stored value is `{{ }}` text bottoming out
        # at a name set nowhere (`phpmyadmin_mysql_password: "{{
        # mysql_root_password }}"` with no `mysql_root_password`
        # anywhere) is UNDEFINED, not "defined, with the seven-character
        # value `undefined`" - which is what the lenient re-render below
        # otherwise hands the engine, since `VarSubstitutor#substitute`
        # renders any unresolved lookup as that literal sentinel text.
        # The engine then saw an ordinary non-empty string: `| default('x')`
        # returned "undefined" instead of "x", `is defined` was True
        # where real Ansible says False, and `when: v | default('') !=
        # ''` ran a task real Ansible skips.
        #
        # Returning nil (an undefined value to the engine) instead lets
        # Jinja's OWN undefined semantics answer all three, which is exactly
        # what they exist for - no sentinel string doing double duty.
        # The complementary half (a STRICT caller - module-arg
        # finalization - failing the task rather than rendering
        # anything) is `VarSubstitutor#raise_if_nested_value_undefined`,
        # which fires before this conversion is ever reached.
        if (raw = raw_value.raw).is_a?(String) && substitutor.unresolvable_template?(raw)
          return nil
        end

        @@prepare_vars_depth += 1
        begin
          rerender_nested_templates(raw_value, substitutor)
        ensure
          @@prepare_vars_depth -= 1
        end
      end

      # The `hostvars` magic variable: every host's vars re-templated,
      # under the same depth guard.
      def self.prepare_hostvars(raw_value : JSON::Any, substitutor : VarSubstitutor) : JSON::Any
        @@prepare_vars_depth += 1
        begin
          hosts = raw_value.as_h? || return raw_value
          JSON::Any.new(hosts.transform_values { |entry| rerender_nested_templates(entry, substitutor) })
        ensure
          @@prepare_vars_depth -= 1
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
      # Exposed as a class method so FilterEngine and ExpressionEvaluator
      # apply the identical recursive re-render.
      # Narrow special case for one specific idiom (found round 755/753,
      # `jtyr.nsswitch`/`jtyr.motd`): `some_var: "{{ some_dict.update(
      # other_dict) }}{{ some_dict }}"` - call `.update()` purely for its
      # mutating side effect, discard its `None` return, then render the
      # now-merged dict. Real Ansible's templar preserves the result as
      # a genuine dict (`_AnsibleLazyTemplateDict`, private ansible-core
      # internals - see KNOWN_MISSING.md's own writeup); replicating
      # that faithfully (deferred evaluation + type preservation through
      # the whole vars pipeline) is a major architectural undertaking,
      # not attempted here. This instead special-cases exactly the
      # documented shape - both operands bare variable names, no
      # arbitrary Jinja expression inside `.update(...)` - by reading
      # both from the vars store directly, merging (matching Python
      # dict.update's own shallow-merge, top-level-key-overrides
      # semantics), and persisting the merge back onto the target
      # variable (matching Python's real in-place mutation, visible to
      # any LATER reference of it too - not just this one). Falls
      # through to the general string-rendering path below for anything
      # that doesn't match this exact shape.
      UPDATE_THEN_REREAD_RE = /\A\{\{\s*([A-Za-z_]\w*)\.update\(\s*([A-Za-z_]\w*)\s*\)\s*\}\}\{\{\s*\1\s*\}\}\z/

      # defer_unresolved: when set, a nested leaf whose template bottoms out
      # at a name set nowhere is left in its raw, unrendered form instead of
      # raising - real Jinja2/Ansible templates a container's values LAZILY,
      # on actual access, so a filter chain that never reads a leaf
      # (`mylist | selectattr('state', ...)` never touching a sibling `name:`
      # whose template references an intentionally-undefined caller var,
      # round 952484 / stackhpc.libvirt-vm) must not fail the whole chain on
      # it. The default (false) keeps the pre-existing strict behavior for
      # every caller that renders a structure as a WHOLE (variable-scope
      # conversion, the to_json-family guards in FilterEngine) - those
      # access every leaf by definition, where real Ansible fails just as
      # this strict path does. A deferred leaf that IS later accessed is
      # rendered strictly at its access point (FilterEngine's map/selectattr
      # attribute extraction), restoring fail-on-access semantics there.
      private def self.rerender_string_value(raw : String, value : JSON::Any, substitutor : VarSubstitutor, defer_unresolved : Bool = false) : JSON::Any
        if merged = update_then_reread_merge(raw, substitutor)
          return merged
        end

        # `{%`/`{#` need the same re-render as `{{`: a variable whose own
        # value is a pure block-tag template (`traefik_install_ver: '{% if
        # traefik_ver.major | int >= 2 %}2{% else %}{{ traefik_ver.major
        # }}{% endif %}'`, round 200 andrewrothstein.traefik) used to reach
        # the engine's scope still raw whenever the OUTER re-pass loop could
        # not save it - most notably as a FILTER-CHAIN head (`{{
        # traefik_install_ver | upper }}` applied `upper` to the literal
        # `{% IF FLAG %}...{% ENDIF %}` text, mangling the tag keywords so
        # no later pass could ever parse them) and as a `default()`
        # argument. The outer loop only sees the ALREADY-filtered result,
        # so the re-render has to happen here, at conversion time, for
        # every construct that reads the variable through the engine's
        # context.
        unless raw.includes?("{{") || raw.includes?("{%") || raw.includes?("{#")
          return value
        end
        # strict: true - a nested leaf that is a BARE/dotted reference to a
        # name set nowhere must FAIL the whole render ("'x' is undefined"),
        # not collapse to this engine's literal "undefined" sentinel text
        # and get serialized as ordinary content. Found via a role
        # `my_config: {foo: {bar: "{{ some_undefined_var }}"}}` fed through
        # `{{ my_config | to_json }}`/`| to_nice_yaml`: real ansible-playbook
        # fails immediately (it templates every nested string value at every
        # level, strictly), while krikri quietly wrote
        # {"foo":{"bar":"undefined"}}. This one call site is shared by BOTH
        # evaluators - the engine's variable preparation (prepare_var) AND the
        # hand-rolled FilterEngine path (ExpressionEvaluator's
        # retemplated_lookup_value -> rerender_nested_templates) - so a
        # filter like to_json on a dict with an undefined nested leaf fails
        # identically either way. substitute's own strictness already
        # forgives exactly what real Ansible does: `default()`/`d()`-guarded
        # leaves, `omit`, literals, operators (raise_if_strict_undefined's
        # own bare-ref rule), so deliberately-lenient nested values keep
        # rendering.
        begin
          rendered = substitutor.substitute(raw, strict: true)
        rescue e : Krikri::UndefinedVariableError
          # The defer_unresolved carve-out: see rerender_nested_templates.
          # Returns the leaf in its raw, still-templated form so a chain
          # that never touches it (real Jinja2's laziness) succeeds; any
          # access point that actually reads the leaf renders it strictly
          # and fails exactly like the pre-laziness behavior did.
          return value if defer_unresolved
          raise e
        end
        stripped = raw.strip
        if stripped.starts_with?("{{") && stripped.ends_with?("}}")
          render_pure_mustache_value(rendered, stripped, substitutor)
        else
          JSON::Any.new(rendered)
        end
      end

      # The `{{ dict.update(other) }}{{ dict }}` mutate-for-side-effect-
      # then-reread idiom (both operands bare names): perform dict.update's
      # own shallow-merge, top-level-key-overrides semantics, and persist
      # the merge back onto the target variable (matching Python's real
      # in-place mutation, visible to any LATER reference of it too - not
      # just this one). Returns nil for anything that doesn't match this
      # exact shape, so the caller falls through to the general
      # string-rendering path.
      private def self.update_then_reread_merge(raw : String, substitutor : VarSubstitutor) : JSON::Any?
        m = UPDATE_THEN_REREAD_RE.match(raw.strip) || return nil
        target_name, arg_name = m[1], m[2]
        target = substitutor.vars[target_name]?
        arg = substitutor.vars[arg_name]?
        return nil unless target && target.raw.is_a?(Hash) && arg && arg.raw.is_a?(Hash)

        # Each dict's OWN values need the same recursive re-render
        # every other nested-template value in this codebase gets
        # (see #rerender_nested_templates just below) - found live
        # via jtyr.nsswitch's real `nsswitch__default` (round
        # confirm-860s): every one of its values is itself a bare
        # `{{ nsswitch_passwd }}`-style indirection to a real list.
        # Merging the RAW dict (unrendered `{{ }}` text still in
        # every value) silently corrupted the rendered
        # /etc/nsswitch.conf - `{{ val | join(' ') }}` treated the
        # literal template text as a string and iterated its
        # CHARACTERS, one per line, which broke NSS `passwd:`
        # resolution (and `sudo`, and the whole host) instead of
        # raising anything - confirmed on a real host before this
        # fix, not merely theorized.
        merged = rerender_nested_templates(target, substitutor).as_h.dup
        rerender_nested_templates(arg, substitutor).as_h.each { |key, val| merged[key] = val }
        merged_json = JSON::Any.new(merged)
        substitutor.vars[target_name] = merged_json
        merged_json
      end

      # A nested-template variable whose ENTIRE value (no other
      # literal characters around it) is a `{{ }}` expression
      # can itself render to a real array/dict
      # (`docker_pip_packages: "{{
      # _docker_pip_packages[ansible_facts['os_family']] |
      # default(...) }}", robertdebock.docker's own vars/main.
      # yml) - substitutor.substitute always returns a formatted
      # STRING, so without re-parsing back to JSON here every
      # such variable silently became a String-typed template
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
      # this JSON.parse-back step; this one (feeding the engine's
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
      # Exactly "True"/"False"/"None" however IS safe to re-type natively:
      # those are Python's own repr of a boolean/None, and real Ansible's
      # templar preserves a whole-single-template value's native TYPE
      # (`__postfix_debian: "{{ ansible_os_family == 'Debian' }}"` in
      # galaxyproject.postfix's defaults/main.yml is a genuine False on a
      # RedHat host, round 812025), so a variable referenced FROM another
      # expression must come out as a real bool there. This converter
      # (feeding the engine's vars scope) was the one rerender site that
      # never did: the string "False" is non-empty and therefore always
      # TRUTHY to Jinja, so a nested ternary conditioned on it
      # (`__postfix_packages: "{{ debian_pkgs if __postfix_debian else
      # (...) }}"`) picked the first (Debian) branch on every host -
      # krikri tried to `dnf install` `bsd-mailx`/`amavisd-new` on Rocky
      # where real ansible-playbook cleanly installed the RedHat list.
      # Exact-match only, so the quoted-string repro case above (and any
      # string that merely begins with those letters) is untouched.
      private def self.render_pure_mustache_value(rendered : String, stripped : String, substitutor : VarSubstitutor) : JSON::Any
        stripped_rendered = rendered.strip
        if stripped_rendered.starts_with?('[') || stripped_rendered.starts_with?('{')
          # A container literal built from a Python-style dict/set
          # expression (`{ 'Virtual': v } if cond else { 'X': y }`,
          # jtyr.motd's own motd_info__default) finalizes to
          # single-quoted Python-repr text ("{'Virtual': 'NO'}"),
          # which is not valid JSON - JSON.parse fails, and used to
          # fall all the way back to a plain STRING here, so a later
          # `{% for key, value in item %}` over it crashed with
          # "cannot unpack multiple values" instead of seeing the
          # real dict (confirmed live against a real host running
          # jtyr.motd). Falling back to a genuine STRUCTURAL
          # evaluation (`evaluate_value!`, already used elsewhere for
          # exactly this "get the real structured value, not a
          # stringify-then-reparse round trip" need) instead of
          # giving up to a plain string recovers the real
          # array/dict without the JSON-text detour at all.
          inner = stripped[2..-3].strip
          (JSON.parse(rendered) rescue nil) ||
            (JinjaRenderer.new(substitutor.vars).evaluate_value!(inner) rescue nil) ||
            JSON::Any.new(rendered)
        elsif stripped_rendered.in?("True", "False", "None")
          Krikri.parse_json_or_python_literal(stripped_rendered)
        else
          JSON::Any.new(rendered)
        end
      end

      def self.rerender_nested_templates(value : JSON::Any, substitutor : VarSubstitutor, defer_unresolved : Bool = false) : JSON::Any
        case raw = value.raw
        when String
          rerender_string_value(raw, value, substitutor, defer_unresolved)
        when Array
          JSON::Any.new(raw.map { |item| rerender_nested_templates(item, substitutor, defer_unresolved) })
        when Hash
          JSON::Any.new(raw.transform_values { |item| rerender_nested_templates(item, substitutor, defer_unresolved) })
        else
          value
        end
      end
    end
  end
end
