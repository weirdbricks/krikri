#!/usr/bin/env crystal

require "json"
require "file_utils"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/file_attrs"
require "../src/krikri/python_literal"

module Krikri
  # json_file plugin - sets or removes one key in a JSON document on the
  # target host and leaves the rest of it (key order included) alone. The
  # JSON counterpart to ini_file, and modeled on it: same path/key/value/
  # state/create/backup shape, same file-attribute handling, same diff and
  # check-mode behavior.
  #
  # This is a krikri EXTENSION, not an Ansible module (issue #1835):
  # ansible-core and community.general have no file-editing JSON module -
  # only the in-memory json_query/json_patch filters - so `json_file:` on
  # ansible-playbook fails with "couldn't resolve module/action". It is
  # registered under a name no Ansible module uses, so it can never shadow
  # a real module this engine should implement instead, and
  # `krikri.json_file` is accepted as its fully-qualified spelling
  # (MODULE_ALIASES) - ansible.builtin.json_file is deliberately not.
  #
  # `key` is a dotted path ("logging.level", "servers.0.host"); a segment
  # indexes an array only when the value it addresses IS an array, and is
  # a plain object key everywhere else, so no array is ever conjured out
  # of an index. state=absent on an array index removes that element (the
  # following ones shift down). A key that itself contains a dot is
  # addressed by writing the whole key as a JSON list of one segment
  # (`key: '["a.b"]'`): a YAML list param reaches a plugin comma-joined by
  # the engine's strings-only wire, so the string form is the one that
  # survives. `changes` takes a list of {key, value} mappings (each entry
  # may carry its own state) for multi-key edits in one task.
  #
  # Output formatting: the document is re-serialized only when an edit
  # actually changed the tree, preserving key order, the trailing-newline
  # shape and the file's own indentation (detected from its smallest
  # leading space run; a compact single-line file stays compact, and
  # `indent:` overrides either). A tab-indented file is the one shape that
  # detection cannot express, so it is rewritten with DEFAULT_INDENT
  # spaces unless `indent:` says otherwise. Missing parent directories of
  # `path` are created, like ini_file does.
  class JsonFilePlugin < BasePlugin
    include PluginHelpers::FileAttrs

    # Every option the module accepts; anything else is rejected the way
    # an Ansible module rejects an unknown argument, rather than silently
    # ignored (there is no generated argument spec covering an extension
    # module, so the check lives here).
    SUPPORTED_PARAMS = %w[
      path dest key value value_type changes state create backup indent
      owner group mode seuser serole setype selevel
    ]

    # Python's json.dump default is no indentation at all; 2 spaces is what
    # a JSON config file conventionally uses, and what a brand-new file this
    # module creates gets unless `indent:` says otherwise.
    DEFAULT_INDENT = 2

    # Ansible's registered-result key order for the modules this one is
    # modeled on (see ini_file.cr's own copy): changed, diff, msg, path,
    # backup_file only when a backup was taken, then add_path_info's stat
    # block and failed.
    SUCCESS_KEY_ORDER = %w[changed diff msg path backup_file uid gid owner group mode state size failed]

    # One requested edit, already resolved into its path segments and
    # whether it sets or removes the addressed leaf.
    private struct Edit
      getter segments : Array(String)
      getter? absent : Bool
      getter value : JSON::Any

      def initialize(@segments : Array(String), @absent : Bool, @value : JSON::Any)
      end
    end

    # A validated task: everything execute() needs, resolved from the
    # command-line-ish param hash before any file is touched.
    private record Request,
      path : String,
      backup : Bool,
      check_mode : Bool,
      indent : String?,
      edits : Array(Edit)

    def execute : PluginResult
      request = build_request
      return request if request.is_a?(PluginResult)
      apply_request(request)
    end

    private def build_request : Request | PluginResult
      unsupported = unsupported_params
      unless unsupported.empty?
        return failure("Unsupported parameters for (json_file) module: #{unsupported.join(", ")}. " \
                       "Supported parameters include: #{SUPPORTED_PARAMS.join(", ")}.")
      end

      path_param = @params["path"]? || @params["dest"]?
      return failure("missing required parameter: path") unless path_param
      path = expand_tilde(path_param)
      return failure("Destination #{path} does not exist!") if File.directory?(path)

      indent_override, indent_failure = indent_setting
      return indent_failure if indent_failure

      edits = requested_edits
      return edits if edits.is_a?(PluginResult)

      create = @params["create"]? ? true?(@params["create"]?) : true
      if !File.exists?(path) && !create && edits.any? { |edit| !edit.absent? }
        return failure("Destination #{path} does not exist!")
      end

      Request.new(
        path: path,
        backup: true?(@params["backup"]?),
        check_mode: true?(@params["_ansible_check_mode"]?),
        indent: indent_override,
        edits: edits
      )
    end

    private def apply_request(request : Request) : PluginResult
      path = request.path
      original = File.exists?(path) ? File.read(path) : ""
      document = parse_document(original, path)
      return document if document.is_a?(PluginResult)

      applied = apply_edits(document, request.edits, original, request.indent)
      return applied if applied.is_a?(PluginResult)
      changed, messages, new_content = applied

      finish(path, original, new_content, changed, messages, request.backup, request.check_mode)
    end

    private def apply_edits(doc : JSON::Any, edits : Array(Edit), original : String,
                            indent_override : String?) : {Bool, Array(String), String} | PluginResult
      changed = false
      messages = [] of String
      edits.each do |edit|
        outcome = apply_edit(doc, edit)
        return outcome if outcome.is_a?(PluginResult)
        edit_changed, message = outcome
        next unless edit_changed
        changed = true
        messages << message
      end

      new_content = if changed
                      serialize(doc, indent_to_write(original, indent_override), trailing_newline?(original))
                    else
                      original
                    end
      {changed, messages, new_content}
    end

    private def finish(path : String, original : String, new_content : String, changed : Bool,
                       messages : Array(String), backup : Bool, check_mode : Bool) : PluginResult
      backup_file = maybe_backup(path, changed, backup, check_mode)
      write_new_content(path, new_content) if changed && !check_mode

      attributes = apply_attributes(path, check_mode)
      return attributes if attributes.is_a?(PluginResult)
      changed = true if attributes

      result = PluginResult.new(
        changed: changed,
        failed: false,
        msg: messages.empty? ? "ok" : messages.uniq.join(", "),
        diff: content_diff(path, original, new_content),
        path: path,
        key_order: SUCCESS_KEY_ORDER
      )
      result.extra["backup_file"] = JSON::Any.new(backup_file) unless backup_file.empty?
      add_path_info(result, path)
      result
    end

    private def maybe_backup(path : String, changed : Bool, backup : Bool, check_mode : Bool) : String
      return "" unless changed && backup && File.exists?(path) && !check_mode
      write_backup(path)
    end

    # Ansible's modules run set_fs_attributes_if_different at exit on an
    # unchanged result too, so a drifted owner:/group:/mode:/se*: is itself
    # a change (the same tail ini_file's finish_execute has). Returns the
    # change flag, or the failure that stopped the run. Attribute drift is
    # invisible to check mode - FileAttrs never applies anything there, so
    # a --check run reports only what the content edit would change, exactly
    # as ini_file does.
    private def apply_attributes(path : String, check_mode : Bool) : Bool | PluginResult
      return false if check_mode || !File.exists?(path)

      attributes_changed, attributes_failure = apply_file_attrs(path, check_mode)
      return attributes_failure if attributes_failure

      secontext_changed, secontext_failure = apply_secontext(path, check_mode)
      return secontext_failure if secontext_failure

      attributes_changed || secontext_changed
    end

    private def content_diff(path : String, original : String, new_content : String) : JSON::Any
      if @diff_mode
        generate_unified_diff(original, new_content, "#{path} (content)", "#{path} (content)")
      else
        generate_unified_diff("", "", "#{path} (content)", "#{path} (content)")
      end
    end

    private def unsupported_params : Array(String)
      @params.keys.reject do |key|
        key.starts_with?('_') || SUPPORTED_PARAMS.includes?(key)
      end
    end

    # The `indent:` override: {whitespace unit, nil} for a value, {nil,
    # nil} for compact output, or {nil, failure} for an unparseable value.
    private def indent_setting : {String?, PluginResult?}
      raw = @params["indent"]?
      return {nil, nil} unless raw

      stripped = raw.strip
      return {nil, nil} if stripped == "0"
      if width = stripped.to_i?
        return {nil, failure("indent must not be negative")} if width < 0
        return {" " * width, nil}
      end
      return {raw, nil} if !raw.empty? && raw.each_char.all? { |char| char == ' ' || char == '\t' }
      {nil, failure("indent must be a number of spaces, a whitespace string, or 0 for compact output")}
    end

    # The file's own indentation unit: the smallest leading-run of spaces
    # any of its lines has (every indented line is then a multiple of it).
    # A compact single-line document stays compact; anything else with no
    # indentation at all gets DEFAULT_INDENT.
    private def indent_to_write(original : String, override : String?) : String?
      return override if @params.has_key?("indent")

      smallest = nil
      original.each_line do |line|
        if match = line.match(/\A( +)\S/)
          width = match[1].size
          smallest = width if smallest.nil? || width < smallest
        end
      end
      return " " * smallest if smallest
      return nil if !original.empty? && !original.includes?("\n")
      " " * DEFAULT_INDENT
    end

    private def serialize(doc : JSON::Any, indent : String?, trailing_newline : Bool) : String
      io = IO::Memory.new
      if indent
        JSON.build(io, indent: indent) { |json| doc.to_json(json) }
      else
        JSON.build(io) { |json| doc.to_json(json) }
      end
      trailing_newline ? io.to_s + "\n" : io.to_s
    end

    # A document that had no trailing newline keeps that shape; a new file
    # gets one.
    private def trailing_newline?(original : String) : Bool
      original.empty? || original.ends_with?("\n")
    end

    # A missing, empty or whitespace-only file starts from an empty object;
    # an existing document must be valid JSON, or the task fails instead of
    # rewriting something this module could not read.
    private def parse_document(original : String, path : String) : JSON::Any | PluginResult
      return JSON::Any.new(Hash(String, JSON::Any).new) if original.strip.empty?
      JSON.parse(original)
    rescue ex : JSON::ParseException
      failure("Unable to parse #{path} as JSON: #{ex.message}")
    end

    private def requested_edits : Array(Edit) | PluginResult
      if changes = @params["changes"]?
        return failure("parameters are mutually exclusive: key|changes") if @params.has_key?("key")
        return failure("parameters are mutually exclusive: value|changes") if @params.has_key?("value")
        return failure("parameters are mutually exclusive: value_type|changes") if @params.has_key?("value_type")
        return failure("parameters are mutually exclusive: state|changes") if @params.has_key?("state")
        return parse_changes(changes)
      end

      key = @params["key"]?
      return failure("missing required parameter: key (or changes)") unless key

      state = state_param(@params["state"]?)
      return state if state.is_a?(PluginResult)
      absent = state == "absent"

      value = absent ? JSON::Any.new(nil) : value_param
      return value if value.is_a?(PluginResult)

      segments = split_key(key)
      return segments if segments.is_a?(PluginResult)

      [Edit.new(segments, absent, value)]
    end

    private def parse_changes(raw : String) : Array(Edit) | PluginResult
      parsed = parse_container_text(raw)
      return failure("'changes' must be a list of {key, value} mappings") unless parsed

      entries = parsed.as_a?
      return failure("'changes' must be a list of {key, value} mappings") unless entries

      edits = [] of Edit
      entries.each_with_index do |entry, index|
        hash = entry.as_h?
        return failure("'changes' entry #{index + 1} must be a mapping") unless hash

        unknown = hash.keys - ["key", "path", "value", "state"]
        unless unknown.empty?
          return failure("Unsupported parameters in 'changes' entry #{index + 1}: #{unknown.join(", ")}")
        end

        key = hash["key"]?.try(&.as_s?) || hash["path"]?.try(&.as_s?)
        return failure("'changes' entry #{index + 1} needs a 'key'") unless key

        state = state_param(hash["state"]?.try(&.as_s?))
        return state if state.is_a?(PluginResult)
        absent = state == "absent"

        value = if absent
                  JSON::Any.new(nil)
                elsif explicit = hash["value"]?
                  explicit
                else
                  return failure("'changes' entry #{index + 1} needs a 'value'")
                end

        segments = split_key(key)
        return segments if segments.is_a?(PluginResult)

        edits << Edit.new(segments, absent, value)
      end

      edits
    end

    private def state_param(raw : String?) : String | PluginResult
      return "present" unless raw
      return raw if raw.in?("present", "absent")
      failure("invalid state: #{raw} (expected present or absent)")
    end

    # A dotted path, or a JSON/Python-literal list of segments (the only
    # way to address a key that itself contains a dot). A key that opens
    # a list but does not parse as one is an error, not a dotted path:
    # falling back to the dot split wrote garbage keys like "[a" from a
    # typo'd `key: "[a.b]"`.
    private def split_key(key : String) : Array(String) | PluginResult
      stripped = key.strip
      if stripped.starts_with?('[')
        list = parse_container_text(stripped).try(&.as_a?)
        return failure("invalid key '#{key}': not a JSON list of segments") unless list
        segments = list.map { |item| item.as_s? || item.to_json }
        return failure("key must have at least one segment") if segments.empty?
        return segments
      end

      segments = key.split('.')
      if segments.empty? || segments.any?(&.empty?)
        return failure("invalid key '#{key}': segments must not be empty")
      end
      segments
    end

    # The wire is strings-only, so a literal container arrives as JSON text
    # and a whole-span `{{ var }}` holding one renders as Python's own repr
    # (single quotes); both forms are accepted here.
    private def parse_container_text(text : String) : JSON::Any?
      JSON.parse(text)
    rescue
      PythonLiteral.literal_json(text)
    end

    # `value:` typing. The strings-only param wire erases most of YAML's
    # type information: an unquoted int/bool literal survives through the
    # parser's marker, a literal container arrives as JSON text, and
    # anything else - a quoted literal, a whole-span `{{ var }}` render -
    # is plain text and is written as a JSON STRING. A text that looks
    # like a JSON container is parsed as one (that is how a literal or
    # templated mapping reaches this plugin); `value_type: string` is the
    # escape hatch for a string value that itself reads as JSON. A
    # templated scalar that must stay a number or boolean goes through
    # `changes:`, whose entries are parsed as JSON text and therefore keep
    # their members' native types.
    private def value_param : JSON::Any | PluginResult
      return JSON::Any.new(nil) if explicit_null_param?("value")
      return failure("missing required parameter: value") unless @params.has_key?("value")

      as_string = false
      if raw_type = @params["value_type"]?
        return failure("invalid value_type: #{raw_type} (expected json or string)") unless raw_type.in?("json", "string")
        as_string = raw_type == "string"
      end

      if native = non_string_param("value")
        if as_string
          return failure("value_type: string cannot be combined with an unquoted non-string literal " \
                         "(#{@params["value"]}); quote the value to make it a string")
        end
        return native
      end

      text = @params["value"]
      return JSON::Any.new(text) if as_string
      if text.starts_with?('{') || text.starts_with?('[')
        if parsed = parse_container_text(text)
          return parsed
        end
        return failure("value is not valid JSON: #{text}")
      end
      JSON::Any.new(text)
    end

    private def apply_edit(doc : JSON::Any, edit : Edit) : {Bool, String} | PluginResult
      return failure("key must have at least one segment") if edit.segments.empty?
      if edit.absent?
        remove_path(doc, edit.segments)
      else
        set_path(doc, edit.segments, edit.value)
      end
    end

    # Present: every intermediate segment is followed, creating a missing
    # object along the way (an existing array is indexed by a numeric
    # segment; an index one past the end appends a new object). A JSON
    # null in the middle of the path is replaced by an object the same way
    # a missing key is - there is nothing under a null to descend into.
    private def set_path(doc : JSON::Any, segments : Array(String), value : JSON::Any) : {Bool, String} | PluginResult
      container = doc
      segments[0...-1].each do |segment|
        descended = descend_present(container, segment)
        return descended if descended.is_a?(PluginResult)
        container = descended
      end
      set_leaf(container, segments.last, value)
    end

    private def descend_present(container : JSON::Any, segment : String) : JSON::Any | PluginResult
      if hash = container.as_h?
        if existing = hash[segment]?
          return existing unless existing.raw.nil?
        end
        created = JSON::Any.new(Hash(String, JSON::Any).new)
        hash[segment] = created
        return created
      end

      if array = container.as_a?
        index = array_index(segment)
        return failure("'#{segment}' is not an array index") unless index
        return failure("array index #{index} out of range (size #{array.size})") if index > array.size
        if index < array.size
          existing = array[index]
          return existing unless existing.raw.nil?
          created = JSON::Any.new(Hash(String, JSON::Any).new)
          array[index] = created
          return created
        end
        created = JSON::Any.new(Hash(String, JSON::Any).new)
        array << created
        return created
      end

      failure("cannot descend into a #{json_type(container)} value at '#{segment}'")
    end

    private def set_leaf(container : JSON::Any, segment : String, value : JSON::Any) : {Bool, String} | PluginResult
      if hash = container.as_h?
        existing = hash[segment]?
        return {false, "ok"} if existing && existing == value
        hash[segment] = value
        return {true, existing ? "key changed" : "key added"}
      end

      if array = container.as_a?
        index = array_index(segment)
        return failure("'#{segment}' is not an array index") unless index
        return failure("array index #{index} out of range (size #{array.size})") if index > array.size
        if index == array.size
          array << value
          return {true, "key added"}
        end
        return {false, "ok"} if array[index] == value
        array[index] = value
        return {true, "key changed"}
      end

      failure("cannot set '#{segment}' on a #{json_type(container)} value")
    end

    # Absent: a path that does not exist is already in the requested state,
    # so nothing is created and nothing is reported changed. A JSON null
    # in the middle of the path counts as "does not exist" - you cannot
    # remove a key from a null.
    private def remove_path(doc : JSON::Any, segments : Array(String)) : {Bool, String} | PluginResult
      container = doc
      segments[0...-1].each do |segment|
        descended = descend_absent(container, segment)
        return {false, "ok"} if descended.nil?
        return descended if descended.is_a?(PluginResult)
        container = descended
      end
      remove_leaf(container, segments.last)
    end

    private def descend_absent(container : JSON::Any, segment : String) : JSON::Any? | PluginResult
      if hash = container.as_h?
        existing = hash[segment]?
        return nil if existing.try(&.raw.nil?)
        return existing
      end

      if array = container.as_a?
        index = array_index(segment)
        return failure("'#{segment}' is not an array index") unless index
        return nil if index >= array.size
        existing = array[index]
        return nil if existing.raw.nil?
        return existing
      end

      failure("cannot descend into a #{json_type(container)} value at '#{segment}'")
    end

    private def remove_leaf(container : JSON::Any, segment : String) : {Bool, String} | PluginResult
      if hash = container.as_h?
        return {true, "key removed"} if hash.delete(segment)
        return {false, "ok"}
      end

      if array = container.as_a?
        index = array_index(segment)
        return failure("'#{segment}' is not an array index") unless index
        return {false, "ok"} if index >= array.size
        array.delete_at(index)
        return {true, "key removed"}
      end

      failure("cannot remove '#{segment}' from a #{json_type(container)} value")
    end

    # A segment addresses an array position only as a plain non-negative
    # integer; anything else ("01", "-1", "1.5") is an object key.
    private def array_index(segment : String) : Int32?
      return nil unless segment.matches?(/\A(0|[1-9]\d*)\z/)
      index = segment.to_i?
      index && index <= Int32::MAX ? index : nil
    end

    private def json_type(value : JSON::Any) : String
      case value.raw
      when Nil     then "null"
      when Bool    then "boolean"
      when Int64   then "number"
      when Float64 then "number"
      when String  then "string"
      when Array   then "array"
      else              "object"
      end
    end

    # seuser:/serole:/setype:/selevel: through BasePlugin's shared helpers
    # (the same ones file, copy, template, lineinfile and stat use), so a
    # context change is detected and counted as changed instead of blindly
    # re-applied. Returns {changed, failure}.
    private def apply_secontext(path : String, check_mode : Bool) : {Bool, PluginResult?}
      return {false, nil} unless pending = pending_secontext_change(path)
      current, desired = pending
      return {true, nil} if check_mode
      if err = set_selinux_context(path, desired)
        return {false, selinux_context_failure(path, err, current, desired, secontext_input_was)}
      end
      {true, nil}
    end

    private def write_new_content(path : String, new_content : String) : Nil
      dir = File.dirname(path)
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      File.write(path, new_content)
    end

    # Ansible's own timestamped-backup naming (ini_file's copy).
    private def write_backup(path : String) : String
      timestamp = Time.utc.to_s("%Y-%m-%d@%H:%M:%S")
      backup_file = "#{path}.#{Process.pid}.#{timestamp}~"
      File.copy(path, backup_file)
      backup_file
    end

    private def failure(message : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: message)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::JsonFilePlugin.new(config)
plugin.run
