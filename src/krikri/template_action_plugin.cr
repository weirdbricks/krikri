require "json"
require "digest/md5"
require "krikri-jinja/krikri_jinja"
require "./krikri_jinja_filters"
require "./needle_lookup"
require "./jinja_host_context"
require "./template_search_path_loader"
require "./base_action_plugin"

module Krikri
  # Template Action Plugin
  # Runs on CONTROLLER to read and render Jinja2 templates
  # Then sends rendered content to remote host

  class TemplateActionPlugin < ActionPlugin
    @render_error : String? = nil

    # Set alongside @render_error when the render failed with the engine's
    # Undefined kind: real 2.19.11 propagates AnsibleUndefinedVariable out
    # of the template action as the task failure's bare msg - "Task failed:
    # 'bind_addr' is undefined" (live-verified, round 5300003
    # wasilak.centos-hashiui's chain-undefined template var) - with NO
    # "Failed to render template" wrapper and no line prefix.
    @render_error_undefined : Bool = false

    # Set alongside @render_error when the render died with the engine's
    # "<CrystalClass> is not iterable" raw message (render_for's else arm,
    # e.g. `{% for x in v %}` over a defined-but-null var). Real 2.19.11
    # does not fail with a rendered-but-generic "Failed to render
    # template" wording: the iteration TypeError unwinds out of the
    # action plugin UNCAUGHT, carrying the value's PYTHON type name (the
    # engine's Crystal one never appears), and takes the same crash shape
    # as the #jinja2: directive failure: "Task failed: Error rendering
    # template: 'NoneType' object is not iterable" (live-verified, issue
    # #274), the [ERROR] block's cause pointing at the template FILE's
    # Origin exactly like it - path only, no line/column. Holds the full
    # cause wording (nil when the raw type is not one whose Python name
    # this engine surface can state with certainty - see
    # #not_iterable_ansible_wording).
    @render_error_not_iterable : String? = nil

    # Set alongside @render_error when the render died with the engine's
    # unknown-FILTER error ("unknown filter \"x\""): real 2.19.11 fails
    # an unknown filter name inside a template FILE at template COMPILE
    # time, as an uncaught TemplateAssertionError - "Task failed: Syntax
    # error in template: No filter named 'x'." with the [ERROR] block's
    # cause pointed at the template file itself (live-verified vs
    # 2.19.11 on the bersace.dockerdns shape, issue #335) - NOT the
    # generic "Failed to render template" wording the other render
    # failures take. Holds the full cause wording.
    @render_error_unknown_filter : String? = nil

    # Set when the template's own leading `#jinja2:` directive line
    # failed Ansible's literal_eval/type validation (see
    # #extract_jinja2_directive): the crash's Origin is the TEMPLATE
    # file, not the task's YAML, so it travels separately from
    # @render_error (crash_failure's #error_origin).
    @directive_error : String? = nil

    # Raised for an invalid `#jinja2:` directive value - Ansible's
    # TemplateOverrides dataclass post-init validation (or ast.
    # literal_eval) dying inside the template ACTION plugin. The message
    # is the BARE "Syntax error in template: ..." text; ActionResult.
    # crash_failure adds the "Task failed: " prefix the fatal dump
    # carries while the [ERROR] block stays bare.
    class Jinja2DirectiveError < Exception
    end

    def execute : ActionResult
      # The parser's non-string-literal markers (NON_STRING_PARAM_PREFIX)
      # arrive intact here (execute_action deliberately exempts template:)
      # because the src/dest/output_encoding conversions need the native
      # type (src is coerced through Python str() here; dest rides the
      # marker to the plugin binary, which applies the same coercion, and
      # output_encoding is read through Ansible's own `or 'utf-8'` fallback
      # plus its encode() type crash - see template_output_encoding).
      # Every OTHER param is demoted back to its plain string first, so the
      # Jinja knob bools (`trim_blocks: true`) and strings see exactly the
      # text they always did - the same contract BasePlugin's param parse
      # gives the plugin binaries.
      demoted = Hash(String, String).new
      @params.each do |key, value|
        if !{"src", "dest", "output_encoding"}.includes?(key) && (native = Krikri.non_string_scalar(value))
          demoted[key] = Krikri.non_string_param_text(native)
        else
          demoted[key] = value
        end
      end
      @params = demoted

      # newline_sequence: template-only param (Ansible strips it from
      # the module args - it is consumed HERE, on the controller, by the
      # Jinja environment). Default "\n"; the three documented values are
      # accepted, including their YAML-escaped literal forms ("\\n" typed
      # with a backslash, which YAML/CLI quoting can hand over as a
      # literal two-character string - Ansible's own
      # wrong_sequences normalization), anything else fails the task with
      # Ansible's exact message before any template is touched
      # (live-verified against ansible-core 2.19.4; the 2.19.11 bytes
      # carry REAL control characters - the Python source literal
      # "\n, \r or \r\n" - and Ansible's error pipeline .strip()s the
      # message, dropping the trailing " \r\n", which is what both the
      # [ERROR] block and the fatal JSON then show).
      # `.presence` is deliberately NOT used on the raw value: it treats
      # a whitespace-only string as unset, and "\r"/"\r\n" are ALL
      # whitespace - newline_sequence: "\r\n" silently fell back to the
      # "\n" default and the CRLF conversion never ran. Only a missing
      # key or a truly empty value means "use the default".
      raw_sequence = @params["newline_sequence"]?
      newline_sequence = (raw_sequence.nil? || raw_sequence.empty?) ? "\n" : raw_sequence
      case newline_sequence
      when "\\n"    then newline_sequence = "\n"
      when "\\r"    then newline_sequence = "\r"
      when "\\r\\n" then newline_sequence = "\r\n"
      end
      unless ["\n", "\r", "\r\n"].includes?(newline_sequence)
        return ActionResult.failure("newline_sequence needs to be one of: \n, \r or")
      end

      # Get source template path
      src = @params["src"]?
      unless src
        return ActionResult.failure("Missing required parameter: src")
      end

      # An EMPTY src skips Ansible's search entirely (its `source and ...`
      # branch never runs, so no candidate list is built) and fails with
      # the bare not-found wording.
      if src.empty?
        return ActionResult.failure(Krikri::NeedleLookup.not_found_message(src, [] of String))
      end

      # A non-string YAML literal src (`src: true`) is coerced through
      # Python str() by Ansible's action plugin before the search - bools
      # render as "True"/"False" (live-verified: real searches for a file
      # literally named "True"), so a bare `src: true` must look for
      # "True", not the YAML text "true" (see NON_STRING_PARAM_PREFIX).
      if native = Krikri.non_string_scalar(src)
        src = Krikri.python_str_scalar(native)
      end

      # Ansible's own _find_needle/copy action wording for a missing
      # source: a RELATIVE src reports the full searched-paths list (the
      # task's search stack plus the playbook basedir, see NeedleLookup),
      # an absolute one reports no list at all (Ansible's absolute branch
      # never populates one) - both live-verified against 2.19.11.
      resolved_src, candidates = resolve_controller_src(src)
      unless resolved_src
        return ActionResult.failure(Krikri::NeedleLookup.not_found_message(src, candidates))
      end
      src = resolved_src

      # Read template content
      begin
        template_content = File.read(src)
      rescue ex
        # Ansible's template action reads the source through
        # _loader._get_file_contents, whose IOError wrapper is an uncaught
        # task crash: "Task failed: " prefix, Python's [Errno N] wording,
        # and the TASK as Origin (a directory src gives Errno 21).
        if Dir.exists?(src)
          detail = "An error occurred while trying to read the file '#{src}': [Errno 21] Is a directory: '#{src}'"
          return ActionResult.crash_failure(detail)
        end
        return ActionResult.failure("Failed to read template file: #{ex.message}")
      end

      # Render template on CONTROLLER
      rendered_content = render_template(template_content, src)
      unless rendered_content
        # An invalid `#jinja2:` directive line is an UNCAUGHT Python
        # exception inside Ansible's template action plugin: the fatal
        # dump's msg keeps the "Task failed: " wrapper while the [ERROR]
        # block's cause stays bare and points at the TEMPLATE file's
        # Origin (round 1500121, apolloclark.packetbeat's
        # `#jinja2: trim_blocks: "true"` - a quoted string where the
        # dataclass demands a bool).
        if directive = @directive_error
          return ActionResult.crash_failure(directive, src)
        end
        if @render_error_undefined && (msg = @render_error)
          # Real's undefined-variable failure is an UNCAUGHT
          # AnsibleUndefinedVariable unwinding out of the action plugin -
          # the crash shape (fatal msg "Task failed: 'bind_addr' is
          # undefined", live-verified, round 5300003
          # wasilak.centos-hashiui), the [ERROR] block's cause carrying
          # the bare wording (no "Failed to render template" wrapper) and
          # the TEMPLATE file as its Origin... which real REPLACES with
          # the failing VALUE's definition when that value is itself an
          # unrendered `{{ }}` template (the executor's
          # _ansible_undef_chain_origin looks it up - see #undef_chain).
          # The engine's own "line N: " prefix is dropped: the bare
          # ansible-core wording carries no line info.
          return ActionResult.crash_failure(msg, src, undef_chain: true)
        end
        if wording = @render_error_not_iterable
          # The scalar-iteration TypeError takes the same UNCAUGHT crash
          # shape ("Task failed: Error rendering template: 'NoneType'
          # object is not iterable", live-verified, issue #274) - no
          # undef chain, though: a null value's Origin is the TEMPLATE
          # file itself, unlike an undefined var's layered definition.
          return ActionResult.crash_failure(wording, src)
        end
        if (msg = @render_error) && msg.starts_with?("Syntax error in template: Encountered unknown tag 'do'")
          # A `{% do %}` inside a variable's value is compiled by ansible
          # when the template reads it: an uncaught TemplateSyntaxError
          # with the crash shape, whose inner Origin is the variable's
          # definition (live-verified, issue #322).
          return ActionResult.crash_failure(msg, src, undef_chain: true)
        end
        if wording = @render_error_unknown_filter
          # Same uncaught-compile-error shape for an unknown FILTER name
          # inside the template file itself: "Task failed: Syntax error
          # in template: No filter named 'x'.", the cause's Origin the
          # template file (live-verified vs 2.19.11, issue #335). No
          # undef chain: the failing name is in the TEMPLATE text, not a
          # variable value.
          return ActionResult.crash_failure(wording, src)
        end
        detail = @render_error ? ": #{@render_error}" : ""
        return ActionResult.failure("Failed to render template#{detail}")
      end

      # Calculate MD5 of rendered content
      content_md5 = Digest::MD5.hexdigest(rendered_content)

      # newline_sequence: Ansible passes this to the Jinja2
      # environment, whose lexer normalizes EVERY newline in the rendered
      # output (the template source's own line breaks and any Jinja-emitted
      # ones alike) to the requested sequence - verified byte-level
      # against ansible-core 2.19.4 (newline_sequence="\r\n" turns a
      # plain-LF template's entire output into CRLF). Crinja's lexer
      # hard-codes "\n", so the same normalization is applied to the
      # finished render here: split on any newline form and rejoin (the
      # same shape Jinja2's lexer itself uses). Done AFTER
      # render_template's own trailing-newline normalization so the
      # appended final newline obeys the sequence too.
      if newline_sequence != "\n"
        rendered_content = rendered_content.split(/\r\n|\r|\n/).join(newline_sequence)
      end

      # output_encoding: Ansible's action plugin writes the rendered result
      # into its own temporary file with Python's
      # `to_bytes(resultant, encoding=output_encoding, errors=...)` and only
      # THEN hands the task to the copy action plugin - so a non-string
      # output_encoding crashes the ACTION plugin with Python's own
      # TypeError, before the copy module's spec ever sees the args. That
      # makes the crash the first thing such a task reports: a typo'd
      # option or a wrong-typed bool beside the literal is never
      # reported (live-verified vs 2.19.11: int/float/bool/list/dict all
      # crash here, and so do the typo'd and the wrong-typed-boolean
      # neighbours). Placed after the render for the same reason real
      # encodes after it - a broken template body still reports the
      # template error first.
      output_encoding, encode_crash = template_output_encoding
      if encode_crash
        return ActionResult.crash_failure(encode_crash)
      end
      if output_encoding && !known_output_encoding?(output_encoding)
        return ActionResult.crash_failure("unknown encoding: #{output_encoding}")
      end

      # Modify params to send rendered CONTENT to remote instead of template path
      # The remote plugin will receive the rendered content, not the template
      modified_params = @params.dup
      modified_params.delete("src")                      # Remove src parameter
      modified_params["content"] = rendered_content      # Add rendered content
      modified_params["_rendered_from_template"] = src   # Track for debugging
      modified_params["_content_checksum"] = content_md5 # For idempotency
      modified_params["output_encoding"] = output_encoding if output_encoding

      ActionResult.success?(modified_params, changed: false)
    end

    # The encoding Ansible's template action plugin writes the rendered
    # result with, and the Python TypeError it dies with when the value
    # cannot be one - the pair `{encoding, crash_message}`, exactly the
    # shape of Ansible's own line
    # `output_encoding = self._task.args.get('output_encoding', 'utf-8') or 'utf-8'`
    # followed by its `to_bytes(resultant, encoding=output_encoding)`
    # (template.py:74 and :158, live-verified against 2.19.11):
    #
    # - a FALSY value is silently the default: `false`, `0`, `0.0`, an
    #   explicit None and an empty list/dict all deploy as utf-8, so the
    #   plugin binary must not be handed the literal's own text (it would
    #   try to encode to "false"/"0" and fail a task real completes);
    # - a TRUTHY non-string value crashes Python's codec stack - "encode()
    #   argument 'encoding' must be str, not _AnsibleTaggedInt" for an
    #   int, plain 'bool' for a bool (bools are not tagged in Ansible 2.19),
    #   '_AnsibleTaggedFloat'/'_AnsibleTaggedList'/'_AnsibleTaggedDict'
    #   for the rest;
    # - a plain string is the codec name as written (an unknown one still
    #   fails the task with Ansible's "unknown encoding: ..." wording, which
    #   the plugin binary produces). A LIST of plain strings is
    #   indistinguishable from such a string on the params wire (the
    #   parser comma-joins it), so it keeps the string reading - the one
    #   deliberate gap here; a list with non-string members keeps its
    #   marker and is read as the list Ansible sees.
    private def template_output_encoding : {String?, String?}
      raw = @params["output_encoding"]?
      return {nil, nil} if raw.nil?
      return {"utf-8", nil} if raw.empty? || raw == Krikri::NONE_SENTINEL
      if native = Krikri.non_string_scalar(raw)
        return {nil, template_encode_crash(native)} if Krikri.python_param_truthy?(raw)
        return {"utf-8", nil}
      end
      if (parsed = (JSON.parse(raw) rescue nil)) && (parsed.as_a? || parsed.as_h?)
        return {"utf-8", nil} if parsed.as_a?.try(&.empty?) || parsed.as_h?.try(&.empty?)
        return {nil, template_encode_crash(parsed)}
      end
      if raw.includes?(Krikri::NON_STRING_MEMBER_PREFIX)
        return {nil, "encode() argument 'encoding' must be str, not _AnsibleTaggedList"}
      end
      {raw, nil}
    end

    private def template_encode_crash(native : JSON::Any) : String
      "encode() argument 'encoding' must be str, not #{Krikri.python_value_type_name(native)}"
    end

    # Whether *name* is a codec Ansible's Python stack can encode to. Real
    # resolves the name in its own codec registry and raises
    # LookupError("unknown encoding: <name>") for one it does not have -
    # from the same to_bytes call as the non-string crash above, so an
    # unknown codec is reported as an action-plugin crash there too, not
    # as a module failure. The candidate search mirrors the plugin
    # binary's own encode_output (Ansible's documented "latin-1" is
    # "latin1"/"ISO-8859-1" to iconv); the byte-level conversion itself
    # still happens in the plugin binary, which is the only place the
    # rendered content exists.
    private def known_output_encoding?(name : String) : Bool
      return true if name.downcase == "utf-8" || name.downcase == "utf8"
      {name, name.delete("-_"), name.upcase, name.delete("-").upcase}.each do |candidate|
        begin
          "".encode(candidate)
          return true
        rescue ArgumentError
        end
      end
      false
    end

    # Render a Jinja2 template with krikri-jinja. A role-local
    # `filter_plugins/*.py` filter is resolved on demand and registered on
    # this render's own engine, then the render is retried once.
    private def render_template(template_content : String, template_path : String) : String?
      directive_overrides, content = extract_jinja2_directive(template_content)
      content = rewrite_crinja_compat(content) unless custom_delimiters?

      options = KrikriJinja::LexerOptions.new(
        block_start: delimiter_param("block_start_string", "{%"),
        block_end: delimiter_param("block_end_string", "%}"),
        var_start: delimiter_param("variable_start_string", "{{"),
        var_end: delimiter_param("variable_end_string", "}}"),
        comment_start: delimiter_param("comment_start_string", "{#"),
        comment_end: delimiter_param("comment_end_string", "#}"),
        trim_blocks: directive_overrides.fetch("trim_blocks", true?(@params["trim_blocks"]?, default: true)),
        lstrip_blocks: directive_overrides.fetch("lstrip_blocks", true?(@params["lstrip_blocks"]?, default: false))
      )

      # Same deferred filter_plugins trigger as the bridge entries (see
      # PythonFilterRunner#scan_for_filter_use): a template-module .j2
      # whose content uses a filter is exactly where real Ansible loads
      # every filter_plugins file of the loaded roles + the
      # playbook-adjacent dir and warns about an unloadable one - a
      # static or filter-free template stays silent (issue #307,
      # live-verified vs 2.19.11). This engine derives its own
      # environment, so the parse-level gate has to run here.
      parsed_template : KrikriJinja::Nodes::TemplateNode? = nil
      begin
        template = KrikriJinja::Parser.parse(content, options)
        parsed_template = template
        Krikri::PythonFilterRunner.scan_for_filter_use(template, @vars["playbook_dir"]?.try(&.as_s?))
      rescue KrikriJinja::TemplateError
        nil
      end

      # The play_hosts read deprecation: this render hands the engine its
      # whole variable scope up front with no per-read resolver hook, so
      # the read is detected on the PARSED template instead - a direct
      # `play_hosts` name in the AST is a read, an attribute access
      # (`x.play_hosts`) or a string/comment occurrence is not.
      # ansible-core 2.19.11's Origin here is the template file alone, no
      # line/column.
      if template = parsed_template
        if template_reads_play_hosts?(template)
          Krikri::ResultDisplay.emit_play_hosts_deprecation(
            ErrorBlock.origin_context(File.expand_path(template_path), 0, nil, show_content: false)
          )
        end
      end

      template_vars = prepare_template_vars_json(template_path)
      engine = KrikriJinja.derive_engine(
        build_template_loader(template_path), options,
        KrikriJinja.ansible_strict_undefined, JinjaHostContext.new(template_vars)
      )
      begin
        # Ansible/Jinja2 compile the WHOLE template before any of it runs,
        # so every filter name in a non-soft frame is resolved at compile
        # time: an unknown filter fails the task even from a branch that
        # never executes when the nearest enclosing construct is a for,
        # with, filter/set/call block or the top level (an `{% if %}` over
        # an empty list wrapping a `{% for %}`; issue #651, live-verified
        # vs 2.19.11). An if branch or conditional expression is a SOFT
        # frame - real defers the name there and only fails at render time
        # if it is actually evaluated (issue #660). The engine itself only
        # raises when a filter node is evaluated, so the same "unknown
        # filter" error is raised up front here for the non-soft names and
        # the rescue below handles it through its normal path - including
        # the role-local filter_plugins retry, which registers the filter
        # on this engine before re-rendering.
        if template = parsed_template
          validate_template_filters(engine, template)
        end
        compile_checked = true
        render_once(engine, content, template_vars)
      rescue ex : KrikriJinja::TemplateError
        # A role-local `filter_plugins/*.py` filter is resolved on demand
        # and registered on this render's own engine, then the render is
        # retried once with that same engine. The same one-chance retry
        # applies to an unknown TEST name - a role-local (or
        # playbook-adjacent) `test_plugins/*.py` test, which Ansible
        # loads on the controller at template-compile time the same way
        # (Aisbergg.networkmanager's `value is list`, round 2300110).
        filter_name = KrikriJinjaFilters.unknown_filter_name(ex)
        if filter_name && KrikriJinjaFilters.ensure_python_filter(filter_name, template_vars, engine)
          render_once(engine, content, template_vars)
        elsif filter_name
          # Still unknown after the role-local plugin chance: real fails
          # at compile time with the uncaught TemplateAssertionError
          # shape (see @render_error_unknown_filter) when the name sat in
          # a non-soft frame, but a soft-frame name (if branch,
          # conditional expression) that reached evaluation is real's
          # RENDER-time failure wording instead (live-verified vs
          # 2.19.11, issue #660) - it only ever errors once evaluated, so
          # a false if keeps the task passing. compile_checked is set
          # before the first render, so it is false only for an error
          # raised by validate_template_filters above.
          @render_error_unknown_filter = if compile_checked
                                           "Error rendering template: No filter named '#{filter_name}' found."
                                         else
                                           "Syntax error in template: No filter named '#{filter_name}'."
                                         end
          raise ex
        elsif test_name = KrikriJinjaFilters.unknown_test_name(ex)
          if KrikriJinjaFilters.ensure_python_test(test_name, template_vars, engine)
            render_once(engine, content, template_vars)
          else
            raise ex
          end
        else
          raise ex
        end
      end
    rescue ex : Jinja2DirectiveError
      # The template's own `#jinja2:` directive line failed validation
      # (see #extract_jinja2_directive) - carried separately from
      # @render_error so execute can give it the crash shape (fatal
      # "Task failed: ..." wrapper, template-file Origin) instead of the
      # generic "Failed to render template: ..." wording.
      @directive_error = ex.message
      nil
    rescue ex : KrikriJinja::TemplateError
      @render_error_not_iterable = not_iterable_ansible_wording(ex)
      @render_error_undefined = ex.kind == KrikriJinja::ErrorKind::Undefined
      @render_error = ansible_wording(ex, line_prefix: !@render_error_undefined)
      nil
    rescue ex
      @render_error = ex.message
      nil
    end

    # The ansible-core crash wording for a render_for else-arm death,
    # nil when this surface cannot state the Python name. The engine's
    # raw message is "<CrystalClass> is not iterable" with the class
    # names Crystal prints ({"Nil", "Bool", "Int64", "Float64"} for the
    # scalars, the namespace prefixed one for everything else -
    # "KrikriJinja::BigIntValue", "Krikri::DateTime"), so the shape is
    # matched on the fully qualified name and mapped by the LAST part.
    # Only names whose Python correspondence is live-verified against
    # real 2.19.11 for THIS path get a mapping: None cannot carry a
    # datatag (a playbook var `al:` reports plain 'NoneType'), bools
    # report plain 'bool', int/float VARS keep their YAML datatags
    # ('_AnsibleTaggedInt' / '_AnsibleTaggedFloat', live-verified - the
    # engine carries no tag state today, so a template-local untainted
    # `1.5` iterating is reported as a tagged one too), computed
    # oversized ints arrive here only through the template's own
    # arithmetic (untagged in real: 'int'), and the datetime host
    # objects map to their module-qualified Python names. Everything
    # else (engine-internal Markup/Callable/Loop* - a Python Markup is a
    # str and would NOT fail iteration) keeps the generic render
    # failure wording rather than claiming behavior real does not have.
    private def not_iterable_ansible_wording(ex : KrikriJinja::TemplateError) : String?
      # indent's non-string TypeError is likewise an uncaught filter-plugin
      # failure in real (a macro with no output hands it None), with the
      # same crash shape and the template FILE as Origin.
      if ex.raw_message.includes?("unsupported operand type(s) for +=:")
        return "The filter plugin 'ansible.builtin.indent' failed: #{ex.raw_message}"
      end
      # A division by an int (bodsch.rspamd's macros.j2 divides a string
      # literal by 0, issue #435) is Python's TypeError too, same crash
      # shape and Origin. The engine reports no operand types, so
      # str-by-int is the only shape live-verified against ansible 2.19;
      # other operand combinations need the engine to report them before
      # they can be worded.
      if ex.raw_message == "unsupported operand for /"
        return "Error rendering template: unsupported operand type(s) for /: 'str' and 'int'"
      end
      match = ex.raw_message.match(/\A(?:\w+::)*(?<cls>\w+) is not iterable\z/)
      return nil unless match
      py_type = case match["cls"]
                when "Nil"         then "NoneType"
                when "Bool"        then "bool"
                when "Int64"       then "_AnsibleTaggedInt"
                when "Float64"     then "_AnsibleTaggedFloat"
                when "BigIntValue" then "int"
                when "DateTime"    then "datetime.datetime"
                when "TimeDelta"   then "datetime.timedelta"
                else                    return nil
                end
      "Error rendering template: '#{py_type}' object is not iterable"
    end

    # Renders through the engine once and applies Ansible's own
    # trailing-newline convention to the result.
    private def render_once(engine : KrikriJinja::Engine, content : String,
                            template_vars : Hash(String, JSON::Any)) : String
      rendered = engine.render_string(
        content,
        template_vars.transform_values { |value| engine_scope_value(value) }
      )
      # Ansible drops an `omit` value out of a rendered string entirely -
      # a template whose body is `A{{ omit }}B` writes "AB" (live-verified
      # against 2.19.11), the same drop its finalize pass applies inside
      # dict/list values. Without this the sentinel string every other path
      # compares against would leak into the written file verbatim.
      rendered = rendered.gsub(Krikri::OMIT_SENTINEL, "") if rendered.includes?(Krikri::OMIT_SENTINEL)
      # An empty render stays empty (live-verified vs 2.19.11: a template
      # whose output is "" writes a 0-byte file and reruns `ok` against an
      # existing empty dest) - only non-empty output gets the newline.
      # Ansible's own _post_render_mutation doesn't just append one \n:
      # it counts the trailing newlines of the template SOURCE against
      # those of the rendered result and appends the difference, so a
      # source ending in two newlines stays two after Jinja chomps one
      # and trim_blocks eats block-tag ones (live-verified: a source
      # ending "{% endfor %}\n\n" writes both newlines after the loop).
      if !rendered.empty? && (missing = trailing_newline_count(content) - trailing_newline_count(rendered)) > 0
        rendered += "\n" * missing
      end
      rendered
    end

    private def trailing_newline_count(string : String) : Int32
      string.size - string.rstrip('\n').size
    end

    # Compile-time filter-name validation over the whole parsed template,
    # raising the engine's own "unknown filter" wording (the same message
    # shape its runtime evaluation raises) for the first name the render's
    # engine could not resolve AND that Jinja2's compiler would resolve
    # eagerly: a filter whose nearest enclosing construct is an if or a
    # conditional expression sits in a soft frame and is only resolved
    # when actually evaluated (see
    # PythonFilterRunner.collect_compile_time_filter_calls, issue #660).
    # The check MUST mirror the runtime lookup
    # exactly or valid templates break: Context#filter resolves an exact
    # name first, then - for a 2+-dot collection-qualified name - its
    # trailing segment (`ansible.builtin.ternary` -> `ternary`); engine.
    # known_filter? downcases the name and lacks the segment fallback, so
    # neither side of the runtime lookup is available off the shelf and the
    # check consults the render engine's own filter hash directly.
    private def validate_template_filters(engine : KrikriJinja::Engine,
                                          template : KrikriJinja::Nodes::TemplateNode) : Nil
      Krikri::PythonFilterRunner.collect_compile_time_filter_calls(template).each do |(name, line)|
        next if resolvable_filter?(engine, name)
        raise KrikriJinja::TemplateError.new("unknown filter #{name.inspect}", line)
      end
    end

    private def resolvable_filter?(engine : KrikriJinja::Engine, name : String) : Bool
      return true if engine.filters.has_key?(name)
      short = name.count('.') >= 2 ? name.rpartition('.')[2] : nil
      !!(short && engine.filters.has_key?(short))
    end

    # Whether the parsed template contains a direct read of `play_hosts`
    # - the one magic variable whose read krikri warns about (the read
    # hook above). Statement bodies are walked for nested expressions,
    # expressions for their operand/subexpression trees; assignment
    # TARGETS are strings on their nodes, not NameNodes, so `{% set
    # play_hosts = ... %}` marks nothing itself (a later READ of the
    # shadowed name still counts - the shadowing shape is rare enough
    # that real-vs-krikri stays aligned in practice). The catch-all
    # `else` keeps an engine adding a node type here from crashing a
    # render over a deprecation scan.
    private def template_reads_play_hosts?(node : KrikriJinja::Nodes::Node) : Bool
      case node
      when KrikriJinja::Nodes::NameNode
        node.name == "play_hosts"
      when KrikriJinja::Nodes::TextNode, KrikriJinja::Nodes::ConstNode,
           KrikriJinja::Nodes::InTestNode
        false
      when KrikriJinja::Nodes::TemplateNode
        any_node_reads_play_hosts?(node.body)
      when KrikriJinja::Nodes::OutputNode, KrikriJinja::Nodes::DoNode
        template_reads_play_hosts?(node.expr)
      when KrikriJinja::Nodes::IfNode
        node.branches.any? { |(test, body)| template_reads_play_hosts?(test) || any_node_reads_play_hosts?(body) } ||
          (node.orelse.try { |orelse| any_node_reads_play_hosts?(orelse) } || false)
      when KrikriJinja::Nodes::ForNode
        template_reads_play_hosts?(node.iter) ||
          (node.test.try { |test| template_reads_play_hosts?(test) } || false) ||
          any_node_reads_play_hosts?(node.body) ||
          (node.orelse.try { |orelse| any_node_reads_play_hosts?(orelse) } || false)
      when KrikriJinja::Nodes::SetNode
        template_reads_play_hosts?(node.expr) ||
          (node.attr_target.try { |target| template_reads_play_hosts?(target) } || false) ||
          (node.body.try { |body| any_node_reads_play_hosts?(body) } || false) ||
          exprs_read_play_hosts?(node.filter_args) ||
          node.filter_kwargs.any? { |kwarg| template_reads_play_hosts?(kwarg[1]) }
      when KrikriJinja::Nodes::BlockNode, KrikriJinja::Nodes::AutoescapeNode
        any_node_reads_play_hosts?(node.body)
      when KrikriJinja::Nodes::MacroNode
        node.params.any? { |param| (default = param[1]) && template_reads_play_hosts?(default) } ||
          any_node_reads_play_hosts?(node.body)
      when KrikriJinja::Nodes::CallNode
        template_reads_play_hosts?(node.macro_expr) ||
          exprs_read_play_hosts?(node.args) ||
          node.kwargs.any? { |kwarg| template_reads_play_hosts?(kwarg[1]) } ||
          (node.body.try { |body| any_node_reads_play_hosts?(body) } || false)
      when KrikriJinja::Nodes::FilterBlockNode
        template_reads_play_hosts?(node.filter) || any_node_reads_play_hosts?(node.body)
      when KrikriJinja::Nodes::WithNode
        node.bindings.any? { |binding| template_reads_play_hosts?(binding[1]) } ||
          any_node_reads_play_hosts?(node.body)
      when KrikriJinja::Nodes::IncludeNode, KrikriJinja::Nodes::ExtendsNode, KrikriJinja::Nodes::ImportNode
        template_reads_play_hosts?(node.template)
      when KrikriJinja::Nodes::ListExprNode, KrikriJinja::Nodes::TupleExprNode
        exprs_read_play_hosts?(node.items)
      when KrikriJinja::Nodes::ConcatNode
        exprs_read_play_hosts?(node.parts)
      when KrikriJinja::Nodes::DictExprNode
        exprs_read_play_hosts?(node.keys) || exprs_read_play_hosts?(node.values)
      when KrikriJinja::Nodes::BinOpNode
        template_reads_play_hosts?(node.left) || template_reads_play_hosts?(node.right)
      when KrikriJinja::Nodes::UnaryOpNode
        template_reads_play_hosts?(node.operand)
      when KrikriJinja::Nodes::CompareNode
        template_reads_play_hosts?(node.left) || exprs_read_play_hosts?(node.comparators)
      when KrikriJinja::Nodes::FilterNode, KrikriJinja::Nodes::TestNode
        template_reads_play_hosts?(node.target) ||
          exprs_read_play_hosts?(node.args) ||
          node.kwargs.any? { |kwarg| template_reads_play_hosts?(kwarg[1]) }
      when KrikriJinja::Nodes::GetattrNode
        template_reads_play_hosts?(node.obj)
      when KrikriJinja::Nodes::GetitemNode
        template_reads_play_hosts?(node.obj) || template_reads_play_hosts?(node.key)
      when KrikriJinja::Nodes::SliceNode
        template_reads_play_hosts?(node.obj) ||
          (node.start.try { |expr| template_reads_play_hosts?(expr) } || false) ||
          (node.stop.try { |expr| template_reads_play_hosts?(expr) } || false) ||
          (node.step.try { |expr| template_reads_play_hosts?(expr) } || false)
      when KrikriJinja::Nodes::CallExprNode
        template_reads_play_hosts?(node.func) ||
          exprs_read_play_hosts?(node.args) ||
          node.kwargs.any? { |kwarg| template_reads_play_hosts?(kwarg[1]) }
      when KrikriJinja::Nodes::CondExprNode
        template_reads_play_hosts?(node.test) ||
          template_reads_play_hosts?(node.truthy) ||
          (node.falsy.try { |expr| template_reads_play_hosts?(expr) } || false)
      else
        false
      end
    end

    private def any_node_reads_play_hosts?(body : Array(KrikriJinja::Nodes::Node)) : Bool
      body.any? { |child| template_reads_play_hosts?(child) }
    end

    private def exprs_read_play_hosts?(exprs : Array(KrikriJinja::Nodes::ExprNode)) : Bool
      exprs.any? { |expr| template_reads_play_hosts?(expr) }
    end

    # Engine-scope conversion for the template render's variable loading.
    # The plain-JSON path is KrikriJinja.from_json_any unchanged; a
    # UNDEFINED_LEAF_MARKER-wrapped leaf (JinjaRenderer's defer-walk) is
    # loaded as a strict chainable Undefined carrying the walk's own
    # real-Ansible message instead. That is what real ansible-core 2.19
    # hands the template engine for a var whose value chain bottoms out at
    # a name set nowhere (rounds 5300003 wasilak.centos-hashiui /
    # 5300004 SathiyarajPeriyannan.vsphere): touching it inside the
    # template fails the task with exactly that innermost message
    # (`'bind_addr' is undefined`), an untouched sibling leaf still never
    # renders strictly (the round-952484 laziness), and the undefined
    # consumers in between behave like Ansible's too - `| default('x')`
    # falls through, `is defined` is False (live-verified vs 2.19.11),
    # and stringification raises rather than printing the raw text.
    private def engine_scope_value(value : JSON::Any) : KrikriJinja::AnyValue
      case raw = value.raw
      when Array
        KrikriJinja::AnyValue.new(raw.map { |item| engine_scope_value(item) })
      when Hash
        converted = {} of String => KrikriJinja::AnyValue
        raw.each { |key, item| converted[key] = engine_scope_value(item) }
        KrikriJinja::AnyValue.new(converted)
      when String
        if message = Krikri.undefined_leaf_message?(raw)
          undefined = KrikriJinja::StrictUndefined.new(nil, chainable: true)
          undefined.hint = message
          KrikriJinja::AnyValue.new(undefined)
        else
          KrikriJinja.from_json_any(value)
        end
      else
        KrikriJinja.from_json_any(value)
      end
    end

    # Loader rooted at the template's own directory plus its role's
    # templates/ ancestors, matching Ansible's role template search
    # path (the engine's default loader searches only the CWD).
    private def build_template_loader(template_path : String) : KrikriJinja::Loader?
      tpl_dir = File.dirname(File.expand_path(template_path))
      return nil unless tpl_dir.starts_with?("/")

      searchpaths = [tpl_dir]
      dir = tpl_dir
      templates_root = File.basename(tpl_dir) == "templates" ? tpl_dir : nil
      while templates_root.nil? && (dir = File.dirname(dir)) != "/" && dir.split("/").includes?("templates")
        searchpaths << dir
        if File.basename(dir) == "templates"
          templates_root = dir
          break
        end
      end
      if templates_root
        role_root = File.dirname(templates_root)
        searchpaths << role_root unless searchpaths.includes?(role_root)
      end
      TemplateSearchPathLoader.new(searchpaths)
    end

    # Ansible's own wording for a strict-undefined failure is
    # "'name' is undefined"; krikri-jinja already uses that phrasing. An
    # attribute miss is reworded from Jinja's "'dict object' has no
    # attribute 'x'" to ansible-core's "object of type 'dict' has no
    # attribute 'x'".
    private def jinja_error_message(ex : KrikriJinja::TemplateError) : String
      ansible_wording(ex, line_prefix: true)
    end

    # The engine message with the attribute-miss rewording; line_prefix
    # false drops TemplateError's "line N: " wrapper (the bare
    # ansible-core wording for an undefined-variable failure carries no
    # line info, unlike a template syntax error which keeps it).
    private def ansible_wording(ex : KrikriJinja::TemplateError, line_prefix : Bool) : String
      base = line_prefix ? (ex.message || "template render failed") : (ex.raw_message || ex.message || "template render failed")
      Krikri.jinja_attribute_miss_wording(base)
    end

    # JSON-shaped counterpart of #prepare_template_vars, for the krikri-jinja
    # render path: Ansible templates a role default's own value
    # recursively, so a default that is itself an unrendered expression
    # resolves before the template sees it.
    #
    # The re-render MUST be JinjaRenderer.rerender_nested_templates, not a
    # local string-only walk: a nested leaf whose whole value is one `{{ }}`
    # expression that evaluates to a container (jtyr.motd's third
    # motd_info__default entry, Oefenweb.sudoers' `sudoers_sudoers:
    # {privileges: "{{ ... }}"}`) has to come out as a REAL dict/list, not
    # the substituted string form of one - substitute always returns a
    # String, so a walk that stops at substitution left sudoers_sudoers
    # .privileges as the text "[{...}]" and the template's `{% for item in
    # ... %}{{ item.name }}` iterated its CHARACTERS ("object of type 'str'
    # has no attribute 'name'" - rounds 975058/975059/975081, same root
    # cause as the engine-scope conversion's render_pure_mustache_value).
    # defer_unresolved keeps this path's existing laziness: a leaf that
    # references an undefined variable stays raw until a template that
    # actually reads it fails, like Ansible - with one upgrade for the
    # chain-undefined leaf shape, see #engine_scope_value and the
    # deferred_leaves collection below: the leaf loads into the engine
    # scope as the message-carrying strict Undefined real 2.19.11 would
    # have instead of silently-renderable raw text (rounds 5300003
    # wasilak.centos-hashiui / 5300004 SathiyarajPeriyannan.vsphere).
    private def prepare_template_vars_json(template_path : String) : Hash(String, JSON::Any)
      substitutor = VarSubstitutor.new(vars: @vars)
      # Strict-undefined COLLECTION for this render's walk (defer_unresolved
      # + a non-nil deferred_leaves tells JinjaRenderer to mark leaves that
      # bottom out at a name set nowhere instead of raising): the marked
      # leaves load into the engine scope as strict Undefineds via
      # #engine_scope_value, so only templates that actually read them
      # fail - template:, not an arg-finalization walk. This is real
      # ansible-core 2.19's lazily-templated scope for the variables of a
      # template: task (rounds 5300003/5300004).
      deferred_leaves = {} of String => String
      # Unsafe gate (VarSubstitutor.resolved_var_name?, the same per-host
      # registry every other re-render site consults): a name published by
      # build_vars_context as execution-resolved (register:/set_fact:/a
      # gathered fact) holds VERBATIM content, not a template level. The
      # re-render below re-scanned `r.stdout`'s hostile
      # `{{ lookup('pipe', ...) }}` text as template source and executed
      # the lookup on the CONTROLLER - a `template:` task (or a `{%
      # include %}`/`{% import %}` sub-template reached through one) gave
      # a hostile target code execution. The value-level text registry
      # (UnsafeValues.unsafe_text?, checked inside
      # JinjaRenderer.rerender_string_value itself) stops the same text
      # when it surfaces under an author-defined key or nested deeper.
      host_name = @vars["inventory_hostname"]?.try(&.as_s?) || @host.name
      vars = {} of String => JSON::Any
      @vars.each do |key, value|
        if key == "hostvars"
          # The hostvars magic is NOT one host's value: each entry must
          # re-render in ITS OWN host's scope (Ansible's HostVarsVars
          # templar). The generic re-render below would have rendered
          # every entry with THIS host's vars.
          vars[key] = VariableSubstitutor::JinjaRenderer.prepare_hostvars(value, substitutor, defer_unresolved: true, deferred_leaves: deferred_leaves)
          next
        end
        unless VarSubstitutor.resolved_var_name?(host_name, key)
          begin
            value = VariableSubstitutor::JinjaRenderer.rerender_nested_templates(value, substitutor, defer_unresolved: true, deferred_leaves: deferred_leaves)
          rescue Krikri::UndefinedVariableError
            # A role default that references an undefined variable stays raw;
            # only a template that actually uses it fails, like Ansible.
          end
        end
        vars[key] = value
      end

      vars["inventory_hostname"] = JSON::Any.new(@host.name)
      vars["ansible_host"] = JSON::Any.new(@host.name)
      vars["ansible_managed"] = JSON::Any.new("Ansible managed")
      vars["template_host"] = JSON::Any.new(@host.name)
      vars["template_path"] = JSON::Any.new(template_path)
      vars["template_fullpath"] = JSON::Any.new(File.expand_path(template_path))
      vars["template_run_date"] = JSON::Any.new(Time.utc.to_s("%Y-%m-%d %H:%M:%S UTC"))
      vars["environment"] = JSON::Any.new(ENV.to_h.transform_values { |value| JSON::Any.new(value) })
      vars["template_destpath"] = JSON::Any.new(@params["dest"]) if @params["dest"]?
      vars["vars"] = JSON::Any.new(vars.dup)
      vars
    end

    # Method-call `.join(` form that Jinja2 permits but Crinja's
    # parser rejects: `{{ "SEP".join(LIST) }}` is the standard `sep.join(list)`
    # idiom (dev-sec os_hardening's securetty template uses it). Rewritten
    # into the equivalent `LIST | join("SEP")` filter, which Crinja supports.
    # $1 = the sep string literal, $2 = the list expression being joined.
    # `[^"\\]` excludes `\n` too (not just cosmetic): a template
    # with an ODD number of `"` characters total has no valid second
    # quote to close a literal at all, so the unbounded `(?:[^"\\]|\\.)*`
    # tries every possible split of the REST OF THE FILE between its two
    # alternatives looking for one - mrlesmithjr.netdata's own 5934-line
    # netdata.conf.j2 has exactly one stray `"` in the whole file, and
    # this pattern alone was the one that actually overflowed PCRE2's
    # JIT match-time stack.
    # Real quoted string literals here are always single-line.
    JOIN_METHOD = /("(?:[^"\\\n]|\\.)*")\s*\.join\(\s*([^)\n]*?)\s*\)/

    # Method-call `.split(...)` - real Python's own str.split() method
    # (not a Jinja2 filter - Jinja2 exposes native object methods
    # directly), rejected by Crinja's parser the same way `.items()`
    # was. dev-sec apache_hardening's own httpd.conf.j2 uses it to pick
    # the minor version out of an already-parsed `apache_version`
    # string: `{% if apache_version.split('.')[1] == '4' %}`. Rewritten
    # to `VAR | split(ARGS)` (see jinja_filters.cr's own :split filter).
    # $1 = the dotted/bracketed variable expression being split
    # (`apache_version`, `_apache_version.stdout`, ...), $2 = the raw
    # argument text (possibly empty, for Python's own no-arg whitespace-
    # split form), $3 = an optional trailing literal numeric index
    # (`apache_version.split('.')[1]` - split()'s result is almost
    # always indexed immediately). Crinja can parse `(EXPR).1` (dot-
    # numeric indexing on a parenthesized expression) but NOT `(EXPR)[1]`
    # (bracket indexing on one) - confirmed by direct testing, not
    # assumed - so a captured trailing `[N]` is rewritten to `.N` rather
    # than carried through as-is; #rewrite_crinja_compat's own gsub
    # call is responsible for making that substitution (see below).
    #
    # Group 1 alternates `.ident`/`[...]` suffixes in any order - real
    # bug found benchmarking githubixx.ansible_role_wireguard's own
    # wg.conf.j2: the old pattern only allowed dot-segments *before* any
    # bracket-index suffix (`foo.bar[0]`), so `hostvars[host].
    # wireguard_address.split('/')[0]` (a bracket, THEN more dots) never
    # matched starting from "hostvars" at all - the regex engine instead
    # found a match starting mid-expression, from "wireguard_address"
    # alone, silently leaving the "hostvars[host]." prefix untouched and
    # producing the syntactically invalid "hostvars[host].(wireguard_
    # address | split('/', 0))" (a stray `.(` Crinja's own parser
    # rejects outright: "Expected IDENTIFIER, got LEFT_PAREN").
    SPLIT_METHOD = /([A-Za-z_]\w*(?:\.[A-Za-z_]\w*|\[[^\]]*\])*)\.split\(([^)]*)\)(?:\[(\d+)\])?/

    # A `{% if EXPR %}`/`{% elif EXPR %}` statement tag - $1/$4 are the
    # optional whitespace-control markers, either the trim `-` or the
    # keep `+` (both preserved as-is on rewrite - the `+` must survive
    # so the vendored Crinja fork's native `+` handling still sees it;
    # the `+` forms used to be pre-stripped out of the whole template,
    # see #render_template's comment for why that's gone), $2 the
    # keyword, $3 the condition - each is wrapped with `| pytruthy`
    # below (see the comment inside the gsub block) so a falsy-but-
    # non-empty condition behaves like real Jinja2. Deliberately does
    # NOT match `{% for %}` - `for x in list`
    # is valid Crinja syntax on its own and must never be touched.
    TAG_IF_ELIF = /\{%(-|\+?)\s*(if|elif)\s+(.*?)\s*(-|\+?)%\}/

    # `{% for (key, value) in dict.items() %}` - the idiomatic real-
    # Jinja2 way to iterate a dict's key/value pairs (mysql_hardening's
    # own hardening.cnf.j2 writes it exactly this way). Only the parens
    # around the loop variables need stripping - the vendored crinja
    # fork's `.items()` is a real method on Hash values (see
    # `lib/crinja/src/runtime/python_hash_methods.cr`), so `.items()`
    # itself is left alone and evaluated for real rather than textually
    # stripped. Was NOT always true: an earlier FOR_ITEMS_METHOD regex
    # used to strip `.items()` out entirely and rely on Crinja's bare
    # `{% for k, v in dict %}` already yielding (key, value) pairs - a
    # real deviation from Python/Jinja2 (where a bare dict for-loop
    # iterates keys only) that happened to produce the right pairs, but
    # silently broke `.items() | sort` (jtyr.nsswitch's own nsswitch.
    # conf.j2: `{% for key, val in nsswitch_config.items() | sort %}`)
    # by sorting the raw dict instead of its item tuples. Removed once
    # `.items()` support landed in the fork - verified live against
    # both jtyr.nsswitch (`.items() | sort`) and jtyr.motd (`.items()`
    # alone, item.motd.j2), byte-for-byte identical to Ansible.
    FOR_TUPLE_PARENS = /(\{%-?\s*for\s+)\(([^)]+)\)(\s+in\s+)/

    # Reads one of the six Jinja delimiter-string task params, falling
    # back to Jinja2's own default when the key is missing or empty.
    private def delimiter_param(name : String, default : String) : String
      raw = @params[name]?
      (raw.nil? || raw.empty?) ? default : raw
    end

    # Ansible's _find_needle search for a bare relative template src
    # on the controller: a standalone playbook task's `src: foo.j2` also
    # resolves against the PLAYBOOK's own directory and its templates/
    # subdir (which is how `template: src: bench-report.j2` finds
    # <playbook_dir>/templates/bench-report.j2 when the process CWD is
    # somewhere else entirely). Returns the resolved path, or nil when
    # every candidate is exhausted - the caller then fails the task with
    # Ansible's exact "Could not find or access" wording.
    # Ansible's path_dwim_relative_stack shape: an absolute (or ~)
    # src is checked as-is with NO candidate list, a relative one is
    # searched through the task's search stack (ansible_search_path,
    # minus the trailing basedir entry Ansible's job var appends - the dwim
    # lookup adds the basedir separately and unconditionally) plus the
    # playbook basedir. Returns {resolved path or nil, candidate list}.
    private def resolve_controller_src(src : String) : {String?, Array(String)}
      if src.starts_with?('/') || src.starts_with?("~")
        test_path = File.expand_path(src)
        return {File.exists?(test_path) ? test_path : nil, [] of String}
      end

      playbook_dir = @vars["playbook_dir"]?.try(&.as_s?)
      return {nil, [] of String} unless playbook_dir && !playbook_dir.empty?

      stack = raw_search_stack(playbook_dir)
      candidates = Krikri::NeedleLookup.candidates(stack, File.expand_path(playbook_dir), "templates", src)
      resolved = candidates.find { |candidate| File.exists?(candidate) }
      {resolved, candidates}
    end

    # The raw dwim search stack reconstructed from ansible_search_path
    # (which the executor builds in Ansible's job-var shape: search stack
    # plus the basedir appended when not already present). The dwim
    # lookup itself must NOT see that appended basedir - it adds its own
    # unconditionally - so a trailing entry equal to the playbook dir is
    # dropped, but only when the stack has more than one entry (a plain
    # playbook task's single entry IS the task dir, which the basedir
    # append skipped as already-present).
    private def raw_search_stack(playbook_dir : String) : Array(String)
      paths = @vars["ansible_search_path"]?.try(&.as_a?).try do |entries|
        entries.compact_map do |entry|
          entry.as_s?
        end
      end
      return [playbook_dir] unless paths && !paths.empty?
      return paths[0...paths.size - 1] if paths.size > 1 && paths.last == playbook_dir
      paths
    end

    # True when any of the six Jinja delimiter-string task params (Ansible's block_start_string/...) is set to a non-default value.
    # The text-level Jinja compat rewrites (#rewrite_crinja_compat's
    # JOIN_METHOD/SPLIT_METHOD/TAG_IF_ELIF/FOR_TUPLE_PARENS regexes) hard-code the
    # classic delimiter shapes; with custom delimiters those byte
    # sequences are literal template text, and rewriting them would
    # corrupt the output - so the whole rewrite pass is skipped for such
    # templates.
    private def custom_delimiters? : Bool
      {
        {"block_start_string", "{%"},
        {"block_end_string", "%}"},
        {"variable_start_string", "{{"},
        {"variable_end_string", "}}"},
        {"comment_start_string", "{#"},
        {"comment_end_string", "#}"},
      }.any? do |name, default|
        raw = @params[name]?
        !raw.nil? && !raw.empty? && raw != default
      end
    end

    # Parses a leading `#jinja2: key:value, key2:value2` directive line
    # (only recognized on the template's literal first line, matching
    # Ansible) into a {key => bool} overrides hash, and returns the
    # template content with that line removed. Only trim_blocks/
    # lstrip_blocks are understood (the only ones any Crinja config knob
    # here maps to); an unrecognized key is ignored rather than raising -
    # Ansible supports a couple of others (keep_trailing_newline,
    # variable_start_string, ...) this directive parser doesn't map
    # (the delimiter strings are honored as TASK params instead, see
    # #delimiter_param). No directive line at all returns an empty
    # overrides hash and the template unchanged.
    #
    # The VALUE goes through Ansible's own pipeline: ast.literal_eval on
    # the raw text, then TemplateOverrides' dataclass post-init type
    # validation - so a quoted string where a bool is required dies with
    # "Syntax error in template: TemplateOverrides.trim_blocks must be
    # <class 'bool'> instead of <class 'str'>" (the quoted-`"true"` header
    # apolloclark.packetbeat's packetbeat-6.6.yml carries, round 1500121:
    # this engine coerced it leniently and PASSED where ansible-playbook
    # failed the task). True/False pass; None/int/float/str/dict/list are
    # each reported with their own Python type name, exactly like the
    # dataclass validator's f-string. A value literal_eval cannot parse
    # at all (bare lowercase `true`, an identifier, ...) is real's
    # "malformed node or string" ValueError - whose message embeds a
    # per-process <ast.Name object at 0x...> address real itself can never
    # reproduce across runs (same unmatchable-nondeterminism class as
    # apt's retry-jitter output), so the address here is a stable
    # placeholder and only the wording/class is matched.
    private def extract_jinja2_directive(template : String) : {Hash(String, Bool), String}
      overrides = Hash(String, Bool).new
      lines = template.split('\n', 2)
      first_line = lines[0]? || ""

      return {overrides, template} unless first_line.strip.starts_with?("#jinja2:")

      first_line.strip[8..].split(',').each do |clause|
        key, sep, value = clause.strip.partition(':')
        next if sep.empty?
        key = key.strip
        next unless key == "trim_blocks" || key == "lstrip_blocks"
        overrides[key] = directive_bool!(key, value.strip)
      end

      {overrides, lines[1]? || ""}
    end

    # literal_eval + the dataclass type check for a bool-typed directive
    # field: returns the bool for True/False, raises Jinja2DirectiveError
    # (real's message verbatim) for a parsed-but-wrong-typed value or an
    # unparseable one.
    private def directive_bool!(key : String, raw : String) : Bool
      kind = python_literal_kind(raw)
      case kind
      when "bool"
        raw == "True"
      when nil
        raise Jinja2DirectiveError.new("Syntax error in template: malformed node or string on line 1: <ast.Name object at 0x000000000000>")
      else
        raise Jinja2DirectiveError.new("Syntax error in template: TemplateOverrides.#{key} must be <class 'bool'> instead of <class '#{kind}'>")
      end
    end

    # ast.literal_eval's accepted scalar shapes, by the Python TYPE NAME
    # the dataclass validator would report (dict/list/tuple included for
    # completeness - a container value fails the bool check the same way).
    private def python_literal_kind(raw : String) : String?
      case raw
      when "True", "False" then "bool"
      when "None"          then "NoneType"
      else
        if (raw.starts_with?('"') && raw.ends_with?('"') && raw.size >= 2) ||
           (raw.starts_with?('\'') && raw.ends_with?('\'') && raw.size >= 2)
          "str"
        elsif raw.starts_with?('{') && raw.ends_with?('}')
          "dict"
        elsif raw.starts_with?('[') && raw.ends_with?(']')
          "list"
        elsif raw.starts_with?('(') && raw.ends_with?(')')
          "tuple"
        elsif raw.matches?(/\A[+-]?\d+\z/)
          "int"
        elsif raw.matches?(/\A[+-]?(\d+\.\d*|\.\d+)([eE][+-]?\d+)?\z/) || raw.matches?(/\A[+-]?\d+[eE][+-]?\d+\z/)
          "float"
        end
      end
    end

    # Text-level Jinja compat rewrites left over from the Crinja era.
    # Inline ternaries (`{{ A if C else B }}`) are deliberately NOT
    # rewritten here: krikri-jinja parses and evaluates them natively,
    # and LAZILY - the old Crinja-era rewrite turned each one into
    # `C | ternary(A, B)`, a filter call whose arguments are evaluated
    # eagerly, so an untaken branch containing an invalid expression
    # (rolehippie.prometheus's default.j2: `' --storage.tsdb.retention.
    # size=' + prometheus_tsdb_retention_size if ... | default(false)
    # else ''`, with the var defaulting to null) failed the whole render
    # with "unsupported operands for +: String and Nil" where real
    # Jinja2 never even evaluates the untaken branch (round 5460382).
    private def rewrite_crinja_compat(template : String) : String
      # Bounded defense-in-depth against a non-converging rewrite pass -
      # every individual rewrite below is believed idempotent once
      # applied, but this loop already hung the whole process for real
      # (100% CPU, no return) from one whitespace-handling bug in the
      # since-removed ternary rewrite; a hard cap turns any *future*
      # such bug into a merely-imperfect render instead of a permanent
      # hang. Matches the same bounded-retemplating pattern
      # VarSubstitutor# substitute already uses for its own "re-render
      # until stable" loop.
      20.times do
        once = template
        # Rewrite `.join(` method calls to the join filter.
        once = once.gsub(JOIN_METHOD) do
          "#{$2} | join(#{$1})"
        end
        # Then rewrite `.split(...)` method calls to the split filter.
        once = once.gsub(SPLIT_METHOD) do
          if index = $3?
            sep_arg = $2.strip.empty? ? "''" : $2
            "(#{$1} | split(#{sep_arg}, #{index}))"
          else
            "(#{$1} | split(#{$2}))"
          end
        end
        # Then wrap every `{% if %}`/`{% elif %}` condition with
        # `| pytruthy` (see the comment inside the block below).
        once = once.gsub(TAG_IF_ELIF) do
          condition = $3
          # Already wrapped by an earlier pass through this same loop
          # (see the loop-convergence comment on #rewrite_crinja_compat)
          # - leave it exactly as-is instead of nesting another `|
          # pytruthy` around it every iteration, which would never
          # converge (`once` would keep differing from `template`
          # forever).
          if condition.ends_with?("| pytruthy")
            "{%#{$1} #{$2} #{condition} #{$4}%}"
          else
            # `| pytruthy` (see jinja_filters.cr) fixes real Python/
            # Jinja2 truthiness for the *whole* condition - Crinja's own
            # Value#truthy? treats an empty string as truthy (a real
            # gap: ssh_hardening/os_hardening both default several vars
            # to `""` specifically to mean "unset", e.g. `ssh_deny_
            # users: ""`, and gate a config line on `{% if ssh_deny_
            # users %}`). Applied unconditionally to every if/elif tag,
            # not just ones already touched by the `in` rewrite -
            # strictly more correct in every case, since real_truthy?
            # agrees with Crinja::Value#truthy? on everything except the
            # empty-collection cases it was already getting wrong.
            "{%#{$1} #{$2} (#{condition}) | pytruthy #{$4}%}"
          end
        end
        # `{% for (k, v) in dict.items() %}` -> `{% for k, v in dict.items() %}`
        # (see FOR_TUPLE_PARENS above - `.items()` itself is real
        # Crinja syntax now, left untouched).
        once = once.gsub(FOR_TUPLE_PARENS) { "#{$1}#{$2}#{$3}" }
        break if once == template
        template = once
      end
      template
    end

    # Prepare variables for template rendering
    #
    # A String value that itself contains "{{" is re-templated first -
    # see JinjaRenderer#prepare_crinja_vars for the full rationale
    # (Ansible re-templates every variable's value recursively
    # wherever it's used; Jinja2 itself does not, so a role default
    # like geerlingguy.nginx's own `nginx_worker_processes: '"{{
    # ansible_processor_vcpus | default(ansible_processor_count) }}"'`
    # would otherwise render as the literal, still-unparsed inner text).
    # This plugin has its own separate prepare_*_vars (see that
    # method's own comment for why its Crinja environment can't be
    # shared with JinjaRenderer's), so it needs the identical fix
    # applied here too, not just there.
    # Helper: Check if parameter is truthy
    private def true?(value : String?, default : Bool = false) : Bool
      return default unless value
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end
  end
end
