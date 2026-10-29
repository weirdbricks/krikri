require "json"
require "../collection_index"

module Krikri
  module VariableSubstitutor
    # `lookup(...)`/`query(...)` dispatch entry points and shared helpers -
    # extracted verbatim from expression_evaluator.cr (lookup-dispatch split).
    class ExpressionEvaluator
      # `lookup('first_found', params)` - only the "first_found" lookup
      # type is supported (the one linux-system-roles actually uses, for
      # OS-version-specific vars files); any other lookup type resolves
      # to "undefined" rather than raising, matching how every other
      # unsupported construct in this evaluator degrades.

      # A `lookup(...)`/`query(...)` argument that is itself a quoted
      # string literal CONTAINING a `{{ }}` span (`lookup('file', "{{
      # tomcat_local_tmp_directory }}/apache-tomcat-{{ tomcat_version
      # }}.tar.gz.sha512")`) needs that inner span rendered before the
      # lookup runs - Ansible supports this "double templating"
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
      # tomcat_version }}.tar.gz.sha512").splitlines() | ... }}'` -
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
      # ansible-core 2.19's warning for exactly the double-templated
      # literal rendered below: a template-looking string CONSTANT inside
      # an expression (jinja_bits.py's _access_const) is tagged
      # _JinjaConstTemplate and re-rendered when the lookup runs, warning
      # once per constant at lookup-terms processing with the Origin
      # inherited from the value being templated - for module-arg
      # finalization that origin is the task param's VALUE position
      # (live-verified vs 2.19.11 alongside the rest of the block shape).
      # The evaluator has no task context of its own, so the executor
      # registers the (task, param key) being finalized on the current
      # fiber (VarSubstitutor#current_task_param); with no registration
      # (var files, template files, when:/name: routes - the is_conditional
      # variant among them) nothing is emitted, best-effort like the rest
      # of this evaluator's Origin work. Dedup per
      # distinct Origin per run - the message and help text are constants,
      # so the Origin is the only variable part of real's formatted
      # [WARNING] block, which is what Display._deduplicate keys on;
      # concurrent per-host finalizations share the set, hence the mutex
      # (same reason as RESERVED_SET_FACT_WARN_MUTEX).
      @@jinja_const_template_warned = Set(String).new
      JINJA_CONST_TEMPLATE_WARN_MUTEX = Mutex.new

      # Public because the krikri-jinja engine's own lookup-terms re-render
      # (krikri_jinja_lookups.cr's prepare_lookup_terms - the native-typed
      # whole-span route set_fact values and debug msgs take) renders the
      # same constants the same way and must warn the same way.
      def self.emit_jinja_const_template_warning : Nil
        return unless site = VarSubstitutor.current_task_param
        return unless origin = ResultDisplay.param_value_origin(site.source_file, site.source_line, site.key)
        JINJA_CONST_TEMPLATE_WARN_MUTEX.synchronize do
          return if @@jinja_const_template_warned.includes?(origin)
          @@jinja_const_template_warned << origin
          STDERR.puts "[WARNING]: Jinja constant strings should not contain embedded templates. This feature will be disabled by default in ansible-core 2.23."
          STDERR.puts origin
          STDERR.puts
          STDERR.puts "Use inline expressions, for example: `msg: \"{{ lookup('env', '{{ a_var }}') }}\"` becomes `msg: \"{{ lookup('env', a_var) }}\"`"
          STDERR.puts
        end
      end

      private def warn_jinja_const_embedded_template : Nil
        ExpressionEvaluator.emit_jinja_const_template_warning
      end

      # The null-file-term marker for the strings-only lookup-args wire (the
      # rerender below and lookup_file in lookup_file.cr are the only hands
      # it passes through): a private-use control character like
      # param_sentinels.cr's own sentinels, so no real role's lookup term -
      # a path, a glob, anything a playbook can write - can ever collide
      # with the equality check in lookup_file.
      LOOKUP_NONE_TERM = "\u{E000}lookup-none"

      # Whether *literal* (a quoted lookup term already proven to carry
      # `{{ }}`) is one top-level `{{ expr }}` span whose native value is
      # None. ansible-core keeps a whole-single-span constant's type through
      # the re-render (`{{ 42 }}` int, `{{ none }}` None - the same typing
      # rule variable values already ride), so a null variable's constant
      # reaches the lookup as REAL None - the structured whole-span probe
      # returns that as a JSON null, which #render!'s always-a-String output
      # would have flattened to "" where None and empty are
      # indistinguishable (live-verified vs 2.19.11). A probe that fails
      # (a genuinely undefined or otherwise unevaluable term) keeps
      # today's behavior: the caller falls through to #render!.
      private def sole_span_none_value?(literal : String) : Bool
        stripped = literal.strip
        return false unless VarSubstitutor.single_top_level_span?(stripped)
        return false if stripped.includes?(".update(")
        value = Rerender.whole_span_structured(@vars, stripped) rescue return false
        value.try { |structured| structured.raw.nil? } || false
      end

      private def rerender_double_templated_literal(part : String, null_carry_file_lookup : Bool = false) : String
        stripped = part.strip
        return part unless literal = sole_quoted_literal?(stripped)
        return part unless literal.includes?("{{") && literal.includes?("}}")

        quote = stripped[0]
        warn_jinja_const_embedded_template
        # Only the file lookup type carries the None through (see the
        # caller for the spelling list): every other lookup type keeps
        # exactly its pre-fix ""-rendered term, since the None term's
        # warning/error shape is the file plugin's own.
        if null_carry_file_lookup && sole_span_none_value?(literal)
          return LOOKUP_NONE_TERM
        end
        rendered = jinja_renderer.render!(literal)
        # A render that comes back CONTAINER-shaped (the term named a list
        # or dict variable, so the render emits its Python repr or JSON
        # text, `['a', 'b']` / `{"k": "v"}`) must NOT be re-wrapped in the
        # original quote character: the repr's own interior quote
        # characters then break `sole_quoted_literal?` on the
        # re-evaluation pass, the whole term degrades to the "undefined"
        # sentinel, and a `query('flattened', '{{ pkg_list }}')` term fed
        # its consumer a single item literally named "undefined" -
        # rhaamo.snmpd's apt task ran `install '['undefined']'` (round
        # 5460199; ansible-core templates the term and flattens the REAL
        # list). The un-mangled original is left for
        # #evaluate_lookup_term, which re-renders it and recovers the
        # container's native type.
        return part if rerender_container_shaped?(rendered)
        "#{quote}#{rendered}#{quote}"
      rescue
        part
      end

      private def rerender_container_shaped?(rendered : String) : Bool
        case Krikri.parse_json_or_python_literal(rendered).raw
        when Array, Hash then true
        else                  false
        end
      end

      # Splits a lookup/query call's comma-split argument list into its
      # positional terms (including the leading lookup-type literal) and
      # its trailing `key=value`-shaped keyword arguments (`wantlist=True`,
      # `errors='ignore'`). Ansible's lookup runner pulls those
      # kwargs out as lookup-plugin OPTIONS before the plugin ever sees
      # its terms - previously they stayed mixed into the positional
      # parts, so e.g. `lookup('nested', a, b, wantlist=True)` fed the
      # non-list kwarg into the Cartesian product and collapsed it to
      # zero rows (any list x empty = empty) - found live benchmarking
      # weakcamel.loki. Only TRAILING kwargs are stripped (Ansible's
      # own restriction); index 0 (the lookup type) is never stripped.
      private def split_lookup_keyword_args(parts : Array(String)) : Tuple(Array(String), Array(String))
        boundary = parts.size
        while boundary > 1 && parts[boundary - 1].strip.matches?(/^\w+\s*=/)
          boundary -= 1
        end
        {parts[0, boundary], parts[boundary..]}
      end

      private def evaluate_lookup(args : String, query_mode : Bool = false) : String
        raw_parts = split_top_level_commas(args)
        # The type as the raw split sees it, before the term rerender below
        # touches anything: the None-carry's file gate must know the dispatch
        # type spelled bare or fully-qualified (the same spellings the
        # subs below strip) while the lookup_type re-read right after stays
        # exactly where it already was - byte-identical for every non-null
        # term.
        raw_lookup_type = raw_parts[0]?.try { |part| quoted_string_literal(part.strip) }.try(&.as_s?)
        null_carry_file_lookup = raw_lookup_type.try(&.in?("file", "ansible.builtin.file", "ansible.legacy.file")) || false
        parts, kwargs = split_lookup_keyword_args(
          raw_parts.map { |part| rerender_double_templated_literal(part, null_carry_file_lookup) },
        )
        lookup_type = parts[0]?.try { |part| quoted_string_literal(part.strip) }.try(&.as_s?)

        # The name exactly as the role spelled it - the prefix strips below
        # must not leak into the not-found error message.
        original_lookup_type = lookup_type

        # Ansible accepts a lookup plugin's name either bare
        # ('first_found') or fully-qualified ('ansible.builtin.
        # first_found') - every `when "..."` case below only matches the
        # bare form. Without this, `lookup('ansible.builtin.first_found',
        # params)` (juju4.*'s own idiom across many of its roles) fell
        # through every case to the final "undefined" fallback, breaking
        # `include_vars: "{{ lookup('ansible.builtin.first_found',
        # params) }}"` outright regardless of whether any candidate file
        # actually existed.
        lookup_type = lookup_type.try(&.sub(/^ansible\.(builtin|legacy)\./, ""))

        # Same treatment for community.general.* - `lookup('community.
        # general.random_string', ...)` (juju4.pocketid's own secret
        # generation) must reach the bare-name case below rather than
        # falling through every dispatch to the "undefined" fallback.
        lookup_type = lookup_type.try(&.sub(/^community\.general\./, ""))

        # ansible-core templates every lookup term before the plugin runs, so
        # a bare undefined name fails the task with its own "'x' is undefined"
        # message; left alone it rendered the "undefined" sentinel and the
        # plugin ran on that literal text (`lookup('template', nope)`).
        parts.skip(1).each do |part|
          name = part.strip
          next unless name.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
          next if name.in?("True", "False", "None", "true", "false", "none")
          next if @vars.has_key?(name)
          raise UndefinedVariableError.new("'#{name}' is undefined")
        end

        evaluate_lookup_scalar(lookup_type, parts, kwargs, query_mode) ||
          evaluate_lookup_file(lookup_type, parts, kwargs) ||
          evaluate_lookup_list(lookup_type, parts, kwargs, query_mode) ||
          evaluate_lookup_cartesian(lookup_type, parts) ||
          evaluate_lookup_misc(lookup_type, parts, kwargs) ||
          evaluate_lookup_file_parsers(lookup_type, parts, kwargs) ||
          evaluate_custom_python_lookup(lookup_type, parts, kwargs, query_mode) ||
          hashi_vault_lookup_failure(original_lookup_type) ||
          unknown_fqcn_lookup_failure(original_lookup_type, lookup_type) ||
          "undefined"
      end

      private def hashi_vault_lookup_failure(original : String?) : Nil
        if message = PythonLookupRunner.hashi_vault_load_failure(original)
          raise PythonLookupRunner::LookupError.new(message)
        end
      end

      # ansible-core 2.19 hard-fails a lookup whose fully-qualified name
      # names a collection that is not installed ("The lookup plugin
      # 'nope.nope.php_version' was not found." - task-fatal at arg
      # finalization for geoffreyvanwyk.moodle's own
      # lookup('geoffreyvanwyk.moodle.php_version', ...)); falling through
      # the whole dispatch to the "undefined" sentinel instead let the
      # task silently succeed with the lookup's consumer holding the
      # literal text "undefined". Only a fully-qualified ns.coll.name
      # whose collection is DEFINITELY absent fails here: bare names keep
      # the fallback, ansible.builtin/ansible.legacy and community.general
      # are stripped above (and never fail), and a collection that IS
      # installed may still carry lookups this evaluator does not
      # implement - those keep the "undefined" degradation exactly as
      # before. ansible's own errors= option cannot rescue this either -
      # the plugin loader's not-found failure happens before any plugin
      # run could be wrapped.
      private def unknown_fqcn_lookup_failure(original : String?, stripped : String?) : Nil
        return unless name = stripped
        return unless name.matches?(/\A\w+\.\w+\.\w+\z/)
        namespace, collection, _leaf = name.split('.', 3)
        return if Krikri::CollectionIndex.installed?(namespace, collection)
        # Real prints the loader's ImportError as a [WARNING] the moment
        # it tries to load the plugin, ahead of the hard not-found failure.
        Krikri::CollectionIndex.warn_missing_lookup_plugin(name)
        raise PythonLookupRunner::LookupError.new("The lookup plugin '#{original}' was not found.")
      end

      # A lookup type with no handler above falls back to role-local
      # (and playbook-adjacent) custom `lookup_plugins/*.py` -
      # Ansible loads those on the controller (a lookup plugin's name
      # IS its file name) and runs `LookupModule.run(terms, variables,
      # **kwargs)` there. Delegated to the controller's own python3
      # (see PythonLookupRunner); nil keeps the previous "undefined"
      # fallback exactly as before whenever the mechanism cannot help
      # (no source file, no python3, no LookupModule class), so roles
      # without custom lookup plugins behave bit-for-bit identically.
      private def evaluate_custom_python_lookup(lookup_type : String?, parts : Array(String), kwargs : Array(String), query_mode : Bool = false) : String?
        return nil unless lookup_type

        role_path = @vars["role_path"]?.try(&.as_s?)
        playbook_dir = @vars["playbook_dir"]?.try(&.as_s?)
        return nil unless source = PythonLookupRunner.find_source(lookup_type, role_path, playbook_dir)

        # wantlist/errors are Templar's own generic options -
        # Ansible pops them before the plugin ever sees the kwargs.
        wantlist = kwargs.any? { |part| part.strip.downcase.starts_with?("wantlist=true") }
        options = Hash(String, JSON::Any).new
        kwargs.each do |kwarg|
          key, _, raw_value = kwarg.strip.partition('=')
          next if key.empty? || key.downcase.in?("wantlist", "errors")
          options[key] = evaluate_lookup_term(raw_value)
        end

        # Ansible's lookup variables dict always carries the omit
        # sentinel - a real-world plugin (manala.accounts's own
        # manala_accounts_users_authorized_keys.py) does
        # `variables['omit']` equality checks against it.
        variables = @vars.dup
        variables["omit"] = JSON::Any.new(OMIT_SENTINEL)

        terms = parts[1..].map { |part| evaluate_lookup_term(part) }
        begin
          result = PythonLookupRunner.call_lookup(lookup_type, source, terms, variables, options)
        rescue ex : PythonLookupRunner::LookupUnavailableError
          return nil if ex.unavailable?
          # A dispatched plugin failure is a real task failure in
          # Ansible (the plugin's own error) - same hard-failure
          # convention as lookup_pipe's PipeLookupError; the generic
          # lookup errors='ignore' option keeps the empty-result
          # behavior instead (verified live against 2.19.4 there).
          return "" if first_found_errors_ignore?(kwargs)
          raise ex
        end

        # Same list-form convention as lookup_inventory_hostnames: a
        # list-shaped result is comma-joined into a scalar only when
        # the caller asked for a scalar lookup() AND got something -
        # query()/wantlist=True/an empty result stay a real list.
        items = result.as_a?
        return result.to_json unless items
        list_form = wantlist || query_mode || items.empty?
        list_form ? items.to_json : items.map { |item| item.raw.is_a?(String) ? item.as_s : item.to_json }.join(",")
      end

      # `query(lookup_type, args)` - Ansible's list-forcing sibling
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
          # kwargs split AFTER the type is read - `errors='ignore'`
          # (nephelaiio.devtools's own loop source) is a generic lookup
          # OPTION, not a term; the params argument must also resolve
          # through first_found_params (not resolve_plus_operand) so a
          # raw list value keeps its nested {{ }} candidates intact for
          # evaluate_first_found's strict per-entry rendering.
          terms, kwargs = split_lookup_keyword_args(parts)
          params = terms[1]?.try { |part| first_found_params(part) }
          return "[]" unless params
          begin
            result = evaluate_first_found(params)
          rescue ex : FirstFoundLookupError | UndefinedVariableError
            # Ansible's generic lookup `errors='ignore'` option
            # swallows lookup errors and returns an empty result - with
            # the LIST term form there is no `skip:` sub-key, so this is
            # the only way the calling role can tolerate a no-match host.
            return "[]" if first_found_errors_ignore?(kwargs)
            raise ex
          end
          return "[]" if result == "undefined" || result == "[]"
          return [result].to_json
        end

        raw = evaluate_lookup(args, query_mode: true)
        # The same "undefined" sentinel #evaluate_lookup falls back to
        # for any lookup type it doesn't implement and that has no
        # role-local custom `lookup_plugins/<name>.py` behind it (those
        # dispatch through #evaluate_custom_python_lookup inside
        # #evaluate_lookup now) - wrapping it as a single-element
        # ["undefined"] array below would make a `loop: "{{ query(...)
        # }}"` run ONCE with a bogus string item instead of the empty
        # list Ansible's own query() falls back to when nothing
        # resolves. Same special case the first_found branch above
        # already has; this is its generic-fallback equivalent.
        return "[]" if raw == "undefined"

        parsed = (JSON.parse(raw) rescue nil)
        parsed.try(&.as_a?) ? raw : [raw].to_json
      end

      private def first_found_errors_ignore?(kwargs : Array(String)) : Bool
        kwargs.any? do |kwarg|
          key, _, value = kwarg.strip.partition('=')
          key.strip.downcase == "errors" && value.strip.delete("'\"").downcase == "ignore"
        end
      end

      # Renders a single `lookup('list'/'items'/'together'/'nested', ...)`
      # TERM (one comma-separated argument, not the whole call) to its
      # real JSON::Any value - a term is usually a variable reference to
      # a list, but may itself be a literal.
      private def evaluate_lookup_term(part : String) : JSON::Any
        stripped = part.strip
        if literal = sole_quoted_literal?(stripped)
          if literal.includes?("{{") || literal.includes?("{%")
            # The double-templated quoted term (`query('flattened',
            # '{{ snmpd_debian_packages }}')`, rhaamo.snmpd round 5460199)
            # that #rerender_double_templated_literal deliberately left
            # alone because its render came back CONTAINER-shaped: render
            # the literal's inner template here and recover the rendered
            # value's NATIVE type - a list variable must reach the lookup
            # as a real list to flatten (ansible-core's
            # listify_lookup_plugin_terms templates each string term), not
            # as one re-quoted repr string.
            return Krikri.parse_json_or_python_literal(jinja_renderer.render!(literal))
          end
          # A quoted literal WITHOUT template markers is a string term by
          # construction - its evaluated text must not be re-typed by its
          # own shape (`query('flattened', '["a","b"]')` is ONE string item
          # in ansible-core 2.19.11, not the parsed list; the shape-based
          # parse below would have flipped it).
          return JSON::Any.new(evaluate(part))
        end
        rendered = evaluate(part)
        Krikri.parse_json_or_python_literal(rendered)
      end
    end
  end
end
