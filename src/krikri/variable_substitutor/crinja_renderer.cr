require "../timing_profile"
require "json"
require "crinja"
require "../variable_substitutor"
require "../python_filter_runner"
require "../python_lookup_runner"
require "../crinja_strict_undefined"
require "../crinja_string_index"
require "../crinja_bool_arithmetic"
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

    # CrinjaRenderer - Handles full Jinja2 template rendering using Crinja
    # This includes {% if %}, {% for %}, {% set %}, etc.
    class CrinjaRenderer
      @vars : Hash(String, JSON::Any)
      @template_context : Crinja::Context?
      # When true, string-literal escapes are decoded (vanilla Jinja
      # semantics) instead of passed through verbatim. Only the
      # conditional/assert path sets this; inline task-param `{{ }}`
      # templating keeps it false. See #shared_env and the class comment
      # on shared_environment for why the two contexts differ.
      @decode : Bool

      def initialize(@vars : Hash(String, JSON::Any), @decode : Bool = false)
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
      @@decode_env : Crinja?

      private def shared_env : Crinja
        @decode ? self.class.decoding_environment : self.class.shared_environment
      end

      # Class-level twin of #shared_env so callers without a renderer
      # instance can consult this environment's own feature libraries -
      # ConditionalEvaluator's compile-time filter-name pre-pass asks it
      # whether a `| name` in a `when:` is one Crinja itself implements
      # (including aliases), since FilterEngine.apply is only ever the
      # fallback path behind Crinja-native filters.
      def self.shared_environment : Crinja
        @@env ||= build_environment(verbatim: true)
      end

      # The conditional/assert twin of #shared_environment: identical in
      # every respect except `verbatim_expression_strings`, which is off so
      # string-literal escapes in a `when:`/`assert:` expression decode the
      # way vanilla Jinja (and real ansible-core's condition compiler) does
      # them - e.g. `x.split('\n')` splits on a real newline and `y ~ '\n'`
      # concatenates one, matching real, where inline task-param templating
      # keeps them literal. Separate template/expression caches (see
      # #cached_template / #cached_expression) because the setting is
      # consumed at PARSE time, so the same source must not be shared
      # between the two.
      def self.decoding_environment : Crinja
        @@decode_env ||= build_environment(verbatim: false)
      end

      private def self.build_environment(verbatim : Bool) : Crinja
        env = Crinja.new
        env.config.trim_blocks = true
        env.config.lstrip_blocks = false
        # Everything this class renders is INLINE task-param templating -
        # `{{ }}` in YAML task args (bare expression or embedded in a
        # longer string) - never a `.j2` template file (that path owns its
        # own per-render environment in TemplateActionPlugin). Real
        # ansible-core 2.19 does NOT decode string-literal escapes inline:
        # its own AnsibleLexer doubles every backslash before Jinja's
        # `unicode-escape` decode, netting exact passthrough, while `{% %}`
        # statement literals (and template files) still decode fully -
        # live-verified against 2.19.11: `{{ 'V\1-\2' }}` renders the
        # literal six characters (not the octal-escape corruption
        # V<0x01>-<0x02>), a `regex_replace` replacement keeps a working
        # `\1` backreference, `'a\nb' | length` is 4, and the same probes
        # inside `{% %}` DO decode (`{% set z = 'a\nb' %}` holds a real
        # newline). crystal-play-0.9.58's verbatim_expression_strings
        # implements exactly that split in the fork's lexer; without it,
        # digit escapes read as octal and decoded real newlines/tabs where
        # real Ansible passed the backslash through. (Replaces the old
        # preserve_inline_string_escapes re-encoding workaround, which
        # papered over this at a single call site - and which would now
        # corrupt output by leaving `\x5C` text in place.)
        env.config.verbatim_expression_strings = verbatim
        # Real Jinja2's `default` filter only ever triggers on an
        # UNDEFINED value - a DEFINED None passes straight through
        # (live-verified against ansible-core 2.19.11:
        # `{{ nv | default('') }}` with `nv: ~` set_fact's null, not
        # ''). Crinja's builtin instead also triggers on nil, which
        # made `enablerepo: "{{ item.enablerepo | default('') }}"` (the
        # officel.httpd shape, round 900905) collapse a real Python
        # None to an empty string both when rendering and in the
        # whole-span null detection that feeds yum/dnf's argument-spec
        # NoneType check - where real ansible-playbook fails the task.
        # The boolean form keeps triggering on falsy values (None
        # included), exactly like real Jinja2's `default(x, true)`.
        # The hand-rolled FilterEngine keeps its own nil-as-undefined
        # semantics (its nil is the engine's internal lookup-miss
        # representation, indistinguishable from a real None by the
        # time a filter sees it) - the two evaluators share no
        # implementation, see CLAUDE.md.
        default_filter = Crinja.filter({default_value: "", boolean: false}) do
          default_value = arguments["default_value"]
          if target.undefined? || (arguments["boolean"].truthy? && !target.truthy?)
            default_value
          else
            target
          end
        end
        env.filters["default"] = default_filter
        env.filters["d"] = default_filter
        env
      end

      # True if *name* resolves in the shared environment's filter
      # library - a registered filter or a registered alias for one
      # (FeatureLibrary#[] downcases lookups and resolves aliases the
      # same way, so this mirrors exactly what a render would find).
      def self.known_filter?(name : String) : Bool
        lookup = name.downcase
        library = shared_environment.filters
        library.keys.includes?(lookup) || library.aliases.has_key?(lookup)
      end

      # True if *name* resolves in the shared environment's TEST
      # library - the test-side twin of #known_filter? above, for
      # ConditionalEvaluator's compile-time test-name pre-pass (an
      # unknown `is <name>` in a `when:` must hard-fail even when
      # and/or short-circuiting never reaches that clause).
      def self.known_test?(name : String) : Bool
        lookup = name.downcase
        library = shared_environment.tests
        library.keys.includes?(lookup) || library.aliases.has_key?(lookup)
      end

      # If *name* is exposed by a role-local (or playbook-adjacent)
      # `filter_plugins/*.py` for the role context in *vars*, register
      # a dynamic Crinja filter dispatching to the controller's python3
      # (see PythonFilterRunner) into the shared environment's filter
      # library and return true - so both this render path and
      # #known_filter? (ConditionalEvaluator's compile-time pre-pass)
      # resolve it from here on. False when no plugin source defines
      # the name (or the mechanism is unavailable), leaving the caller
      # to raise the plain unknown-filter error.
      def self.ensure_python_filter?(name : String, vars : Hash(String, JSON::Any), env : Crinja = shared_environment) : Bool
        role_path = vars["role_path"]?.try(&.as_s?)
        playbook_dir = vars["playbook_dir"]?.try(&.as_s?)
        return false unless role_path || playbook_dir

        sources = PythonFilterRunner.find_sources(role_path, playbook_dir)
        return false if sources.empty?
        return false unless PythonFilterRunner.defines_filter?(name, sources)

        register_python_filter_instance(name, env)
        true
      end

      # Registers the dynamic dispatching filter under *name* into
      # *env* (the shared `{{ }}`-path environment by default, or a
      # real `.j2` template's own standalone `Crinja.new` - see
      # TemplateActionPlugin#render_template, which builds a fresh
      # environment per render and never shares this class's own, so
      # the shared-environment registration alone never reaches it).
      # The plugin sources are re-resolved from the RENDERING
      # environment's own context at each call (`env.context`'s
      # role_path/playbook_dir magic vars), not captured at
      # registration time - a shared environment outlives any single
      # role, so a stale capture could dispatch a later role's filter
      # to the wrong (already-finished) role's plugin file.
      def self.register_python_filter_instance(name : String, env : Crinja = shared_environment) : Nil
        instance = Crinja.filter do
          target = arguments.target!
          render_env = arguments.env

          role_value = render_env.context["role_path"]
          playbook_value = render_env.context["playbook_dir"]
          role_path = role_value.undefined? ? nil : role_value.to_s
          playbook_dir = playbook_value.undefined? ? nil : playbook_value.to_s

          sources = Krikri::PythonFilterRunner.find_sources(role_path, playbook_dir)
          value = crinja_value_to_json_any(target)
          pos_args = arguments.varargs.map { |arg| crinja_value_to_json_any(arg) }
          kwargs = arguments.kwargs.each_with_object(Hash(String, JSON::Any).new) do |(key, val), hash|
            hash[key] = crinja_value_to_json_any(val)
          end

          if sources.empty? || !Krikri::PythonFilterRunner.defines_filter?(name, sources)
            raise Crinja::RuntimeError.new("No filter named '#{name}'.")
          end
          # The rendering environment's own context vars ride along so a
          # @pass_context-decorated filter gets a Context stub that can
          # resolve them (see PythonFilterRunner's header). Undefined
          # entries are skipped - they carry no look-up-able value.
          context_vars = Hash(String, JSON::Any).new
          render_env.context.keys.each do |key|
            context_value = render_env.context[key]
            next if context_value.undefined?
            context_vars[key] = crinja_value_to_json_any(context_value)
          end
          json_any_to_crinja_value(
            Krikri::PythonFilterRunner.call_filter(name, sources, value, pos_args, kwargs, context_vars)
          )
        end
        env.filters[name.downcase] = instance
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
        TimingProfile.measure("controller.crinja", "controller.crinja") do
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
            rescue retry_error : KrikriJinja::TemplateError
              raise retry_error unless KrikriJinjaFilters.unknown_filter_name(retry_error)
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

      # Parses Crinja's own unknown-feature error wording ("no filter/
      # test with name ... registered") into {kind, name}, for #render's
      # rescue.
      def self.unknown_feature(e : Crinja::FeatureLibrary::UnknownFeatureError) : {String, String}?
        match = e.message.try(&.match(/no (filter|test) with name "([^"]+)" registered/))
        match ? {match[1], match[2]} : nil
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
      # Crinja context provides (JinjaVarResolver), with Ansible's
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

        CrinjaRenderer.elide_omitted(KrikriJinja.to_json_any(value))
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
        when HostVarsVarsDict
          # Krikri's hostvars wrapper (a Crinja::Object, so the generic
          # Object case below would stringify it): converts to the
          # host's plain dict, so an extract result containing it (e.g.
          # `x | extract(hostvars)` with no morekeys) crosses into
          # JSON-shaped rendering as a real mapping, not a repr string.
          hash = Hash(String, JSON::Any).new
          raw.each { |k, v| hash[k] = crinja_value_to_json_any(v) }
          JSON::Any.new(hash)
        when Crinja::Dictionary
          hash = Hash(String, JSON::Any).new
          raw.each { |k, v| hash[k.to_s] = crinja_value_to_json_any(v) }
          JSON::Any.new(hash)
        when Array(Crinja::Value)
          JSON::Any.new(raw.map { |item| crinja_value_to_json_any(item) })
        when Crinja::Tuple
          # Real ansible-core's native-types finalization converts Python
          # tuples to lists at every output position (verified 2.19.4:
          # `{{ (1, 2) }}` -> `[1, 2]`, `zip`/`dictsort` results are
          # bracketed lists) - so a tuple crossing from Crinja into this
          # engine's JSON world becomes an array, never the paren-repr
          # string the old `else` fallback produced (`["('a', 1)", ...]`
          # for a `{{ d1 | dictsort }}` span; found via the round-306
          # follow-up verification). The fork's own Finalizer got the
          # matching fix for the raw-.j2-text path (crystal-play-0.9.26).
          JSON::Any.new(raw.to_a.map { |item| crinja_value_to_json_any(item) })
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
        # `hostvars` gets the HostVarsVars treatment: each host's vars
        # dict converts into a Krikri::HostVarsVarsDict whose subscript
        # miss raises under strict templating, matching real Ansible's
        # own raising wrapper (see HostVarsVarsDict's comment for the
        # found-live divergence this closes). Conversion reuses the
        # same re-render + depth guard as any other var.
        return convert_hostvars(raw_value, substitutor) if name == "hostvars"

        prepared = prepare_var(raw_value, substitutor, name)
        prepared ? json_any_to_crinja_value(prepared) : Crinja::Value.new(Crinja::Undefined.new(name))
      end

      # The engine-neutral half of #convert_var: the variable's value after
      # recursive re-templating, or nil when it is undefined. Shared by the
      # Crinja context and the krikri-jinja resolver.
      def self.prepare_var(raw_value : JSON::Any, substitutor : VarSubstitutor, name : String = "") : JSON::Any?
        # Resolved-value carve-out (0.9.1267 gap, same one
        # re_template_from_variable?/raise_if_strict_undefined apply):
        # a name published by build_vars_context as execution-resolved
        # (register:/set_fact:) holds VERBATIM content, not a template
        # level - the re-render below re-scanned brace text that real
        # ansible-core never re-scans on a resolved fact/module result
        # (a set_fact value containing literal `{{ ... }}` rendered to
        # the "undefined" sentinel / Crinja::Undefined here instead of
        # passing through as-is).
        if VarSubstitutor.resolved_var_name?(substitutor.host_name, name.split(/[\.\[]/, 2)[0])
          return raw_value
        end

        if @@prepare_crinja_vars_depth >= MAX_PREPARE_CRINJA_VARS_DEPTH
          return raw_value
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
          return nil
        end

        @@prepare_crinja_vars_depth += 1
        begin
          rerender_nested_templates(raw_value, substitutor)
        ensure
          @@prepare_crinja_vars_depth -= 1
        end
      end

      # Converts the `hostvars` magic variable with each host's vars
      # dict wrapped in Krikri::HostVarsVarsDict (see that class's own
      # comment). Shared by BOTH Crinja context builds that can carry
      # hostvars - LazyCrinjaContext#convert (the `{% %}`/`{{ }}`
      # evaluator's lazy context, via #convert_var) and the template
      # module's eager env (template_action_plugin.cr) - so a raising
      # attribute miss behaves identically in a `.j2` file and a
      # module-arg render.
      def self.convert_hostvars(raw_value : JSON::Any, substitutor : VarSubstitutor) : Crinja::Value
        @@prepare_crinja_vars_depth += 1
        begin
          top = Hash(String, Crinja::Value).new
          raw_value.as_h?.try do |hosts|
            hosts.each do |host, entry|
              top[host] = wrap_host_vars_entry(
                json_any_to_crinja_value(rerender_nested_templates(entry, substitutor)),
              )
            end
          end
          Crinja::Value.new(top)
        ensure
          @@prepare_crinja_vars_depth -= 1
        end
      end

      # JSON counterpart of #convert_hostvars for the krikri-jinja resolver:
      # every host's vars re-templated, under the same depth guard.
      def self.prepare_hostvars(raw_value : JSON::Any, substitutor : VarSubstitutor) : JSON::Any
        @@prepare_crinja_vars_depth += 1
        begin
          hosts = raw_value.as_h? || return raw_value
          JSON::Any.new(hosts.transform_values { |entry| rerender_nested_templates(entry, substitutor) })
        ensure
          @@prepare_crinja_vars_depth -= 1
        end
      end

      # json_any_to_crinja_value hands back a plain Crinja::Dictionary
      # (Crinja.value normalizes every Hash), so the dictionary shape is
      # what gets matched here, not Hash(String, Value).
      private def self.wrap_host_vars_entry(converted : Crinja::Value) : Crinja::Value
        if hash = converted.raw.as?(Crinja::Dictionary)
          entries = Hash(String, Crinja::Value).new
          hash.each { |key, value| entries[key.to_string] = value }
          Crinja::Value.new(HostVarsVarsDict.new(entries))
        else
          converted
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
      # every caller that renders a structure as a WHOLE (Crinja context
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
        # Crinja's context still raw whenever the OUTER re-pass loop could
        # not save it - most notably as a FILTER-CHAIN head (`{{
        # traefik_install_ver | upper }}` applied `upper` to the literal
        # `{% IF FLAG %}...{% ENDIF %}` text, mangling the tag keywords so
        # no later pass could ever parse them) and as a `default()`
        # argument. The outer loop only sees the ALREADY-filtered result,
        # so the re-render has to happen here, at conversion time, for
        # every construct that reads the variable through Crinja's own
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
        # evaluators - Crinja's own context conversion (convert_var) AND the
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
      # Exactly "True"/"False"/"None" however IS safe to re-type natively:
      # those are Python's own repr of a boolean/None, and real Ansible's
      # templar preserves a whole-single-template value's native TYPE
      # (`__postfix_debian: "{{ ansible_os_family == 'Debian' }}"` in
      # galaxyproject.postfix's defaults/main.yml is a genuine False on a
      # RedHat host, round 812025), so a variable referenced FROM another
      # expression must come out as a real bool there. This converter
      # (feeding Crinja's own vars context) was the one rerender site that
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
          # jtyr.motd). Falling back to a genuine STRUCTURAL Crinja
          # evaluation (`evaluate_value!`, already used elsewhere for
          # exactly this "get the real Crinja::Value, not a
          # stringify-then-reparse round trip" need) instead of
          # giving up to a plain string recovers the real
          # array/dict without the JSON-text detour at all.
          inner = stripped[2..-3].strip
          (JSON.parse(rendered) rescue nil) ||
            (CrinjaRenderer.new(substitutor.vars).evaluate_value!(inner) rescue nil) ||
            JSON::Any.new(rendered)
        elsif stripped_rendered.in?("True", "False", "None")
          Krikri.parse_json_or_python_literal(stripped_rendered)
        else
          JSON::Any.new(rendered)
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
