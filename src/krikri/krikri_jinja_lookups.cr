require "json"
require "krikri-jinja/krikri_jinja"
require "./collection_index"
require "./lookup_plugins"
require "./aws_secret_lookup"
require "./python_lookup_runner"
require "./jinja_host_context"
require "./vault"
require "./unsafe_values"
require "./variable_substitutor/filter_engine"
require "./lookups/inventory_pattern"

module Krikri
  # Ansible's `lookup()` / `query()` / `q()` on the krikri-jinja engine.
  # The built-in lookup types run on the controller here; any other name
  # dispatches to a role-local (or playbook-adjacent) `lookup_plugins/*.py`
  # through the controller's python3. wantlist/errors are Templar's generic
  # options, never passed to a plugin.
  module KrikriJinjaLookups
    alias AnyValue = KrikriJinja::AnyValue

    def self.register : Nil
      {"lookup" => false, "query" => true, "q" => true}.each do |function_name, query_mode|
        KrikriJinja.register_default_function(function_name) do |args, kwargs, ctx|
          raise KrikriJinja::TemplateError.new("#{function_name}() requires a lookup name", 0) if args.empty?
          # ansible-core fails the lookup argument's undefined name before the
          # plugin runs; the lenient Undefined would otherwise stringify to ""
          # and the plugin would run on an empty (then literal "undefined") term.
          args.each do |arg|
            next unless (undefined = arg.raw.as?(KrikriJinja::Undefined))
            raise KrikriJinja::TemplateError.new(KrikriJinja.undefined_message(undefined), 0, kind: KrikriJinja::ErrorKind::Undefined)
          end
          name = text(args[0]).sub(/^ansible\.(builtin|legacy)\./, "")
          result = lookup(name, prepare_lookup_terms(args[1..], ctx), kwargs, ctx, query_mode)
          if query_mode && !result.raw.is_a?(KrikriJinja::Undefined) && !result.raw.nil? && !result.raw.is_a?(Array)
            AnyValue.new([result])
          else
            result
          end
        end
      end
    end

    private def self.text(value : AnyValue) : String
      case raw = value.raw
      when String                      then raw
      when Nil, KrikriJinja::Undefined then ""
      else                                  KrikriJinja.to_json_any(value).to_s
      end
    end

    private def self.json(value : AnyValue) : JSON::Any
      KrikriJinja.to_json_any(value)
    end

    private def self.list(value : AnyValue) : Array(AnyValue)
      case raw = value.raw
      when Array then raw
      else            [] of AnyValue
      end
    end

    private def self.truthy?(value : AnyValue?) : Bool
      return false unless value
      case raw = value.raw
      when Nil, KrikriJinja::Undefined then false
      when Bool                        then raw
      when String                      then !raw.empty?
      when Int64                       then raw != 0
      when Float64                     then raw != 0.0
      when Array                       then !raw.empty?
      when Hash                        then !raw.empty?
      else                                  true
      end
    end

    private def self.scope_string(ctx : KrikriJinja::Context, name : String) : String?
      value = ctx[name]
      value.raw.as?(String)
    end

    # Every name visible to the rendering template: its local scopes plus
    # the host's whole variable scope.
    private def self.visible_names(ctx : KrikriJinja::Context) : Array(String)
      names = [] of String
      if host = ctx.host_context.as?(JinjaHostContext)
        names.concat(host.vars.keys)
      end
      ctx.scopes.each { |scope| names.concat(scope.keys) }
      names.uniq
    end

    # Renders a nested template string against the calling template's own
    # variables (its local scopes, then the lazy scope), plus *extra*.
    private def self.render_nested(ctx : KrikriJinja::Context, source : String,
                                   extra : Hash(String, AnyValue) = {} of String => AnyValue) : String
      variables = {} of String => AnyValue
      ctx.scopes.each { |scope| scope.each { |key, value| variables[key] = value } }
      extra.each { |key, value| variables[key] = value }
      KrikriJinja.default_engine.render_parsed(
        KrikriJinja::Parser.parse(source, KrikriJinja::LexerOptions.new(trim_blocks: true)),
        variables, resolver: ctx.resolver, undefined: ctx.undefined, host_context: ctx.host_context
      )
    end

    # Ansible's listify_lookup_plugin_terms: every lookup TERM that is a
    # string carrying Jinja markers (`'{{ var }}'` - the "double-templated"
    # idiom rhaamo.snmpd's own `query('flattened',
    # '{{ snmpd_debian_packages }}')` uses, round 5460199) is itself
    # templated before the plugin ever sees it (ansible-core emits a
    # deprecation warning steering authors to inline expressions, but
    # still resolves it). The engine previously handed the plugin the
    # LITERAL unrendered text, so flattened saw one string item
    # `{{ snmpd_debian_packages }}` instead of the three packages. The
    # rendered value recovers its native type (a list variable flattens
    # as a real list, not one repr string).
    private def self.prepare_lookup_terms(terms : Array(AnyValue), ctx : KrikriJinja::Context) : Array(AnyValue)
      terms.map do |term|
        next term unless (raw = term.raw).is_a?(String)
        next term unless raw.includes?("{{") || raw.includes?("{%")
        # Host-derived text (register results, !unsafe scalars, anything
        # the taint registry tracks) is verbatim DATA, never template
        # source - the same gate every other re-render path consults. A
        # hostile target's `{{ lookup('pipe', ...) }}`-shaped stdout
        # flowing into a lookup term must print verbatim, not execute.
        next term if UnsafeValues.unsafe_text?(raw)
        # Same ansible-core 2.19 "Jinja constant strings should not contain
        # embedded templates" warning the hand-rolled lookup dispatch emits
        # for its own re-render of such a term: this is the native-typed
        # whole-span route (set_fact values, debug msg containers), where
        # the same double-templated lookup constant renders HERE instead -
        # leaving that route silent would warn for one idiom shape and not
        # another. Only with a task param registered on the current fiber
        # (no task context, no warning), and before the render, matching
        # where _trust_jinja_constants warns.
        VariableSubstitutor::ExpressionEvaluator.emit_jinja_const_template_warning if raw.includes?("{{")
        rendered = begin
          render_nested(ctx, raw)
        rescue
          raw
        end
        KrikriJinja.from_json_any(Krikri.parse_json_or_python_literal(rendered))
      end
    end

    private def self.lookup(name : String, terms : Array(AnyValue), kwargs : Hash(String, AnyValue),
                            ctx : KrikriJinja::Context, query_mode : Bool = false) : AnyValue
      first = terms[0]? || AnyValue.new(nil)
      role_path = scope_string(ctx, "role_path")
      case name
      when "env"
        var_name = text(first)
        AnyValue.new(var_name.empty? ? "" : (ENV[var_name]? || ""))
      when "config"
        names = terms.map { |term| text(term) }.reject { |term| term.empty? || term.downcase.starts_with?("wantlist=") }
        values = names.map { |config_name| LookupPlugins.ansible_config_value(config_name) }
        if names.size > 1 || truthy?(kwargs["wantlist"]?) || terms.any? { |term| text(term).downcase.starts_with?("wantlist=true") }
          AnyValue.new(values.map { |value| AnyValue.new(value) })
        else
          AnyValue.new(values[0]? || "")
        end
      when "vars"
        var_name = text(first)
        var_name.empty? ? AnyValue.new(nil) : ctx[var_name]
      when "file"
        path = LookupPlugins.resolve_lookup_path(text(first), role_path)
        File.exists?(path) ? AnyValue.new(File.read(path).chomp) : AnyValue.new(nil)
      when "pipe", "lines"
        output = IO::Memory.new
        status = Process.run("/bin/sh", ["-c", text(first)], output: output, error: Process::Redirect::Close) rescue nil
        if status.nil? || !status.success?
          AnyValue.new(nil)
        elsif name == "pipe"
          AnyValue.new(output.to_s.chomp)
        else
          AnyValue.new(output.to_s.split('\n').reject(&.empty?).map { |line| AnyValue.new(line) })
        end
      when "template"
        lookup_template(ctx, text(first), kwargs, role_path)
      when "password"
        AnyValue.new(LookupPlugins.password_lookup(text(first), role_path))
      when "unvault"
        path = text(first)
        password = Krikri::Vault.password
        begin
          (password && File.exists?(path)) ? AnyValue.new(Krikri::Vault.decrypt(File.read(path), password).chomp) : AnyValue.new(nil)
        rescue
          AnyValue.new(nil)
        end
      when "dict"
        hash = first.raw.as?(Hash(String, AnyValue)) || {} of String => AnyValue
        AnyValue.new(hash.map { |key, value| AnyValue.new({"key" => AnyValue.new(key), "value" => value}) })
      when "list"
        AnyValue.new(terms)
      when "items"
        AnyValue.new(terms.flat_map { |term| term.raw.is_a?(Array) ? list(term) : [term] })
      when "flattened"
        items = flatten(terms)
        # query() is Ansible's list-forcing sibling: the plugin's own
        # scalar comma-join is lookup()-only, so a `query('flattened', ...)`
        # result must stay the real flattened list (previously the
        # comma-joined STRING came back and the register wrapper wrapped
        # it into a one-element list - `query('flattened', pkg_list)`
        # yielded `["a,b"]`).
        (query_mode || truthy?(kwargs["wantlist"]?)) ? AnyValue.new(items) : AnyValue.new(items.map { |item| text(item) }.join(","))
      when "together"
        arrays = terms.map { |term| list(term) }
        size = arrays.max_of?(&.size) || 0
        AnyValue.new((0...size).map { |i| AnyValue.new(arrays.map { |array| array[i]? || AnyValue.new(nil) }) })
      when "nested"
        rows = terms.map { |term| list(term) }.reduce([[] of AnyValue]) do |acc, array|
          acc.flat_map { |row| array.map { |item| row + [item] } }
        end
        AnyValue.new(rows.map { |row| AnyValue.new(row) })
      when "cartesian"
        lookup_cartesian(terms)
      when "varnames"
        patterns = terms.compact_map { |term| VariableSubstitutor::FilterEngine.cached_regex(text(term)) rescue nil }
        AnyValue.new(visible_names(ctx).select { |var_name| patterns.any?(&.matches?(var_name)) }.map { |var_name| AnyValue.new(var_name) })
      when "indexed_items"
        AnyValue.new(list(first).map_with_index { |item, i| AnyValue.new([AnyValue.new(i.to_i64), item]) })
      when "random_choice"
        items = terms.flat_map { |term| term.raw.is_a?(Array) ? list(term) : [term] }
        items.empty? ? AnyValue.new(nil) : items.sample
      when "subelements"
        subkey = text(terms[1]? || AnyValue.new(""))
        options = terms[2]?.try(&.raw.as?(Hash(String, AnyValue)))
        skip_missing = truthy?(options.try(&.["skip_missing"]?))
        pairs = [] of AnyValue
        list(first).each do |parent|
          children = parent.raw.as?(Hash(String, AnyValue)).try(&.[subkey]?)
          next if children.nil? && skip_missing
          (children ? list(children) : [] of AnyValue).each { |child| pairs << AnyValue.new([parent, child]) }
        end
        AnyValue.new(pairs)
      when "url"
        lines = LookupPlugins.fetch_url_lines(text(first))
        if lines.nil?
          AnyValue.new(nil)
        elsif truthy?(kwargs["wantlist"]?)
          AnyValue.new(lines.map { |line| AnyValue.new(line) })
        else
          AnyValue.new(lines.join(","))
        end
      when "first_found"
        lookup_first_found(ctx, first, kwargs, role_path)
      when "sequence"
        AnyValue.new(LookupPlugins.sequence_lookup(text(first)).map { |value| AnyValue.new(value) })
      when "csvfile"
        AnyValue.new(LookupPlugins.csvfile_lookup(text(first)))
      when "ini"
        AnyValue.new(LookupPlugins.ini_lookup(text(first)))
      when "inventory_hostnames"
        # inventory_hostnames over the `groups` magic var - the same
        # throwaway-InventoryManager plugin the hand-rolled evaluator
        # implements for direct `{{ lookup('inventory_hostnames', ...) }}`
        # text, on shared InventoryPatterns machinery. This arm is what
        # every legacy `with_inventory_hostnames:` loop source actually
        # rides: TaskExecutor#resolve_loop_lookup evaluates the source as
        # `query('inventory_hostnames', term, wantlist=True)` HERE, so
        # without the arm such loops fell through to python_lookup and
        # failed with "lookup plugin (inventory_hostnames) not found"
        # (and the false-block skip path degraded them to one bare
        # skipping line instead of per-item lines).
        # variables['groups'] is in every real task's context; absent
        # here, the real plugin's throwaway manager is empty, so matching
        # means an empty result (+ its own unmatched-pattern warning),
        # never a failure.
        groups = ctx.host_context.as?(JinjaHostContext)
          .try(&.vars["groups"]?.try(&.as_h?)) || {} of String => JSON::Any
        hosts = InventoryPatterns.pattern_hosts(
          flatten(terms).map { |term| text(term) },
          InventoryPatterns.groups_from_vars(groups)
        )
        # query() is Ansible's list-forcing sibling, and a SCALAR lookup()
        # of an EMPTY match renders [] (a real empty list), not "" - the
        # exact convention the hand-rolled lookup_inventory_hostnames
        # already pins (verified vs ansible-core 2.19.4).
        list_form = query_mode || truthy?(kwargs["wantlist"]?) || hosts.empty?
        list_form ? AnyValue.new(hosts.map { |host| AnyValue.new(host) }) : AnyValue.new(hosts.join(","))
      when "aws_secret", "amazon.aws.aws_secret"
        lookup_aws_secret(name, terms, kwargs, query_mode)
      else
        python_lookup(name, terms, kwargs, ctx, query_mode)
      end
    end

    # amazon.aws.aws_secret - natively implemented (see AwsSecretLookup for
    # why: the collection is deliberately supported and the lookup runs on
    # the controller, where the PythonLookupRunner cannot reach installed
    # collections' plugins). The helper raises the plugin's own message;
    # the generic wrapper prefix and hard-failure here match real
    # ("The lookup plugin '<name as spelled>' failed: Failed to find secret
    # x (ResourceNotFound)", live-verified vs amazon.aws 10.1.1) - the same
    # convention lookup_template's not-found raise rides.
    private def self.lookup_aws_secret(name : String, terms : Array(AnyValue),
                                       kwargs : Hash(String, AnyValue), query_mode : Bool) : AnyValue
      options = {} of String => String
      kwargs.each do |key, value|
        next if key.downcase.in?("wantlist", "errors")
        options[key] = aws_secret_text(value)
      end
      term_values = flatten(terms).map { |term| aws_secret_text(term) }
      begin
        result = Krikri::AwsSecretLookup.run(term_values, options,
          warning_sink: ->(warning : String) { ResultDisplay.emit_display_warning(warning) })
      rescue ex : Krikri::AwsSecretLookup::Error
        raise PythonLookupRunner::LookupError.new("The lookup plugin '#{name}' failed: #{ex.message}")
      end
      converted = KrikriJinja.from_json_any(JSON::Any.new(result))
      # Same list-form convention as python_lookup's own dispatch: a
      # list-shaped result is comma-joined into a scalar only for a plain
      # lookup() that got something - query()/wantlist=True/an empty result
      # stay a real list.
      items = converted.raw.as?(Array)
      if items.nil? || items.empty? || query_mode || truthy?(kwargs["wantlist"]?)
        return converted
      end
      AnyValue.new(items.map { |item| text(item) }.join(","))
    end

    private def self.aws_secret_text(value : AnyValue) : String
      case raw = value.raw
      when Nil       then ""
      when String    then raw
      when Bool      then raw ? "true" : "false"
      when Int64     then raw.to_s
      when Float64   then raw.to_s
      when JSON::Any then aws_secret_json_text(raw)
      else                KrikriJinja.to_json_any(value).to_s
      end
    end

    private def self.aws_secret_json_text(raw : JSON::Any) : String
      case raw.raw
      when Nil     then ""
      when String  then raw.as_s
      when Bool    then raw.as_bool ? "true" : "false"
      when Int64   then raw.to_s
      when Float64 then raw.to_s
      else              raw.to_json
      end
    end

    private def self.flatten(terms : Array(AnyValue)) : Array(AnyValue)
      terms.flat_map { |term| term.raw.is_a?(Array) ? flatten(list(term)) : [term] }
    end

    private def self.lookup_template(ctx : KrikriJinja::Context, path : String,
                                     kwargs : Hash(String, AnyValue), role_path : String?) : AnyValue
      resolved = LookupPlugins.resolve_template_lookup_path(path, role_path)
      unless File.exists?(resolved)
        # find_file_in_search_path prints this warning for a lookup file
        # the search paths cannot find, for every errors mode
        # (live-verified vs 2.19.11: warn and ignore carry the task
        # past the missing file, strict still fails after the warning).
        ResultDisplay.emit_display_warning(
          "Unable to find '#{path}' in expected paths (use -vvvvv to see paths)"
        )
        # The generic lookup errors= option decides what the missing
        # file does (live-verified 2.19.11 against every mode): only
        # strict, the default, fails the task; warn warns and carries
        # on, ignore just carries on, and both
        # return None ([ ] under wantlist=True), never the raise. The
        # old silent nil matched the lenient modes but masked strict's
        # failure, which is what issue #248's role rode through.
        errors_option = kwargs["errors"]?.try { |value| text(value).strip.downcase }
        if errors_option == "warn"
          ResultDisplay.emit_display_warning(
            "An error occurred while running the lookup plugin 'template': the template file #{path} could not be found for the lookup"
          )
          return truthy?(kwargs["wantlist"]?) ? AnyValue.new([] of AnyValue) : AnyValue.new(nil)
        end
        return truthy?(kwargs["wantlist"]?) ? AnyValue.new([] of AnyValue) : AnyValue.new(nil) if errors_option == "ignore"
        # template.py raises with the term AS GIVEN ("the template file
        # %s could not be found for the lookup" % term, never the
        # search-path-joined candidate: live-verified 2.19.11 for an
        # absolute term outside any role AND a relative one inside one)
        # and the generic wrapper prefixes the message as "The lookup
        # plugin 'template' failed: ..." - the same typed LookupError
        # routing the 'cartesian' raise travels.
        raise Krikri::PythonLookupRunner::LookupError.new(
          "The lookup plugin 'template' failed: the template file #{path} could not be found for the lookup"
        )
      end
      content = File.read(resolved)
      first_line_end = content.index('\n')
      first_line = first_line_end ? content[0...first_line_end] : content
      if first_line.strip.starts_with?("#jinja2:")
        content = first_line_end ? content[(first_line_end + 1)..] : ""
      end
      extra = kwargs["template_vars"]?.try(&.raw.as?(Hash(String, AnyValue))) || {} of String => AnyValue
      # Ansible's template lookup keeps the template's trailing newlines
      # (live-verified vs ansible-core 2.19.11), so restore whatever the
      # source had beyond the rendered result's own, as lookup_file.cr does.
      # ansible-core 2.19.11 attributes a play_hosts read deprecation
      # raised inside a lookup('template') render to the LOOKUP's template
      # file as Origin (path alone, no line/column), not to the calling
      # task param - registered on the fiber for the render's variable
      # reads to pick up (play_hosts_read_origin).
      VarSubstitutor.push_current_template_file(resolved)
      begin
        rendered = render_nested(ctx, content, extra)
      ensure
        VarSubstitutor.pop_current_template_file
      end
      missing = (content.size - content.rstrip('\n').size) - (rendered.size - rendered.rstrip('\n').size)
      rendered += "\n" * missing if !rendered.empty? && missing > 0
      # Ansible's template lookup yields None, not "", when the render
      # produces no output at all (only block tags / comments, or a loop
      # body that never runs - live-verified vs 2.19.x), so a var holding
      # the lookup becomes None where we used to give "" (2 bytes apart in
      # the rendered config: linux-system-roles.logging's rsyslog subrole
      # renders its empty custom_templates list as "None" vs our ""). A
      # source with no block/comment markup, an empty file, or an
      # expression yielding "" still renders "" exactly as Ansible does.
      return AnyValue.new(nil) if rendered.empty? && (content.includes?("{%") || content.includes?("{#"))
      AnyValue.new(rendered)
    rescue KrikriJinja::TemplateError
      AnyValue.new(nil)
    end

    # `first_found` with a `{files:, paths:, skip:}` term: the first
    # existing file under the (rendered) search paths; no match raises
    # unless skip is set OR the caller passed `errors='ignore'` - the
    # generic lookup errors option (first_found's own `errors:` sub-key
    # aside), which makes Ansible's plugin return None instead of
    # raising. That None matters: `params: "{{ lookup('first_found',
    # params_, errors='ignore') }}"` + `when: params | length > 0`
    # (lotusnoir.apps_consul_exporter, round 5210000) fails on real
    # ansible with "object of type 'NoneType' has no len()", while the
    # old raise here degraded downstream to an empty STRING whose
    # length is 0 - the task silently skipped. An errors= kwarg value
    # other than 'ignore' keeps the raise (Ansible re-raises there).
    private def self.lookup_first_found(ctx : KrikriJinja::Context, term : AnyValue, kwargs : Hash(String, AnyValue), role_path : String?) : AnyValue
      hash = term.raw.as?(Hash(String, AnyValue))
      files = first_found_param(ctx, hash.try(&.["files"]?)) || [] of String
      paths = first_found_param(ctx, hash.try(&.["paths"]?)) || ["files", "templates", "vars", "."]
      roots = paths.flat_map { |path| LookupPlugins.resolve_first_found_roots(render_nested(ctx, path), role_path) }
      files.each do |file|
        rendered = render_nested(ctx, file)
        roots.each do |root|
          candidate = File.join(root, rendered)
          return AnyValue.new(candidate) if File.exists?(candidate)
        end
      end
      return AnyValue.new([] of AnyValue) if truthy?(hash.try(&.["skip"]?))
      if (errors_val = kwargs["errors"]?) && text(errors_val).strip.downcase == "ignore"
        return AnyValue.new(nil)
      end
      raise Krikri::FirstFoundLookupError.new(
        "The lookup plugin 'first_found' failed: No file was found when using first_found."
      )
    end

    private def self.first_found_param(ctx : KrikriJinja::Context, value : AnyValue?) : Array(String)?
      return nil unless value
      case raw = value.raw
      when Array
        raw.map { |item| text(item) }
      when String
        rendered = Krikri.parse_json_or_python_literal(render_nested(ctx, raw))
        (rendered.as_a? || [rendered]).map { |item| item.as_s? || item.to_s }
      end
    end

    # The community.general cartesian lookup (see the hand-rolled
    # evaluator's evaluate_lookup_list "cartesian" case for the full
    # semantics): an itertools.product over every argument, a string or
    # other non-iterable argument wrapping as a single-element list, a
    # dict iterating its keys, an empty argument making the whole
    # product empty and zero arguments the plugin's own hard error -
    # live-verified against ansible-core 2.19.11 + community.general
    # 12.5.0 (znerol.ssh_kba, round 5410000).
    private def self.lookup_cartesian(terms : Array(AnyValue)) : AnyValue
      if terms.empty?
        raise Krikri::PythonLookupRunner::LookupError.new(
          "The lookup plugin 'cartesian' failed: with_cartesian requires at least one element in each list"
        )
      end
      cartesian_lists = terms.map { |term| lookup_cartesian_term(term) }
      cartesian_rows = cartesian_lists.reduce([[] of AnyValue]) do |acc, cartesian_list|
        acc.flat_map do |cartesian_row|
          cartesian_list.flat_map do |item|
            spread = item.raw.as?(Array) || [item]
            [cartesian_row + spread]
          end
        end
      end
      AnyValue.new(cartesian_rows.map { |row| AnyValue.new(row) })
    end

    # One cartesian lookup argument through
    # listify_lookup_plugin_terms: a list iterates as-is, a dict
    # iterates its keys, a string is ITS OWN element (stripped) rather
    # than iterating its characters, and every other scalar wraps as a
    # single-element list.
    private def self.lookup_cartesian_term(term : AnyValue) : Array(AnyValue)
      case raw = term.raw
      when Array
        raw
      when Hash
        raw.keys.map { |key| AnyValue.new(key) }
      when String
        [AnyValue.new(raw.strip)]
      else
        [term]
      end
    end

    private def self.python_lookup(name : String, terms : Array(AnyValue), kwargs : Hash(String, AnyValue),
                                   ctx : KrikriJinja::Context, query_mode : Bool = false) : AnyValue
      host = ctx.host_context.as?(JinjaHostContext)
      role_path = scope_string(ctx, "role_path")
      playbook_dir = scope_string(ctx, "playbook_dir")
      source = PythonLookupRunner.find_source(name, role_path, playbook_dir)
      # Ansible fails the task the moment a lookup plugin cannot be found
      # ("The lookup plugin 'nope.nope.php_version' was not found." -
      # the plugin loader's own error, before any plugin run or
      # errors= option handling); the old "lookup plugin (name) not
      # found" TemplateError got swallowed by the renderer's
      # give-back-the-text fallback instead of failing. The typed
      # LookupError is what JinjaRenderer#render! re-raises as a hard
      # task failure - same message shape the hand-rolled dispatch
      # raises for the same condition.
      # Same loader-ImportError [WARNING] real prints before this failure
      # when the name names a collection that cannot be imported; bare
      # names and installed collections stay silent (the helper filters).
      unless source
        if message = PythonLookupRunner.hashi_vault_load_failure(name)
          raise PythonLookupRunner::LookupError.new(message)
        end
      end
      Krikri::CollectionIndex.warn_missing_lookup_plugin(name) unless source
      raise PythonLookupRunner::LookupError.new("The lookup plugin '#{name}' was not found.") unless source

      options = {} of String => JSON::Any
      kwargs.each do |key, value|
        next if key.downcase.in?("wantlist", "errors")
        options[key] = json(value)
      end
      variables = host ? host.lookup_variables : {"omit" => JSON::Any.new(Krikri::OMIT_SENTINEL)}
      result = begin
        KrikriJinja.from_json_any(PythonLookupRunner.call_lookup(name, source, terms.map { |term| json(term) }, variables, options))
      rescue ex : PythonLookupRunner::LookupUnavailableError
        return AnyValue.new(nil) if ex.unavailable?
        return AnyValue.new(nil) if kwargs["errors"]?.try { |value| text(value).downcase } == "ignore"
        raise ex
      end
      # Same list-form convention as the hand-rolled evaluator's
      # evaluate_custom_python_lookup: a list-shaped result is
      # comma-joined into a scalar for a plain lookup() - ansible's
      # lookup()/query() distinction (live-verified vs ansible-playbook:
      # lookup() of a plugin returning ['bob','alice'] renders
      # "bob,alice"), while query()/wantlist=True/an empty result stay a
      # real list. Without this a resolved lookup fed the WHOLE list to
      # its consumer (issue #519: ansible_become_user became
      # "['bob']" instead of "bob" and the owning task still failed).
      items = result.raw.as?(Array(AnyValue))
      return result unless items && !items.empty? &&
                           !(query_mode || truthy?(kwargs["wantlist"]?))
      AnyValue.new(items.map { |item| (str = item.raw.as?(String)) ? str : text(item) }.join(","))
    end
  end
end

Krikri::KrikriJinjaLookups.register
