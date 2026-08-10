require "json"
require "digest/md5"
require "crinja"
require "./jinja_filters"
require "./base_action_plugin"
# For the shared JSON::Any -> Crinja::Value converter (this plugin keeps
# its own Crinja environment - see that method's comment for why).
require "./variable_substitutor/crinja_renderer"

module CrystalPlay
  # Template Action Plugin
  # Runs on CONTROLLER to read and render Jinja2 templates
  # Then sends rendered content to remote host
  
  class TemplateActionPlugin < ActionPlugin
    @render_error : String? = nil

    def execute : ActionResult
      # Get source template path
      src = @params["src"]?
      unless src
        return ActionResult.failure("Missing required parameter: src")
      end
      
      # Check if template file exists on CONTROLLER
      unless File.exists?(src)
        return ActionResult.failure("Template file not found on controller: #{src}")
      end
      
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
      
      # Modify params to send rendered CONTENT to remote instead of template path
      # The remote plugin will receive the rendered content, not the template
      modified_params = @params.dup
      modified_params.delete("src")  # Remove src parameter
      modified_params["content"] = rendered_content  # Add rendered content
      modified_params["_rendered_from_template"] = src  # Track for debugging
      modified_params["_content_checksum"] = content_md5  # For idempotency
      
      ActionResult.success(modified_params, changed: false)
    end
    
    # Render Jinja2 template with variables
    private def render_template(template_content : String, template_path : String) : String?
      begin
        # Jinja2's `{%+ ... %}`/`{% ... +%}` whitespace-control modifier
        # (explicitly keeping whitespace trim_blocks/lstrip_blocks would
        # otherwise strip around this one tag) - Crinja's parser doesn't
        # recognize `+` as a modifier at all here, and fails outright with
        # "no tag with name '+' registered", failing the whole template
        # render. konstruktoid-hardening's sshd_config.j2 uses this around
        # its `Match Address/Group/User` section headers. Since this
        # renderer already forces lstrip_blocks off unconditionally (see
        # below), the left-side `+` is always a no-op here already; the
        # right-side `+%}` losing its trim_blocks override (when
        # trim_blocks is on) is an imperfect but acceptable trade against
        # the alternative of failing the entire render.
        #
        # MUST run before #rewrite_inline_ternaries: TAG_IF_ELIF's own
        # regex only recognizes a bare `{%`/plain `-` prefix, not `{%+` -
        # so a `{%+ if X +%}` tag left unstripped skips the pytruthy
        # rewrite entirely and reaches Crinja's *native* `{% if %}`
        # evaluation instead, which has its own real bug (Crinja::Value#
        # truthy? treats an empty string as truthy - see real_truthy?'s
        # own comment in jinja_filters.cr). Found via this exact
        # template's `{%+ if sshd_sftp_only_group +%}` (default `""`):
        # rendered "Match Group " with the condition's own variable
        # empty and unset, instead of skipping the block entirely.
        template_content = template_content.gsub(/\{%\+/, "{%").gsub(/\+%\}/, "%}")

        # Crinja 0.9.0 cannot parse Jinja2's inline conditional expression
        # `{{ A if C else B }}`. Real Ansible supports it and real roles
        # (dev-sec os_hardening's login.defs and ufw templates) use it, so
        # rewrite the idiomatic form into the ternary filter we provide
        # (`{{ C | ternary(A, B) }}`) before Crinja sees it. Only the
        # literal `X if C else Y` shape is rewritten; `{% if %}` blocks are
        # left untouched.
        template_content = rewrite_inline_ternaries(template_content)

        # A `#jinja2: key:value, key2:value2` directive on the template's
        # very first line (real Ansible's own per-template override for
        # trim_blocks/lstrip_blocks/etc. - dev-sec ssh_hardening's
        # opensshd.conf.j2 opens with exactly this) is metadata for the
        # renderer, not template content - real Ansible strips it before
        # rendering. Previously left in place, it rendered as a literal
        # "#jinja2: ..." line in the *output* file - harmless in most
        # templates (just an extra comment) but fatal here, since this
        # particular output is `sshd_config`, whose `validate:` command
        # (`sshd -T -f %s`) rejects any line it doesn't recognize and
        # failed the whole task.
        directive_overrides, template_content = extract_jinja2_directive(template_content)

        # Create Crinja environment
        env = Crinja.new

        # Configure Crinja to match Ansible defaults. A directive value
        # (explicit true OR false) always wins over the param default -
        # `directive_overrides.fetch` (not `||`) so an explicit `false`
        # in the directive isn't treated as "unset, fall through".
        trim_blocks = directive_overrides.fetch("trim_blocks", is_true?(@params["trim_blocks"]?, default: true))

        env.config.trim_blocks = trim_blocks

        # Crinja's lstrip_blocks is broken: even a bare, unindented `{% if %}`
        # on its own line (no leading whitespace to strip) makes it eat the
        # *preceding* line's newline too, and an indented tag eats every
        # newline in the whole block ("A\n    {% if %}\nB\n    {% endif %}\nC\n"
        # renders as "ABC" instead of "A\nB\nC\n"). Real templates set
        # `lstrip_blocks: True` via the `#jinja2:` directive precisely to get
        # clean, newline-correct output (konstruktoid-hardening's
        # resolved.conf.j2 does), so honoring the broken implementation would
        # produce worse output than ignoring the request - always render with
        # it off regardless of what was requested.
        env.config.lstrip_blocks = false
        
        # Prepare template variables
        template_vars = prepare_template_vars
        
        # Add Ansible-specific variables
        template_vars["ansible_managed"] = Crinja::Value.new("Ansible managed")
        template_vars["template_host"] = Crinja::Value.new(@host.name)
        template_vars["template_path"] = Crinja::Value.new(template_path)
        template_vars["template_fullpath"] = Crinja::Value.new(File.expand_path(template_path))
        template_vars["template_run_date"] = Crinja::Value.new(Time.utc.to_s("%Y-%m-%d %H:%M:%S UTC"))
        
        # Render template
        template = env.from_string(template_content)
        rendered = template.render(template_vars)
        
        # Ensure rendered content ends with newline (matches Ansible behavior and file conventions)
        # This prevents idempotency issues with heredoc writes that add trailing newlines
        rendered += "\n" unless rendered.ends_with?("\n")
        
        return rendered
      rescue ex
        @render_error = ex.message
        return nil
      end
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
    INLINE_TERNARY = /
      \{\{                          # opening {{
      (                             # capture the whole expression
        (?:[^}]*?)                 # lazy: up to the ternary
        \s+if\s+                  # the ` if ` keyword
        (?:[^}]*?)                 # condition (lazy)
        (?:\s+else\s+              # the ` else ` keyword (optional)
        (?:[^}]*?))?                # else branch (lazy, optional)
      )
      \}\}                        # closing }}
    /x

    # Method-call `.join(` form that real Jinja2 permits but Crinja's
    # parser rejects: `{{ "SEP".join(LIST) }}` is the standard `sep.join(list)`
    # idiom (dev-sec os_hardening's securetty template uses it). Rewritten
    # into the equivalent `LIST | join("SEP")` filter, which Crinja supports.
    # $1 = the sep string literal, $2 = the list expression being joined.
    JOIN_METHOD = /("(?:[^"\\]|\\.)*")\s*\.join\(\s*([^)]*?)\s*\)/

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
    SPLIT_METHOD = /([A-Za-z_][\w.]*(?:\[[^\]]*\])*)\.split\(([^)]*)\)(?:\[(\d+)\])?/

    # A `{% if EXPR %}`/`{% elif EXPR %}` statement tag - $1/$4 are the
    # optional whitespace-trim `-` markers (preserved as-is on rewrite),
    # $2 the keyword, $3 the condition. Used to find the same real-Jinja2
    # infix `in`/`not in` operator Crinja can't parse (see
    # #rewrite_in_expr) when it's used directly in a statement condition
    # rather than nested inside an inline ternary's own condition
    # (already handled separately, since that one lives inside a `{{ }}`
    # block). Deliberately does NOT match `{% for %}` - `for x in list`
    # is valid Crinja syntax on its own and must never be touched.
    TAG_IF_ELIF = /\{%(-?)\s*(if|elif)\s+(.*?)\s*(-?)%\}/

    # `{% for (key, value) in dict.items() %}` - the idiomatic real-
    # Jinja2 way to iterate a dict's key/value pairs (mysql_hardening's
    # own hardening.cnf.j2 writes it exactly this way) - two things
    # Crinja can't parse: parens around the loop variables, and dicts
    # having no `.items()` method at all. Neither needs real rewriting
    # logic, since Crinja's own bare `{% for k, v in dict %}` (no
    # parens, no `.items()`) already yields (key, value) pairs directly
    # - a real deviation from Python/Jinja2 (where a bare dict for-loop
    # iterates keys only, not pairs), but exactly the behavior needed
    # here, so both problem pieces are simply stripped rather than
    # implemented from scratch.
    FOR_TUPLE_PARENS = /(\{%-?\s*for\s+)\(([^)]+)\)(\s+in\s+)/
    FOR_ITEMS_METHOD  = /(\{%-?\s*for\s+.+?\s+in\s+[A-Za-z_][\w.]*)\.items\(\)/

    # Parses a leading `#jinja2: key:value, key2:value2` directive line
    # (only recognized on the template's literal first line, matching
    # real Ansible) into a {key => bool} overrides hash, and returns the
    # template content with that line removed. Only trim_blocks/
    # lstrip_blocks are understood (the only ones any Crinja config knob
    # here maps to); an unrecognized key is ignored rather than raising -
    # real Ansible supports a couple of others (keep_trailing_newline,
    # variable_start_string, ...) this codebase has no Crinja equivalent
    # for. No directive line at all returns an empty overrides hash and
    # the template unchanged.
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

    private def rewrite_inline_ternaries(template : String) : String
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
            "{%#{$1} #{$2} (#{rewrite_in_expr(condition)}) | pytruthy #{$4}%}"
          end
        end
        # `{% for (k, v) in dict.items() %}` -> `{% for k, v in dict %}`
        # (see FOR_TUPLE_PARENS/FOR_ITEMS_METHOD above).
        once = once.gsub(FOR_TUPLE_PARENS) { "#{$1}#{$2}#{$3}" }
        once = once.gsub(FOR_ITEMS_METHOD) { $1 }
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
      return expr unless container.starts_with?('[') || container.starts_with?('(')

      # A trailing top-level ` and `/` or ` after the container means this
      # is a compound condition, not a clean single `in` test - leave it
      # alone rather than mis-rewrite half of it.
      return expr if index_of_token(container, " and ") >= 0 || index_of_token(container, " or ") >= 0

      if container.starts_with?('(')
        inner = strip_wrapping_parens(container)
        return expr if inner == container # not a single clean (...) wrap
        list_literal = "[#{inner}]"
      else
        list_literal = container
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
    # see CrinjaRenderer#prepare_crinja_vars for the full rationale
    # (real Ansible re-templates every variable's value recursively
    # wherever it's used; real Jinja2 itself does not, so a role default
    # like geerlingguy.nginx's own `nginx_worker_processes: '"{{
    # ansible_processor_vcpus | default(ansible_processor_count) }}"'`
    # would otherwise render as the literal, still-unparsed inner text).
    # This plugin has its own separate prepare_*_vars (see that
    # method's own comment for why its Crinja environment can't be
    # shared with CrinjaRenderer's), so it needs the identical fix
    # applied here too, not just there.
    private def prepare_template_vars : Hash(String, Crinja::Value)
      vars = Hash(String, Crinja::Value).new
      substitutor = VarSubstitutor.new(vars: @vars)

      # Add all vars
      @vars.each do |key, value|
        value = JSON::Any.new(substitutor.substitute(value.as_s)) if value.raw.is_a?(String) && value.as_s.includes?("{{")
        vars[key] = VariableSubstitutor::CrinjaRenderer.json_any_to_crinja_value(value)
      end
      
      # Add host information
      vars["inventory_hostname"] = Crinja::Value.new(@host.name)
      vars["ansible_hostname"] = Crinja::Value.new(@host.name)
      vars["ansible_host"] = Crinja::Value.new(@host.name)
      
      vars
    end
    
    
    # Helper: Check if parameter is truthy
    private def is_true?(value : String?, default : Bool = false) : Bool
      return default unless value
      ["true", "yes", "1", "on"].includes?(value.downcase)
    end
  end
end
