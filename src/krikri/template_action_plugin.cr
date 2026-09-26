require "json"
require "digest/md5"
require "krikri-jinja/krikri_jinja"
require "./krikri_jinja_filters"
require "./jinja_host_context"
require "./template_search_path_loader"
require "./base_action_plugin"

module Krikri
  # Template Action Plugin
  # Runs on CONTROLLER to read and render Jinja2 templates
  # Then sends rendered content to remote host

  class TemplateActionPlugin < ActionPlugin
    @render_error : String? = nil

    def execute : ActionResult
      # newline_sequence: template-only param (real Ansible strips it from
      # the module args - it is consumed HERE, on the controller, by the
      # Jinja environment). Default "\n"; the three documented values are
      # accepted, including their YAML-escaped literal forms ("\\n" typed
      # with a backslash, which YAML/CLI quoting can hand over as a
      # literal two-character string - real Ansible's own
      # wrong_sequences normalization), anything else fails the task with
      # real Ansible's exact message before any template is touched
      # (live-verified against ansible-core 2.19.4).
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
        return ActionResult.failure("newline_sequence needs to be one of: \\n, \\r or \\r\\n")
      end

      # Get source template path
      src = @params["src"]?
      unless src
        return ActionResult.failure("Missing required parameter: src")
      end

      # Check if template file exists on CONTROLLER - real Ansible's own
      # _find_needle/copy action wording for a missing source (the
      # newline is literal: real's msg is the two-line
      # "Could not find or access '<path>' on the Ansible Controller.\n"
      # "If you are using a module and expect the file to exist on the
      # remote, see the remote_src option").
      resolved_src = resolve_controller_src(src)
      unless resolved_src
        return ActionResult.failure("Could not find or access '#{src}' on the Ansible Controller.\nIf you are using a module and expect the file to exist on the remote, see the remote_src option")
      end
      src = resolved_src

      # Read template content
      begin
        template_content = File.read(src)
      rescue ex
        return ActionResult.failure("Failed to read template file: #{ex.message}")
      end

      # Render template on CONTROLLER
      rendered_content = render_template(template_content, src)
      unless rendered_content
        detail = @render_error ? ": #{@render_error}" : ""
        return ActionResult.failure("Failed to render template#{detail}")
      end

      # Calculate MD5 of rendered content
      content_md5 = Digest::MD5.hexdigest(rendered_content)

      # newline_sequence: real Ansible passes this to the Jinja2
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

      # Modify params to send rendered CONTENT to remote instead of template path
      # The remote plugin will receive the rendered content, not the template
      modified_params = @params.dup
      modified_params.delete("src")                      # Remove src parameter
      modified_params["content"] = rendered_content      # Add rendered content
      modified_params["_rendered_from_template"] = src   # Track for debugging
      modified_params["_content_checksum"] = content_md5 # For idempotency

      ActionResult.success?(modified_params, changed: false)
    end

    # Render a Jinja2 template with krikri-jinja. A role-local
    # `filter_plugins/*.py` filter is resolved on demand and registered on
    # this render's own engine, then the render is retried once.
    private def render_template(template_content : String, template_path : String) : String?
      directive_overrides, content = extract_jinja2_directive(template_content)
      content = rewrite_inline_ternaries(content, false) unless custom_delimiters?

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

      template_vars = prepare_template_vars_json(template_path)
      engine = KrikriJinja.derive_engine(
        build_template_loader(template_path), options,
        KrikriJinja.ansible_strict_undefined, JinjaHostContext.new(template_vars)
      )
      begin
        render_once(engine, content, template_vars)
      rescue ex : KrikriJinja::TemplateError
        # A role-local `filter_plugins/*.py` filter is resolved on demand
        # and registered on this render's own engine, then the render is
        # retried once with that same engine.
        filter_name = KrikriJinjaFilters.unknown_filter_name(ex)
        if filter_name && KrikriJinjaFilters.ensure_python_filter(filter_name, template_vars, engine)
          render_once(engine, content, template_vars)
        else
          raise ex
        end
      end
    rescue ex : KrikriJinja::TemplateError
      @render_error = jinja_error_message(ex)
      nil
    rescue ex
      @render_error = ex.message
      nil
    end

    # Renders through the engine once and applies Ansible's own
    # trailing-newline convention to the result.
    private def render_once(engine : KrikriJinja::Engine, content : String,
                            template_vars : Hash(String, JSON::Any)) : String
      rendered = engine.render_string(
        content,
        template_vars.transform_values { |value| KrikriJinja.from_json_any(value) }
      )
      rendered += "\n" unless rendered.ends_with?("\n")
      rendered
    end

    # Loader rooted at the template's own directory plus its role's
    # templates/ ancestors, matching real Ansible's role template search
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

    # Real Ansible's own wording for a strict-undefined failure is
    # "'name' is undefined"; krikri-jinja already uses that phrasing. An
    # attribute miss is reworded from Jinja's "'dict object' has no
    # attribute 'x'" to ansible-core's "object of type 'dict' has no
    # attribute 'x'".
    private def jinja_error_message(ex : KrikriJinja::TemplateError) : String
      (ex.message || "template render failed")
        .gsub(/'(\w+) object' has no attribute/, "object of type '\\1' has no attribute")
    end

    # JSON-shaped counterpart of #prepare_template_vars, for the krikri-jinja
    # render path: real Ansible templates a role default's own value
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
    # actually reads it fails, like real Ansible.
    private def prepare_template_vars_json(template_path : String) : Hash(String, JSON::Any)
      substitutor = VarSubstitutor.new(vars: @vars)
      vars = {} of String => JSON::Any
      @vars.each do |key, value|
        begin
          value = VariableSubstitutor::JinjaRenderer.rerender_nested_templates(value, substitutor, defer_unresolved: true)
        rescue Krikri::UndefinedVariableError
          # A role default that references an undefined variable stays raw;
          # only a template that actually uses it fails, like real Ansible.
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

    # Rewrites Jinja2 inline conditional expressions `{{ A if C else B }}`
    # into the Crinja-parseable `{{ C | ternary(A, B) }}` form. This is
    # real Jinja2 (used by dev-sec os_hardening), which Crinja 0.9.0 cannot
    # parse. Only `{{ }}` expression blocks are touched; `{% %}` statement
    # blocks are left as-is.
    #
    # Regex-based (not manual char indexing): matches a `{{ ... }}` block
    # and rewrites an inline ` A  if  C  else  B ` ternary within it. Each
    # match keeps the ` if ` / ` else ` as the top-level separator, so an
    # operand that is itself a parenthesized ternary (`(B if C2 else D)`)
    # is handled naturally by the nested `( ... )` captures.
    # The ` else ... ` branch is optional - real Jinja2 permits `{{ A if C
    # }}` on its own (renders as empty/Undefined when C is false;
    # konstruktoid-hardening's sshd_config.j2 does this throughout, e.g.
    # `{{ 'Ciphers ' ~ sshd_ciphers | join(',') if sshd_ciphers }}` to
    # omit the whole config line entirely when the list is empty).
    # #rewrite_ternary_expr treats a missing else branch as `''`.
    # `[^}\n]` (not just `[^}]`) in every lazy segment below is load-
    # bearing, not cosmetic: a real inline ternary is always written on
    # one line, but `[^}]*?` alone also matches newlines, so on a large
    # template with sparse/mismatched `{`/`}` (mrlesmithjr.netdata's own
    # 5934-line netdata.conf.j2 - only 26 `{{` and 37 bare `}` total in
    # the whole file, zero of them an actual ternary) each of the 26
    # `{{` candidates would lazily scan for the next literal `}`
    # ACROSS THE REST OF THE FILE, and the nested optional `else` group
    # multiplies that against every already-scanned position - PCRE2's
    # JIT match-time stack (a separate resource from its compile-time
    # stack, and unrelated to true catastrophic backtracking) overflows
    # ("Regex match error: JIT stack limit reached"), crashing the
    # `template:` task outright on a file that never needed rewriting at
    # all. Excluding `\n` bounds every candidate scan to a single line,
    # matching how these templates are actually written and eliminating
    # the cross-file scan entirely.
    INLINE_TERNARY = /
      \{\{                          # opening {{
      (                             # capture the whole expression
        (?:[^}\n]*?)               # lazy: up to the ternary
        \s+if\s+                  # the ` if ` keyword
        (?:[^}\n]*?)               # condition (lazy)
        (?:\s+else\s+              # the ` else ` keyword (optional)
        (?:[^}\n]*?))?              # else branch (lazy, optional)
      )
      \}\}                        # closing }}
    /x

    # Method-call `.join(` form that real Jinja2 permits but Crinja's
    # parser rejects: `{{ "SEP".join(LIST) }}` is the standard `sep.join(list)`
    # idiom (dev-sec os_hardening's securetty template uses it). Rewritten
    # into the equivalent `LIST | join("SEP")` filter, which Crinja supports.
    # $1 = the sep string literal, $2 = the list expression being joined.
    # `[^"\\]` excludes `\n` too (not just cosmetic - see INLINE_TERNARY's
    # own comment above for the general shape of this bug): a template
    # with an ODD number of `"` characters total has no valid second
    # quote to close a literal at all, so the unbounded `(?:[^"\\]|\\.)*`
    # tries every possible split of the REST OF THE FILE between its two
    # alternatives looking for one - mrlesmithjr.netdata's own 5934-line
    # netdata.conf.j2 has exactly one stray `"` in the whole file, and
    # this pattern alone (not INLINE_TERNARY, initially suspected first)
    # was the one that actually overflowed PCRE2's JIT match-time stack.
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
    # than carried through as-is; #rewrite_inline_ternaries's own gsub
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
    # keyword, $3 the condition. Used to find the same real-Jinja2
    # infix `in`/`not in` operator Crinja can't parse (see
    # #rewrite_in_expr) when it's used directly in a statement condition
    # rather than nested inside an inline ternary's own condition
    # (already handled separately, since that one lives inside a `{{ }}`
    # block). Deliberately does NOT match `{% for %}` - `for x in list`
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
    # alone, item.motd.j2), byte-for-byte identical to real Ansible.
    FOR_TUPLE_PARENS = /(\{%-?\s*for\s+)\(([^)]+)\)(\s+in\s+)/

    # Reads one of the six Jinja delimiter-string task params, falling
    # back to Jinja2's own default when the key is missing or empty.
    private def delimiter_param(name : String, default : String) : String
      raw = @params[name]?
      (raw.nil? || raw.empty?) ? default : raw
    end

    # Real Ansible's _find_needle search for a bare relative template src
    # on the controller: a standalone playbook task's `src: foo.j2` also
    # resolves against the PLAYBOOK's own directory and its templates/
    # subdir (which is how `template: src: bench-report.j2` finds
    # <playbook_dir>/templates/bench-report.j2 when the process CWD is
    # somewhere else entirely). Returns the resolved path, or nil when
    # every candidate is exhausted - the caller then fails the task with
    # real Ansible's exact "Could not find or access" wording.
    private def resolve_controller_src(src : String) : String?
      return src if File.exists?(src)
      return nil if src.starts_with?('/')

      playbook_dir = @vars["playbook_dir"]?.try(&.as_s?)
      return nil unless playbook_dir && !playbook_dir.empty?

      candidates = [
        File.join(playbook_dir, src),
        File.join(playbook_dir, "templates", src),
      ]
      candidates.find { |candidate| File.exists?(candidate) }
    end

    # True when any of the six Jinja delimiter-string task params (real
    # Ansible's block_start_string/...) is set to a non-default value.
    # The text-level Jinja compat rewrites (#rewrite_inline_ternaries'
    # INLINE_TERNARY/TAG_IF_ELIF/FOR_TUPLE_PARENS regexes) hard-code the
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
    # real Ansible) into a {key => bool} overrides hash, and returns the
    # template content with that line removed. Only trim_blocks/
    # lstrip_blocks are understood (the only ones any Crinja config knob
    # here maps to); an unrecognized key is ignored rather than raising -
    # real Ansible supports a couple of others (keep_trailing_newline,
    # variable_start_string, ...) this directive parser doesn't map
    # (the delimiter strings are honored as TASK params instead, see
    # #delimiter_param). No directive line at all returns an empty
    # overrides hash and the template unchanged.
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
        overrides[key] = value.strip.downcase == "true"
      end

      {overrides, lines[1]? || ""}
    end

    # `rewrite_in:` is false on the krikri-jinja path: that engine evaluates
    # a real infix `in`/`not in` natively, including Python's "undefined on
    # the left of a list membership is simply False", so rewriting it into
    # the `is in([...])` test form would only lose that.
    private def rewrite_inline_ternaries(template : String, rewrite_in : Bool = true) : String
      # Bounded defense-in-depth against a non-converging rewrite pass -
      # every individual rewrite below is believed idempotent once
      # applied, but this loop already hung the whole process for real
      # (100% CPU, no return) from one whitespace-handling bug in
      # #rewrite_ternary_expr; a hard cap turns any *future* such bug
      # into a merely-imperfect render instead of a permanent hang.
      # Matches the same bounded-retemplating pattern VarSubstitutor#
      # substitute already uses for its own "re-render until stable"
      # loop.
      20.times do
        once = template
        # Rewrite inline ternaries first. INLINE_TERNARY's match includes
        # the surrounding `{{`/`}}` (needed so the regex only fires
        # inside an expression block, not inside plain text that happens
        # to contain " if "/" else "), and String#gsub replaces the
        # *whole* match with the block's return value - so the rewrite
        # must re-add `{{ }}` around the rewritten expression itself.
        # Previously didn't, silently turning every inline ternary in
        # every template into unparsed literal text in the rendered
        # output (`value=true | ternary('a', 'b')` instead of `value=a`) -
        # never caught by task-status-only real-host diffing, since the
        # template task still reports `changed:`/"Template rendered
        # successfully" either way; only inspecting the rendered file's
        # actual content surfaces it.
        once = once.gsub(INLINE_TERNARY) do
          "{{ #{rewrite_ternary_expr($1)} }}"
        end
        # Then rewrite `.join(` method calls to the join filter.
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
        # Then rewrite a real-Jinja2 infix `in`/`not in` test used
        # directly in a `{% if %}`/`{% elif %}` condition (the ternary
        # case above already handles it when nested inside a `{{ }}`
        # ternary's own condition).
        once = once.gsub(TAG_IF_ELIF) do
          condition = $3
          # Already wrapped by an earlier pass through this same loop
          # (see the loop-convergence comment on #rewrite_inline_ternaries)
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
            condition = rewrite_in_expr(condition) if rewrite_in
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

    # Rewrites a single expression's `A if C else B` into `C | ternary(A, B)`.
    # Requires the literal ` if ` and ` else ` tokens present in *expr*.
    #
    # *then_part*/*else_part* are recursively rewritten too - ssh_hardening's
    # own AllowTcpForwarding line nests a ternary inside another's else
    # branch (`A if C1 else (B if C2 else D)`), which the outer gsub loop
    # (see #rewrite_inline_ternaries) cannot fix up on a later pass: once
    # the outer ternary is rewritten to `C1 | ternary(A, (B if C2 else
    # D))`, the inner "B if C2 else D" text is no longer inside its own
    # `{{ }}` block (it is now embedded in an already-rewritten filter
    # call), so INLINE_TERNARY's regex either never matches it again or -
    # worse - matches the *whole* already-rewritten `{{ }}` block a
    # second time and mangles it further. Recursing here, before the
    # outer rewrite is assembled, fixes both branches in one pass so
    # nothing nested is left for a second pass to mishandle.
    # Real Jinja2 (and every real playbook/template) writes list/tuple
    # membership as the bare infix operator `X in [...]`/`X not in [...]`
    # - standard Python/Jinja2 syntax. Crinja has no infix `in` operator
    # at all, only a `is in(seq)` TEST (`Crinja.test({seq: ...}, :in)`),
    # so any real-world use of the infix form fails the whole render
    # (dev-sec ssh_hardening's AllowTcpForwarding line: `ssh_allow_tcp_
    # forwarding in ('yes', 'no', 'local', 'all', 'remote')`).
    #
    # Rewrites a single self-contained `LEFT (not )?in CONTAINER`
    # expression into `LEFT is (not )?in(CONTAINER_AS_LIST)` - a `(...)`
    # tuple-literal container is converted to a `[...]` list literal
    # (Crinja's `:in` test reads its `seq` argument from a real Jinja
    # list, not a tuple, which Crinja doesn't have as its own literal
    # type at all). Returns *expr* unchanged if it isn't a clean, single
    # top-level `in`/`not in` expression (e.g. a compound `X in Y and Z`
    # condition) - not needed by any template in this codebase today,
    # and safer to leave alone than to guess at operator precedence.
    private def rewrite_in_expr(expr : String) : String
      stripped = strip_wrapping_parens(expr.strip)

      negated = false
      in_idx = index_of_token(stripped, " not in ")
      if in_idx >= 0
        negated = true
        token_len = 8
      else
        in_idx = index_of_token(stripped, " in ")
        return expr if in_idx < 0
        token_len = 4
      end

      left = stripped[0...in_idx].strip
      container = stripped[(in_idx + token_len)..].strip
      return expr if left.empty? || container.empty?

      # A trailing top-level ` and `/` or ` after the container means this
      # is a compound condition, not a clean single `in` test - leave it
      # alone rather than mis-rewrite half of it.
      return expr if index_of_token(container, " and ") >= 0 || index_of_token(container, " or ") >= 0

      list_literal = if container.starts_with?('[')
                       container
                     elsif container.starts_with?('(')
                       inner = strip_wrapping_parens(container)
                       return expr if inner == container # not a single clean (...) wrap
                       "[#{inner}]"
                     elsif container =~ /\A[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*|\[[^\]]+\])*\z/
                       # A bare variable/dotted/indexed reference
                       # (`ansible_facts.processor`, not a `[...]`
                       # literal or `(...)` tuple) - real Ansible roles
                       # check membership against a variable-bound list
                       # far more often than an inline literal one.
                       # Crinja's own `is in(seq)` test takes `seq:
                       # Array(Crinja::Value)`, evaluated as a normal
                       # expression - a bare variable reference needs no
                       # bracket-wrapping at all, unlike the tuple-
                       # literal case above. Found via dev-sec.os-
                       # hardening's own `('amd' in ansible_facts.
                       # processor) | pytruthy` - previously fell
                       # through to `return expr` unrewritten (neither
                       # `[`- nor `(`-prefixed), leaving Crinja's own
                       # unsupported infix `in` operator untouched and
                       # failing the whole template render outright.
                       container
                     else
                       return expr
                     end
      "#{left} is #{negated ? "not " : ""}in(#{list_literal})"
    end

    private def rewrite_ternary_expr(expr : String) : String
      # #strip - INLINE_TERNARY's capture includes the raw whitespace
      # padding around the `{{`/`}}` delimiters (e.g. captures " EXPR "
      # from "{{ EXPR }}"). Without stripping it here, a call that falls
      # through to the plain `return expr` below (nothing to rewrite)
      # hands back that same padding, which the caller then re-wraps as
      # "{{ #{expr} }}" - adding *another* space on each side on top of
      # what's already there. Every later pass through the outer
      # rewrite_inline_ternaries loop re-captures and re-pads the same
      # way, growing the string by two characters forever and never
      # reaching the loop's `once == template` convergence check - a
      # genuine unbounded infinite loop (confirmed: 100% CPU, no I/O,
      # never returns), not just a cosmetic double-space.
      expr = expr.strip

      # A whole ternary can itself be wrapped in a redundant outer paren
      # pair (ssh_hardening's own ForwardAgent line: `((ssh_forward_agent)
      # if ssh_forward_agent is defined else 'no')`) - without stripping
      # it first, that outer `(` never closes until the very end, so
      # every character of the real ` if `/` else ` tokens sits at paren
      # depth 1, not 0, and #index_of_token (a depth-0-only scan) never
      # finds them at all - the whole ternary is left completely
      # unrewritten and handed to Crinja as literal (unsupported) inline-
      # if syntax.
      expr = strip_wrapping_parens(expr)

      # Split on the top-level ` if ` and ` else ` (guarding quotes/parens
      # via a small scan). Uses a manual scan rather than the regex above
      # because a ternary may be nested and we want the *last* ` else `.
      if_idx = index_of_token(expr, " if ")
      return expr unless if_idx >= 0
      else_idx = index_of_token_from(expr, " else ", if_idx)

      then_part = rewrite_ternary_expr(strip_wrapping_parens(expr[0...if_idx].strip))
      # A missing ` else ` branch (`{{ A if C }}`, real Jinja2's own
      # else-less inline conditional) renders as empty/Undefined when C
      # is false - `''` reproduces that in the ternary filter form.
      if else_idx >= 0
        cond_part = rewrite_in_expr(expr[if_idx + 4...else_idx].strip)
        else_part = rewrite_ternary_expr(strip_wrapping_parens(expr[else_idx + 6..].strip))
      else
        cond_part = rewrite_in_expr(expr[if_idx + 4..].strip)
        else_part = "''"
      end

      # cond_part is parenthesized unconditionally before the pipe: real
      # Jinja2's `|` binds *tighter* than `is`, so an unparenthesized `X
      # is in([...]) | ternary(...)` parses as `X is in([...] |
      # ternary(...))` - the filter call ends up as part of the test's
      # own argument instead of applying to the test's boolean result.
      # Only actually matters when cond_part itself contains `is` (from
      # #rewrite_in_expr), but wrapping is harmless otherwise too.
      "(#{cond_part}) | ternary(#{then_part}, #{else_part})"
    end

    # Strips one layer of wrapping parens from *s* - but only when the
    # opening `(` and closing `)` actually match each other (paren depth
    # returns to 0 only at the very last character), not when *s* merely
    # starts with `(` and ends with `)` for unrelated reasons (e.g.
    # `(a) + (b)`). A nested ternary branch written `(B if C2 else D)`
    # needs this stripped before recursing into #rewrite_ternary_expr,
    # or the whole branch stays at paren depth 1 throughout and its own
    # ` if `/` else ` tokens are never found (both are depth-0-only
    # scans).
    private def strip_wrapping_parens(s : String) : String
      return s unless s.starts_with?('(') && s.ends_with?(')')
      depth = 0
      s.each_char.with_index do |char, i|
        depth += 1 if char == '('
        depth -= 1 if char == ')'
        return s if depth == 0 && i < s.size - 1
      end
      s[1..-2]
    end

    # Index of the first occurrence of *token* (outside quotes and at
    # paren depth 0), or -1. The token must be preceded/followed by a
    # non-identifier char so `elif`/`elseif` style keywords can't match.
    private def index_of_token(str : String, token : String) : Int32
      index_of_token_from(str, token, 0)
    end

    private def index_of_token_from(str : String, token : String, from : Int32) : Int32
      depth = 0
      in_single = false
      in_double = false
      j = from
      while j <= str.size - token.size
        c = str[j]
        if in_single
          in_single = false if c == '\''
        elsif in_double
          in_double = false if c == '"'
        else
          case c
          when '\'' then in_single = true
          when '"'  then in_double = true
          when '('  then depth += 1
          when ')'  then depth -= 1
          else
            if depth == 0 && str[j, token.size] == token
              return j
            end
          end
        end
        j += 1
      end
      -1
    end

    # Prepare variables for template rendering
    #
    # A String value that itself contains "{{" is re-templated first -
    # see JinjaRenderer#prepare_crinja_vars for the full rationale
    # (real Ansible re-templates every variable's value recursively
    # wherever it's used; real Jinja2 itself does not, so a role default
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
