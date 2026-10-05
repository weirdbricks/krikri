require "json"

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
        rendered = jinja_renderer.render!(literal)
        "#{quote}#{rendered}#{quote}"
      rescue
        part
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
        parts, kwargs = split_lookup_keyword_args(
          split_top_level_commas(args).map { |part| rerender_double_templated_literal(part) },
        )
        lookup_type = parts[0]?.try { |part| quoted_string_literal(part.strip) }.try(&.as_s?)

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

        evaluate_lookup_scalar(lookup_type, parts, kwargs, query_mode) ||
          evaluate_lookup_file(lookup_type, parts, kwargs) ||
          evaluate_lookup_list(lookup_type, parts, kwargs, query_mode) ||
          evaluate_lookup_misc(lookup_type, parts, kwargs) ||
          evaluate_lookup_file_parsers(lookup_type, parts, kwargs) ||
          evaluate_custom_python_lookup(lookup_type, parts, kwargs, query_mode) ||
          "undefined"
      end

      # A lookup type with no handler above falls back to role-local
      # (and playbook-adjacent) custom `lookup_plugins/*.py` - real
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

        # wantlist/errors are Templar's own generic options - real
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
          # A dispatched plugin failure is a real task failure in real
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
        rendered = evaluate(part)
        Krikri.parse_json_or_python_literal(rendered)
      end
    end
  end
end
