require "json"
require "krikri-jinja/krikri_jinja"
require "./lookup_plugins"
require "./python_lookup_runner"
require "./jinja_host_context"
require "./vault"
require "./variable_substitutor/filter_engine"

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
          name = text(args[0]).sub(/^ansible\.(builtin|legacy)\./, "")
          result = lookup(name, args[1..], kwargs, ctx)
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
      when String then raw
      when Nil, KrikriJinja::Undefined then ""
      else KrikriJinja.to_json_any(value).to_s
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

    private def self.lookup(name : String, terms : Array(AnyValue), kwargs : Hash(String, AnyValue),
                            ctx : KrikriJinja::Context) : AnyValue
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
        truthy?(kwargs["wantlist"]?) ? AnyValue.new(items) : AnyValue.new(items.map { |item| text(item) }.join(","))
      when "together"
        arrays = terms.map { |term| list(term) }
        size = arrays.max_of?(&.size) || 0
        AnyValue.new((0...size).map { |i| AnyValue.new(arrays.map { |array| array[i]? || AnyValue.new(nil) }) })
      when "nested"
        rows = terms.map { |term| list(term) }.reduce([[] of AnyValue]) do |acc, array|
          acc.flat_map { |row| array.map { |item| row + [item] } }
        end
        AnyValue.new(rows.map { |row| AnyValue.new(row) })
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
        lookup_first_found(ctx, first, role_path)
      when "sequence"
        AnyValue.new(LookupPlugins.sequence_lookup(text(first)).map { |value| AnyValue.new(value) })
      when "csvfile"
        AnyValue.new(LookupPlugins.csvfile_lookup(text(first)))
      when "ini"
        AnyValue.new(LookupPlugins.ini_lookup(text(first)))
      else
        python_lookup(name, terms, kwargs, ctx)
      end
    end

    private def self.flatten(terms : Array(AnyValue)) : Array(AnyValue)
      terms.flat_map { |term| term.raw.is_a?(Array) ? flatten(list(term)) : [term] }
    end

    private def self.lookup_template(ctx : KrikriJinja::Context, path : String,
                                     kwargs : Hash(String, AnyValue), role_path : String?) : AnyValue
      resolved = LookupPlugins.resolve_lookup_path(path, role_path)
      return AnyValue.new(nil) unless File.exists?(resolved)
      content = File.read(resolved)
      first_line_end = content.index('\n')
      first_line = first_line_end ? content[0...first_line_end] : content
      if first_line.strip.starts_with?("#jinja2:")
        content = first_line_end ? content[(first_line_end + 1)..] : ""
      end
      extra = kwargs["template_vars"]?.try(&.raw.as?(Hash(String, AnyValue))) || {} of String => AnyValue
      AnyValue.new(render_nested(ctx, content, extra).chomp)
    rescue KrikriJinja::TemplateError
      AnyValue.new(nil)
    end

    # `first_found` with a `{files:, paths:, skip:}` term: the first
    # existing file under the (rendered) search paths; no match raises
    # unless skip is set.
    private def self.lookup_first_found(ctx : KrikriJinja::Context, term : AnyValue, role_path : String?) : AnyValue
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

    private def self.python_lookup(name : String, terms : Array(AnyValue), kwargs : Hash(String, AnyValue),
                                   ctx : KrikriJinja::Context) : AnyValue
      host = ctx.host_context.as?(JinjaHostContext)
      role_path = scope_string(ctx, "role_path")
      playbook_dir = scope_string(ctx, "playbook_dir")
      source = PythonLookupRunner.find_source(name, role_path, playbook_dir)
      raise KrikriJinja::TemplateError.new("lookup plugin (#{name}) not found", 0) unless source

      options = {} of String => JSON::Any
      kwargs.each do |key, value|
        next if key.downcase.in?("wantlist", "errors")
        options[key] = json(value)
      end
      variables = host ? host.lookup_variables : {"omit" => JSON::Any.new(Krikri::OMIT_SENTINEL)}
      begin
        KrikriJinja.from_json_any(PythonLookupRunner.call_lookup(name, source, terms.map { |term| json(term) }, variables, options))
      rescue ex : PythonLookupRunner::LookupUnavailableError
        return AnyValue.new(nil) if ex.unavailable?
        return AnyValue.new(nil) if kwargs["errors"]?.try { |value| text(value).downcase } == "ignore"
        raise ex
      end
    end
  end
end

Krikri::KrikriJinjaLookups.register
