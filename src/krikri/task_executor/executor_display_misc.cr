require "./executor"

module Krikri
  class TaskExecutor
    private def report_unreachable(task : Task, host : Host, ssh_error : String? = nil, no_log : Bool = false) : Nil
      connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name
      # Ansible embeds the transport's own error text in the msg
      # ("Failed to connect to the host via ssh: ssh: connect to host
      # ...: No route to host"); the known-unreachable paths have no
      # fresh error to show and fall back to the connection host, which
      # is what this always printed before.
      #
      # no_log redaction applies on the unreachable path too (Ansible honors no_log there): the SSH transport error can echo
      # task context (a command line, a URL with embedded credentials)
      # the task asked to keep out of the output.
      detail = ssh_error.try(&.strip.lines.first?) || connection_host
      msg = %("Failed to connect to the host via ssh: #{detail}")
      msg = "" if no_log
      puts %(fatal: [#{host.name}]: UNREACHABLE! => {"changed": false, "msg": #{msg.to_json}, "unreachable": true}).colorize(:red)

      stats = @results[host.name]
      if task.ignore_unreachable?
        # Counted as ok AND ignored, matching Ansible's own recap
        # for an ignored unreachable task.
        stats["ok"] += 1
        stats["ignored"] += 1
      else
        stats["unreachable"] += 1
        @halted_hosts << host.name
      end
    end

    def show_recap : Nil
      ResultDisplay.show_recap(@hosts, @results)
    end

    # Ansible templates a task's `name:` leniently through
    # ReplacingMarkerBehavior (the Ansible module _post_validate_name):
    # every undefined span becomes a numbered
    # `<< error N - 'x' is undefined >>` placeholder IN the displayed
    # name, and every name-templating CONTEXT exits by emitting
    # `[WARNING]: Encountered N template error(s).` block(s) on stderr -
    # one block per consecutive run of same-origin errors - with the
    # ORIGIN OF THE FAILING VALUE'S DEFINING SITE: the task's own file
    # for a direct `{{ undefined }}` in the name, but the file/line where
    # a nested variable's value was DEFINED (role vars/main.yml, play
    # vars, the inventory line, ...) once the render recurses into it.
    # Live-verified against ansible-core 2.19.11: the warning fires even
    # when the task is when:-skipped, the error counter is shared across
    # contexts within one task's name (and restarts per task), a nested
    # MULTI-part value's context completes (and numbers its errors)
    # before the enclosing context's own errors, and identical warning
    # text dedups to one display per run.
    @@name_warning_seen = Set(String).new

    # Per-name-render error state: the shared counter (numbers are
    # assigned when a context completes, not when its error occurs -
    # a nested context's errors number first) and the placeholder prefix
    # markers embed while their number is still unknown.
    private class NameTemplateErrorState
      property counter = 0
      getter placeholder_prefix : String

      def initialize
        # Random per render: a resolved variable's VALUE could otherwise
        # collide with a fixed sentinel and corrupt the final marker text.
        @placeholder_prefix = "\uE000#{Random::Secure.hex(8)}\uE000"
      end

      def take(count : Int32) : Array(Int32)
        numbers = ((counter + 1)..(counter + count)).to_a
        @counter += count
        numbers
      end
    end

    # One name-templating context: the template text being rendered (the
    # name itself, or a nested variable's multi-part value) plus the
    # origin its errors are reported against (overridable per error -
    # a nested SINGLE-expression value's failure joins the enclosing
    # context but carries the nested value's own origin, live-verified:
    # `dx: "{{ undef_d }} {{ ex }}"`, `ex: "{{ undef_e }}"` numbers
    # undef_d 1 and undef_e 2 with each error's OWN defining file).
    private class NameTemplateContext
      property origin : VarOrigin? = nil
      getter errors = [] of {String, VarOrigin?}

      def push(msg : String, origin : VarOrigin?) : Int32
        @errors << {msg, origin}
        @errors.size - 1
      end
    end

    private def render_task_name_for_display(task : Task, host : Host) : String
      return task.name unless task.name.includes?("{{")
      return lenient_task_name(task, host) if task.name.includes?("{%") || task.name.includes?("{#")

      vars_context = build_vars_context(task, host)
      substitutor = VarSubstitutor.new(vars: vars_context, host_name: host.name)

      state = NameTemplateErrorState.new
      top = NameTemplateContext.new
      top.origin = name_value_origin(task)
      rendered = marker_render_chunks(task.name, substitutor, vars_context, task, host, top, state, 0, nil)
      complete_name_context(top, state, rendered)
    rescue
      task.name
    end

    # Ansible's name templating applies its ReplacingMarkerBehavior at
    # EVERY recursion level, not just the name's own top-level spans: a
    # span whose variable's own stored value is unrendered Jinja gets
    # that value rendered chunk-wise too, each failing sub-expression
    # annotated individually while resolvable literals and sibling
    # expressions survive (andrewrothstein.nats, round 2300765). The
    # error counter is shared across levels, matching Ansible's per-name
    # numbering.
    private MAX_NAME_MARKER_DEPTH = 8

    private def marker_render_chunks(text : String, substitutor : VarSubstitutor, vars_context : Hash(String, JSON::Any), task : Task, host : Host, ctx : NameTemplateContext, state : NameTemplateErrorState, depth : Int32, error_origin : VarOrigin?) : String
      pieces = [] of String
      pos = 0
      aborted = false
      while !aborted && (start = text.index("{{", pos))
        stop = text.index("}}", start) || break
        pieces << text[pos...start]
        span = text[start..stop + 1]
        if (m = span.match(/\A\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}\z/))
          pieces << render_bare_name_span(m[1], span, substitutor, vars_context, task, host, ctx, state, depth, error_origin)
        else
          span_text, aborted = render_complex_name_span(span, substitutor, vars_context, task, host, ctx, state, depth, error_origin)
          pieces << span_text
        end
        pos = stop + 2
      end
      # An aborting span ends the template run mid-render (live-verified
      # vs 2.19.11, p20 probe): the trailing text is never rendered and
      # later spans are never even evaluated.
      pieces << text[pos..] unless aborted
      pieces.join
    end

    # A bare `{{ name }}` span. Its failure never aborts the enclosing
    # template run - the span is replaced by its error marker(s) and
    # rendering continues (live-verified: `{{ a }}{{ b }}` yields two
    # markers, no truncation).
    private def render_bare_name_span(name : String, span : String, substitutor : VarSubstitutor, vars_context : Hash(String, JSON::Any), task : Task, host : Host, ctx : NameTemplateContext, state : NameTemplateErrorState, depth : Int32, error_origin : VarOrigin?) : String
      begin
        return substitutor.substitute(span, strict: true)
      rescue e : UndefinedVariableError
        raw_template = depth < MAX_NAME_MARKER_DEPTH ? bare_var_raw_template(span, vars_context) : nil
        if raw_template
          origin = var_origin_for(task, host, name)
          if single_span_template?(raw_template)
            inner = raw_template.strip[2..-3].strip
            if inner.match(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
              # A value that IS exactly one bare-variable reference keeps
              # the propagation semantics: its failure joins THIS context
              # carrying the nested value's own origin, and a chain of
              # them keeps re-pointing the override at the immediately
              # failing definition (live-verified: p2/p8 shapes).
              return marker_render_chunks(raw_template, substitutor, vars_context, task, host, ctx, state, depth + 1, origin || error_origin)
            end
            # A value that is one COMPLEX expression fails as its own
            # self-truncating run (live-verified p16: error 1 is the
            # expression's own error and error 2 "template potentially
            # truncated", both at the value's defining site) and the
            # marker text it leaves behind is consumed LENIENTLY by the
            # enclosing template - p17: the outer name's literals
            # survive and the outer run adds no truncation of its own.
            child = NameTemplateContext.new
            child.origin = origin
            child_out = marker_render_chunks(raw_template, substitutor, vars_context, task, host, child, state, depth + 1, nil)
            return complete_name_context(child, state, child_out)
          end
          # A multi-part value (`"{{ a }} {{ b }}"`) renders chunk-wise
          # with each failing span annotated individually; the enclosing
          # template continues with the marker text inline (p7/p21).
          child = NameTemplateContext.new
          child.origin = origin
          child_out = marker_render_chunks(raw_template, substitutor, vars_context, task, host, child, state, depth + 1, nil)
          return complete_name_context(child, state, child_out)
        end
        idx = ctx.push(e.message.to_s, error_origin || ctx.origin)
        return "#{state.placeholder_prefix}#{idx}\uE001"
      rescue
        # A non-undefined span failure (bad filter, syntax) is not a
        # Marker in real either - keep the old lenient render for it.
        return (substitutor.substitute(span) rescue span)
      end
    end

    # Any non-bare span. Real evaluates it as an expression that can
    # ABORT the whole template run: the errors the span produced are
    # followed by one final "template potentially truncated" error
    # (live-verified p1/p4/p9/p10/p11/p14/p15/p18/p20), the span's own
    # partial output is discarded (p18: earlier pre-rendered markers of
    # the same span vanish from the name, their warning block does not),
    # prior spans' output survives (p14) and later spans are never
    # evaluated (p10/p11). A failure of a referenced variable's OWN
    # single-bare-reference value propagates the same way (c03-class:
    # the value's error carries the value's defining origin), while a
    # multi-part or complex-expression value renders leniently with
    # inline markers and does NOT abort (p6/p17).
    private def render_complex_name_span(span : String, substitutor : VarSubstitutor, vars_context : Hash(String, JSON::Any), task : Task, host : Host, ctx : NameTemplateContext, state : NameTemplateErrorState, depth : Int32, error_origin : VarOrigin?) : {String, Bool}
      err_start = ctx.errors.size
      span_vars = vars_context
      active_substitutor = substitutor
      abort = false

      # Quoted segments are literals, not references - strip them before
      # scanning so `{{ 'badvar' ~ x }}` does not pre-render badvar.
      scan_text = span.gsub(/'[^']*'/, " ").gsub(/"[^"]*"/, " ")
      scan_text.scan(/[A-Za-z_][A-Za-z0-9_]*/).map(&.[0]).uniq!.each do |ident|
        raw = span_vars[ident]?.try(&.as_s?) || next
        next unless raw.includes?("{{") && !raw.includes?("{%") && !raw.includes?("{#")
        origin = var_origin_for(task, host, ident)
        if single_span_template?(raw)
          inner = raw.strip[2..-3].strip
          if inner.match(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
            out = marker_render_chunks(raw, active_substitutor, span_vars, task, host, ctx, state, depth + 1, origin || error_origin)
            if out.includes?(state.placeholder_prefix)
              abort = true
              break
            end
            next
          end
        end
        child = NameTemplateContext.new
        child.origin = origin
        child_out = marker_render_chunks(raw, active_substitutor, span_vars, task, host, child, state, depth + 1, nil)
        finalized = complete_name_context(child, state, child_out)
        span_vars = span_vars.dup
        span_vars[ident] = JSON::Any.new(finalized)
        active_substitutor = VarSubstitutor.new(vars: span_vars, host_name: host.name)
      end

      unless abort
        begin
          return {active_substitutor.substitute(span, strict: true), false}
        rescue e : RenderExpressionError
          # Real's task-NAME marker shows the BARE message ("error 1 -
          # 'z' is not in list", probed 2026-10-10) - no "Error rendering
          # template:" prefix for this class.
          ctx.push(e.message.to_s, error_origin || ctx.origin)
        rescue e : UndefinedVariableError
          ctx.push(e.message.to_s, error_origin || ctx.origin)
        rescue e
          ctx.push("Error rendering template: #{e.message}", error_origin || ctx.origin)
        end
        abort = true
      end
      # Real truncates the name only when the failing span is a MULTI-PART
      # expression (a concat/arithmetic operator outside quoted literals -
      # c03/c21/E probes: `{{ 'pre-' ~ badvar }}` aborts the whole name and
      # later spans are never evaluated). A single-operand span failing on
      # an attribute/subscript/undefined reference is an INLINE marker and
      # the name render CONTINUES - later spans still evaluate (real 2.19.11
      # probes A/B/D/F/G/H/L/M/N 2026-10-10: `{{ d.json }}` -> error 1 only;
      # `{{ d.json }} {{ undef2 }}` -> both spans' markers, no truncation).
      multipart = span.gsub(/'[^']*'|"[^"]*"/, " ").matches?(/[~+\-*\/%]/)
      if multipart
        ctx.push("template potentially truncated", ctx.origin)
      else
        abort = false
      end
      markers = (err_start...ctx.errors.size).map do |i|
        "#{state.placeholder_prefix}#{i}\uE001"
      end.join
      {markers, multipart}
    end

    # A value consisting of exactly one `{{ ... }}` construct (no
    # surrounding literal text) - Ansible's single-expression template
    # shape, which evaluates inline instead of opening a nested context.
    private def single_span_template?(value : String) : Bool
      stripped = value.strip
      return false unless stripped.starts_with?("{{") && stripped.ends_with?("}}")
      stripped.scan(/\{\{/).size == 1 && stripped.scan(/\}\}/).size == 1
    end

    # The raw stored value of a failed span's bare variable reference,
    # when that value is itself plain `{{ }}` template text (no block
    # tags - those route through the full renderer, not chunk-wise) -
    # nil otherwise, so the caller falls back to the collapsed marker.
    private def bare_var_raw_template(span : String, vars_context : Hash(String, JSON::Any)) : String?
      return nil unless (m = span.match(/\A\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}\z/))
      raw = vars_context[m[1]]?
      return nil unless raw && (value = raw.as_s?) && value.includes?("{{")
      return nil if value.includes?("{%") || value.includes?("{#")
      value
    end

    # The old lenient whole-name substitution - still used for names
    # carrying `{%`/`{#` block tags, where Ansible's marker behavior is not
    # reproduced here.
    private def lenient_task_name(task : Task, host : Host) : String
      vars_context = build_vars_context(task, host)
      VarSubstitutor.new(vars: vars_context, host_name: host.name).substitute(task.name)
    rescue
      task.name
    end

    # A context's exit: number its collected errors from the shared
    # counter, turn the placeholder markers it embedded into final
    # `<< error N - ... >>` text, emit its warning blocks (one per
    # consecutive run of same-origin errors), and return the finalized
    # string for splicing.
    private def complete_name_context(ctx : NameTemplateContext, state : NameTemplateErrorState, rendered : String) : String
      return rendered if ctx.errors.empty?

      numbers = state.take(ctx.errors.size)
      finalized = rendered.gsub(/#{Regex.escape(state.placeholder_prefix)}(\d+)#{Regex.escape("\uE001")}/) do |match|
        idx = $1.to_i
        msg = ctx.errors[idx]?.try(&.[0]) || match
        "<< error #{numbers[idx]? || idx + 1} - #{msg} >>"
      end

      # Group consecutive same-origin errors into one block (verified:
      # two errors from one defining file share a block; an intervening
      # error from another file splits it).
      group_start = 0
      while group_start < ctx.errors.size
        group_origin = ctx.errors[group_start][1]
        group_end = group_start
        while group_end + 1 < ctx.errors.size &&
              ctx.errors[group_end + 1][1].try(&.group_key) == group_origin.try(&.group_key)
          group_end += 1
        end

        block = String.build do |io|
          count = group_end - group_start + 1
          io << "[WARNING]: Encountered #{count} template error#{count == 1 ? "" : "s"}.\n"
          (group_start..group_end).each do |i|
            io << "error #{numbers[i]} - #{ctx.errors[i][0]}\n"
          end
          if origin = group_origin
            io << var_origin_block(origin)
          end
          io << "\n"
        end
        STDERR.puts block if @@name_warning_seen.add?(block)

        group_start = group_end + 1
      end

      finalized
    end

    # The `Origin: ...` + excerpt section of a warning block, in real's
    # three shapes (see VarOrigin).
    private def var_origin_block(origin : VarOrigin) : String
      case origin
      when FileVarOrigin
        return line_origin_block(origin.path, origin.line) if origin.column <= 0
        return "Origin: #{File.expand_path(origin.path)}:#{origin.line}:#{origin.column}\n\n" unless File.file?(origin.path)
        lines = File.read_lines(origin.path)
        origin_context_block(origin.path, lines, origin.line, origin.column)
      when TextVarOrigin
        "Origin: #{origin.label}\n\n#{origin.text}\n"
      else
        ""
      end
    end

    # Inventory-shaped origin: `Origin: <file>:<line>` with the usual
    # 2-context-line excerpt but a full-line caret RUN instead of a
    # positioned caret (live-verified 2.19.11).
    private def line_origin_block(path : String, line_num : Int) : String
      lines = File.file?(path) ? File.read_lines(path) : [] of String
      String.build do |io|
        io << "Origin: " << File.expand_path(path) << ":" << line_num << "\n"
        io << "\n"

        label_width = line_num.to_s.size
        start_idx = Math.max(0, (line_num - 1) - 2)
        (start_idx..(line_num - 1)).each do |idx|
          line = lines[idx]?.to_s.chomp.gsub('\t', ' ')
          io << (idx + 1).to_s.rjust(label_width) << (line.empty? ? "" : " ") << line << "\n"
        end
        content = lines[line_num - 1]?.to_s.chomp.gsub('\t', ' ')
        io << " " * (label_width + 1) << "^" * content.size << "\n"
      end
    end

    # The name value's own origin: the task's own source file (role tasks
    # files and include_tasks: targets included - real points there, NOT
    # at the playbook), located by scanning for the task's `- name:` line
    # (same approach as task_arg_error_context), with the origin column
    # at the name VALUE's first character - real points at the value
    # token itself (quote included), not the `name:` key.
    private def name_value_origin(task : Task) : VarOrigin?
      path = task.source_file || @playbook_file
      return nil unless path && File.file?(path)

      lines = File.read_lines(path)
      located = locate_name_line(lines, task)
      return nil unless located
      name_idx, _key_col = located

      column = 1
      if (name_key = lines[name_idx].index("name:"))
        rest = lines[name_idx][(name_key + 5)..]
        column = name_key + 5 + (rest.size - rest.lstrip.size) + 1
      end
      FileVarOrigin.new(File.expand_path(path), name_idx + 1, column)
    end

    # The "myrole : " prefix Ansible puts on a role-sourced task's
    # own TASK banner (verified live against ansible-core 2.19.12:
    # `TASK [myrole : Install packages]`, and a NAMELESS role task gets
    # it too, e.g. `TASK [myrole : debug]` - matching the already-fixed
    # action-derived fallback name from KNOWN_MISSING.md's "Generic
    # TASK [Task 1] label" entry). Display-only: task.name itself stays
    # bare (this helper is deliberately NOT folded into
    # #render_task_name_for_display, which HandlerRunner also uses as
    # its own name_resolver for notify: MATCHING bookkeeping, not just
    # display - prefixing that shared function would make a plain
    # `notify: my handler` stop matching a role handler's now-prefixed
    # rendered_name; see handler_runner.cr's own separate, matching-
    # safe prefix-at-print-time fix for the HANDLER banner).
    #
    # `include_role:`/`import_role:` tasks are the one documented
    # exception - Ansible never prefixes the include/import task
    # itself with its OWN enclosing role's name (only what it expands
    # INTO inherits the new role's prefix): verified live, a NAMED
    # `include_role:` task inside "myrole" showed just its own name,
    # no "myrole :" prefix at all.
    private def execute_async(task : Task, exec_host : Host, config_json : String, vars : Hash(String, JSON::Any), substitutor : VarSubstitutor? = nil, substituted_become_user : String? = nil) : JSON::Any
      is_local = exec_host.vars["ansible_connection"]?.try(&.as_s?) == "local" || exec_host.name == "localhost" || exec_host.name == "127.0.0.1"
      unless is_local
        return execute_remote_async(task, exec_host, config_json, vars, substitutor, substituted_become_user)
      end

      jid = AsyncJobs.generate_jid
      AsyncJobs.write_status(jid, JSON.parse({
        "started"        => 1,
        "finished"       => 0,
        "ansible_job_id" => jid,
      }.to_json))
      # The config carries full module params (potentially secrets) - the
      # job files live under a predictable shared path, so 0600 from the
      # moment of creation (a create-then-chmod leaves the params sitting
      # on disk world-readable in the window between; same pattern as
      # AsyncJobs.write_status, which likewise writes the status file
      # 0600 itself).
      AsyncJobs.write_config(jid, config_json)

      executable = Process.executable_path || File.join(Dir.current, "krikri-playbook")
      Process.new(
        executable,
        ["__async_run", task.module_name, AsyncJobs.config_path(jid), AsyncJobs.status_path(jid)],
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )

      poll = task.poll_seconds || 10
      if poll <= 0
        # ansible-core 2.19.11's fire-and-forget registered shape
        # (live-verified by dumping the registered var keys AND values):
        # failed, started, finished, ansible_job_id, results_file,
        # changed - booleans (failed: false, started: true,
        # finished: false, changed: true), NO "msg" (Ansible's own
        # async_wrapper end() dict carries none; the old "Job started:
        # <jid>" msg key is not something Ansible's LOCAL shape produces).
        # Ansible's registered result also carries ansible_facts + warnings
        # from interpreter discovery on that first module contact - no
        # krikri equivalent, a known set gap.
        return JSON.parse({
          "failed"         => false,
          "started"        => true,
          "finished"       => false,
          "ansible_job_id" => jid,
          "results_file"   => AsyncJobs.status_path(jid),
          "changed"        => true,
        }.to_json)
      end

      deadline = Time.instant + (task.async_seconds || raise "BUG: async_seconds missing").seconds
      loop do
        sleep poll.seconds
        if status = AsyncJobs.read_status(jid)
          if AsyncJobs.finished?(status)
            return async_status_wrapped_result(jid, status)
          end
        end
        break if Time.instant >= deadline
      end

      JSON.parse({
        "changed"        => false,
        "failed"         => true,
        "msg"            => "async task did not complete within #{task.async_seconds} seconds",
        "ansible_job_id" => jid,
      }.to_json)
    end

    # Ansible's poll>0 final registered shape (live-verified via
    # `{{ r.keys() | list | to_json }}` on a registered poll: 5 command
    # job): the async_status ACTION plugin's base dict - started,
    # finished, stdout, stderr, stdout_lines, stderr_lines,
    # ansible_job_id, results_file (the Ansible module
    # initializes it, then coerces started/finished to booleans) - merged
    # with the job file's module result the way its merge_hash does:
    # duplicate keys keep their base position with the file's value, the
    # module's own keys append in file order (for a command job: changed,
    # rc, cmd, start, end, delta, msg, failed).
    private def async_status_wrapped_result(jid : String, status : JSON::Any) : JSON::Any
      merged = JSON.parse({
        "started"        => true,
        "finished"       => true,
        "stdout"         => "",
        "stderr"         => "",
        "stdout_lines"   => [] of String,
        "stderr_lines"   => [] of String,
        "ansible_job_id" => jid,
        "results_file"   => AsyncJobs.status_path(jid),
      }.to_json).as_h
      status.as_h.each do |key, value|
        merged[key] = value
      end
      JSON::Any.new(merged)
    end

    # The remote-connection half of async: - see execute_async's own
    # comment. Detached launch (poll: 0 returns immediately, real
    # fire-and-forget semantics: the `shutdown -r now` idiom kills the
    # SSH session the moment it starts, which is the point) plus an
    # optional poll loop reading the job's status file back over SSH.
    private def execute_remote_async(task : Task, exec_host : Host, config_json : String, vars : Hash(String, JSON::Any), substitutor : VarSubstitutor?, substituted_become_user : String?) : JSON::Any
      # Same become resolution + validation the non-async remote path
      # applies at its own call site.
      become = false
      become_user = nil
      if substitutor && resolve_task_become(task, substitutor)
        become = true
        candidate = substituted_become_user
        become_user = (candidate.nil? || candidate.empty?) ? "root" : candidate
        unless PluginManager.valid_become_user?(become_user)
          return JSON.parse({
            "changed" => false,
            "failed"  => true,
            "msg"     => "become_user #{become_user.inspect} is not a valid username",
          }.to_json)
        end
      end

      # Same transport-failure conversion execute_remote_plugin applies:
      # a host that dropped off the network before its async: task gets
      # an UNREACHABLE result, not a process-killing upload exception.
      begin
        PluginManager.ensure_uploaded(exec_host, task.module_name, vars)
      rescue ex
        raise ex unless SSHManager.connection_level_exception?(ex)
        detail = ex.message.to_s.lines.first?.to_s
        return JSON.parse({
          "changed"     => false,
          "msg"         => "Failed to connect to the host via ssh: #{detail}",
          "stderr"      => detail,
          "unreachable" => true,
        }.to_json)
      end
      become_pw = Passwords.become(vars, exec_host)
      target = PluginManager.remote_plugin_target(task.module_name, become, become_user, exec_host.user || "root", become_pw)
      # With a become password the target is the probe+sudo -S wrapper,
      # which is full of single quotes - it cannot live inside the
      # `sh -c '<...>'` argv string below (the quotes would terminate
      # it, and argv is exactly where a password must never appear
      # anyway). That shape writes the inner command to its own base64'd
      # file instead; without a password the launch bytes stay exactly
      # as they always were.
      pw_wrapped = !become_pw.nil? && PluginManager.become_needed?(become, become_user, exec_host.user || "root")
      connection_host = PluginManager.get_connection_host(exec_host, vars)
      user = exec_host.user || "root"
      identity_file = vars["ansible_ssh_private_key_file"]?.try(&.as_s?)

      jid = AsyncJobs.generate_jid
      dir = "~/.ansible_async"
      encoded = Base64.strict_encode(config_json)
      # base64 alphabet can't break shell quoting; the tmp+mv makes the
      # status file's appearance atomic for the poll loop below (a
      # partial stdout write would otherwise parse as garbage mid-read).
      #
      # The initial status stub is written SYNCHRONOUSLY in the launch
      # script, before the worker detaches - Ansible's own
      # async_wrapper does the same (the job file exists with
      # started: 1/finished: 0 the moment the module returns, so an
      # async_status: poll can never race it). Without the stub, the
      # poll's first read raced the SSH channel teardown: the nohup'd
      # worker could be killed by the session closing before it ever
      # exec'd, leaving NO status file at all and every poll answering
      # "could not find job" (found live via modules_systems.yml's async
      # probe - flaky, older runs won the race). The stub also means a
      # worker killed mid-flight shows as started-but-not-finished
      # instead of not-found, which is what Ansible reports too.
      launch = if pw_wrapped
                 inner = "#{target} < #{dir}/#{jid}.cfg > #{dir}/#{jid}.tmp 2>&1; mv #{dir}/#{jid}.tmp #{dir}/#{jid}"
                 inner_encoded = Base64.strict_encode(inner)
                 <<-SCRIPT
                   mkdir -p #{dir}
                   echo '{"started": 1, "finished": 0, "ansible_job_id": "#{jid}"}' > #{dir}/#{jid}
                   echo '#{encoded}' | base64 -d > #{dir}/#{jid}.cfg
                   echo '#{inner_encoded}' | base64 -d > #{dir}/#{jid}.run
                   nohup sh #{dir}/#{jid}.run >/dev/null 2>&1 &
                 SCRIPT
               else
                 <<-SCRIPT
                   mkdir -p #{dir}
                   echo '{"started": 1, "finished": 0, "ansible_job_id": "#{jid}"}' > #{dir}/#{jid}
                   echo '#{encoded}' | base64 -d > #{dir}/#{jid}.cfg
                   nohup sh -c '#{target} < #{dir}/#{jid}.cfg > #{dir}/#{jid}.tmp 2>&1; mv #{dir}/#{jid}.tmp #{dir}/#{jid}' >/dev/null 2>&1 &
                 SCRIPT
               end

      launched = SSHManager.exec_script(connection_host, user, launch, exec_host.port, identity_file: identity_file)
      if launched[:exit_code] != 0
        return JSON.parse({
          "changed" => false,
          "failed"  => true,
          "msg"     => "remote async launch failed: #{launched[:stderr].strip}",
        }.to_json)
      end

      poll = task.poll_seconds || 10
      if poll <= 0
        return JSON.parse({
          "changed"        => true,
          "failed"         => 0,
          "started"        => 1,
          "finished"       => 0,
          "ansible_job_id" => jid,
          "msg"            => "Job started: #{jid}",
        }.to_json)
      end

      deadline = Time.instant + (task.async_seconds || raise "BUG: async_seconds missing").seconds
      loop do
        sleep poll.seconds
        check = SSHManager.exec_script(connection_host, user, "cat #{dir}/#{jid} 2>/dev/null", exec_host.port, identity_file: identity_file)
        if (output = check[:stdout].strip).size > 0
          if status = (JSON.parse(output) rescue nil)
            # The file can still hold the synchronous launch stub
            # (started: 1, finished: 0) - when the worker dies with the
            # session or simply outlives a poll tick, that stub is NOT
            # the job's result. Returning it here reported a
            # still-running (or dead) job as an ok: task (found via
            # Aplyca.AnsibleTower's async setup.sh round: Ansible polled
            # the job to its rc=1 failure while krikri answered with the
            # stub). Only a finished status is final; keep polling to
            # the deadline, then the same async-timeout failure
            # ansible-core reports.
            return status if AsyncJobs.finished?(status)
          end
        end
        break if Time.instant >= deadline
      end

      JSON.parse({
        "changed"        => false,
        "failed"         => true,
        "msg"            => "async task did not complete within #{task.async_seconds} seconds",
        "ansible_job_id" => jid,
      }.to_json)
    end

    # ansible.builtin.reboot - entirely unimplemented before (silently
    # dropped at parse time, "Plugin not available"). Architecturally
    # can't be a normal plugin binary the way every other module here
    # works: those get uploaded to and run ON the target host, but a
    # reboot module's own process would die the instant the machine it's
    # running on actually reboots, before it could ever report back.
    # Ansible's own reboot module is a controller-side ACTION
    # plugin for exactly this reason - it issues the reboot command,
    # then polls the CONNECTION (not the remote process) until the host
    # goes away and comes back. Handled entirely here instead: issues
    # reboot_command over one SSH call (tolerating the connection dying
    # mid-command, which is the expected/successful outcome), waits
    # post_reboot_delay, then polls a trivial remote command (test_command
    # if given, else a bare `whoami`) until it succeeds or reboot_timeout
    # is exceeded. Found via robertdebock.common's own "Reboot" handler
    # (notified by "Set hostname"/"Fill /etc/hosts", `common_reboot:
    # true` by default) and robertdebock.update's own reboot-on-upgrade
    # handler - both very common real-world idioms, not narrow ones.
    #
    # local connection is intentionally left alone (returns changed:
    # false, failed: true) - rebooting the controller process's own
    # machine out from under itself has no safe/sane implementation here
    # and Ansible's own module warns heavily against it too.
    # group_by: - like reboot:, has no uploaded plugin binary at all
    # (listed in AVAILABLE_PLUGINS purely so the task isn't dropped at
    # parse time as "Plugin not available"). Ansible implements it
    # as an action plugin that mutates the live inventory rather than
    # running anything on the target - mirrored here by mutating the
    # shared Inventory instance krikri-playbook.cr passes to every play's
    # TaskExecutor (the SAME object across the whole per-play loop, not
    # a copy - a later play's `hosts:` pattern lookup sees whatever
    # group membership an earlier play's group_by: task added). `key:`
    # may itself be comma-separated (a rarely-used Ansible feature:
    # one task adding the host to several groups at once); `parents:` is
    # accepted and recorded via HostGroup#add_child for completeness,
    # though this codebase's own Inventory#get_hosts never actually
    # walks group hierarchy (only exact group-name matches), so it's
    # inert beyond documentation today - same limitation static
    # inventory group parent/child nesting already has here.
    private def execute_set_stats(params : Hash(String, String), host : Host, vars_context : Hash(String, JSON::Any)) : JSON::Any
      data_json = params["data"]?
      # A None data (`data:` with no value - the parser wires literal
      # nulls as NONE_SENTINEL, same as a whole-span null template) is
      # Ansible's missing-required-argument shape, same as the empty string.
      data_json = "" if data_json == Krikri::NONE_SENTINEL
      if data_json.nil? || data_json.empty?
        return JSON.parse({"changed" => false, "failed" => true, "msg" => "missing required argument: data"}.to_json)
      end

      data = JSON.parse(data_json) rescue nil
      unless data && data.as_h?
        return JSON.parse({"changed" => false, "failed" => true, "msg" => "data must be a dictionary of stat name -> value"}.to_json)
      end

      aggregate = !["false", "no", "0", "off"].includes?(params["aggregate"]?.try(&.downcase))
      per_host = ["true", "yes", "1", "on"].includes?(params["per_host"]?.try(&.downcase))

      data.as_h.each do |key, value|
        CustomStats.set(key, value, aggregate, host.name, per_host)
      end

      JSON.parse({"changed" => false, "failed" => false, "msg" => ""}.to_json)
    end

    private def debug_if_requested(task : Task, host : Host, result : JSON::Any) : JSON::Any
      setting = task.debugger || @debugger
      return result unless TaskDebugger.triggered?(setting, result)

      current = result
      # `task_vars[...] = v` typed at the prompt lands here once
      # `u`/`update_task` promotes it, and is merged into the context
      # every subsequent redo builds - Ansible's own semantics,
      # where a task_vars edit changes nothing until `u` re-templates
      # the task (verified against ansible-core 2.19.4: assign + `r`
      # alone re-runs the ORIGINAL command).
      var_overrides = Hash(String, JSON::Any).new
      loop do
        debug_vars = build_vars_context(task, host)
        var_overrides.each { |key, value| debug_vars[key] = value }

        case TaskDebugger.run(render_task_name_for_display(task, host), host.name, current,
          debug_vars, task, var_overrides)
        in TaskDebugger::Outcome::Continue
          return current
        in TaskDebugger::Outcome::Redo
          # `r` re-runs the task and re-evaluates the trigger against the
          # new result, so a still-failing task prompts again - which is
          # the point of being able to fix something and retry.
          rerun_vars = build_vars_context(task, host)
          var_overrides.each { |key, value| rerun_vars[key] = value }
          rerun = execute_task_once(task, host, rerun_vars)
          current = rerun if rerun
          return current unless TaskDebugger.triggered?(setting, current)
        end
      end
    end

    # Raised when a loop_control.label fails to template: ansible-core
    # fails the ITEM with "Failed to template loop_control.label: <err>"
    # (round 5250000, veselahouba.openvpn's label `{{ openvpn_client.name
    # }}` over a dict item) - the old silent fallback rendered the label
    # as the "undefined" sentinel text and let the task sail through as
    # ok/skipped where real fails it.
    class LoopLabelError < Exception
    end

    private def item_label_for(task : Task, item : JSON::Any, vars_context : Hash(String, JSON::Any), host : Host) : String
      if label = task.loop_label
        # Strict, like real's templar: a missing attribute on the item
        # ("object of type 'dict' has no attribute 'name'") or an
        # undefined reference fails the label (and through the callers,
        # the item) instead of silently rendering the sentinel text.
        begin
          rendered = VarSubstitutor.new(vars: vars_context, host_name: host.name).substitute(label, strict: true)
        rescue ex : UndefinedVariableError | VariableSubstitutor::TemplateSyntaxError
          raise LoopLabelError.new("Failed to template loop_control.label: #{ex.message}")
        end
        return rendered if rendered
      end
      item_display(item)
    end

    private def item_display(item : JSON::Any) : String
      # Ansible's loop-item label is Python's repr of the item, not
      # JSON: booleans render True/False, dicts/lists use single-quoted
      # `{'k': 'v'}`/`['a']`, None for null. A bare string is shown without
      # quotes. `.to_json` gave lowercase true/false and double quotes, so
      # `(item=...)` diverged from real for any non-string item.
      item.raw.is_a?(String) ? item.as_s : ResultDisplay.python_repr(item)
    end

    # Whether *host*'s `meta: end_role` already ended the role *task*
    # belongs to. Identity: the role invocation - a dynamic include_role
    # run stamps its freshly-loaded tasks with a per-invocation token
    # (Task#role_invocation_id), so two invocations of the same role are
    # independent; a statically loaded role (roles:/import_role:) keys on
    # its filesystem root (task.role_path), which is unique per play
    # there. Tasks outside any role are never affected.
    private def role_ended_for_host?(task : Task, host : Host) : Bool
      key = task.role_invocation_id || task.role_path
      return false unless key
      ended = @role_ended_hosts[key]?
      ended ? ended.includes?(host.name) : false
    end

    # Run a task repeatedly (up to task.retries times, sleeping task.delay
    # seconds between attempts) until task.until_condition evaluates true
    # against the registered result, matching Ansible's until:/retries:/delay:.
    # Skipped entirely in check mode: most modules refuse to act in check
    # mode anyway, which would otherwise turn every retry loop into a slow,
    # guaranteed-to-fail wait for no reason.
    private def execute_meta(task : Task, host : Host) : Nil
      # Ansible reads the meta action from the task args' _raw_params
      # at strategy time and raises for anything it doesn't recognize -
      # INCLUDING the literal None Ansible reports when _raw_params is unset
      # (a null value, an empty string, or the generator's
      # `meta: {free_form: noop}` mapping shape). The raise happens after
      # the PLAY/TASK banners and is a run-level AnsibleError, not a task
      # result: the [ERROR] block goes to stderr with the task's Origin,
      # nothing further runs, and there is no recap - rc 1 (live-verified
      # vs 2.19.11). See PlaybookParser.parse_meta_task for the parse-time
      # shapes this engine still refuses outright.
      action = task.meta_action
      unless action && Krikri::PlaybookParser::SUPPORTED_META_ACTIONS.includes?(action)
        abort_invalid_meta_action(task, action || "None")
      end
      case action
      when "flush_handlers"
        # Called once per host by the outer per-task host loop in #run,
        # but @tasks.each is sequential across tasks - every active host
        # has already finished every task BEFORE this one by the time any
        # of them reaches it, so running the full (cross-host)
        # HandlerRunner#run here is correct regardless of which host
        # triggers it first. Subsequent per-host calls for this same
        # meta task are harmless no-ops: HandlerRunner#run clears each
        # host's notified set after running, so any_notified? is false
        # for the 2nd..Nth host and #run returns immediately without
        # re-printing anything.
        run_handlers
      when "end_host"
        # Per-host - verified against ansible-playbook: a 2nd host
        # whose own `when:` makes it skip this exact task entirely keeps
        # running normally afterward, unlike end_play below. Reuses
        # halted_hosts (already excludes this host from every remaining
        # task in this play, including nested block:/rescue:/always:,
        # and - also verified live - suppresses its own pending notified
        # handlers at the end-of-play flush, exactly like a real
        # failure) but tracked separately in ended_hosts so it's NOT
        # treated as a failure for the exit code or carried forward into
        # later plays.
        @halted_hosts.add(host.name)
        @ended_hosts.add(host.name)
      when "end_play"
        # Global, NOT per-host - verified against ansible-playbook:
        # even a host whose own `when:` skips this exact task entirely
        # (never itself executes this branch) still gets halted for the
        # rest of the play the moment ANY other host does. So this halts
        # every currently-active host in the whole play, not just
        # `host` - @hosts is the play's own full host list, available on
        # the executor regardless of which single host's fiber is
        # running this code.
        @hosts.each do |other|
          next if @halted_hosts.includes?(other.name)
          @halted_hosts.add(other.name)
          @ended_hosts.add(other.name)
        end
      when "clear_host_errors"
        # Global, NOT scoped to `host` - same shape as end_play above,
        # and for the same reason: Ansible's own doc wording
        # ("clears the failed state from hosts specified in the PLAY'S
        # LIST OF HOSTS") and live verification both show it acts on
        # every failed host in the play, not just whichever host(s)
        # happen to still be active enough to individually execute this
        # meta task - a host that already failed earlier in this play is
        # EXCLUDED from this task too (same halted_hosts gate as any
        # other), so if clearing were scoped to `host` alone, the failed
        # host itself could never reach this code to clear its own
        # error, making the feature unusable exactly the way the
        # community.general docs' own example uses it (a failing task
        # immediately followed by clear_host_errors in the same task
        # list). Also confirmed live: clears the failure for SUBSEQUENT
        # plays (the failed host is back for play 2) but leaves
        # halted_hosts itself untouched, so the current play still does
        # not resume for that host - matching "does NOT continue
        # execution in the current play" exactly.
        @hosts.each do |other|
          @cleared_error_hosts.add(other.name) if @halted_hosts.includes?(other.name)
        end
      when "end_batch"
        # Ansible's end_batch ends the current `serial:` batch (all
        # its hosts, like end_play but without the end_play flag). This
        # engine doesn't model serial batching - one batch per play - so
        # end_batch IS end_play here (verified against ansible-core
        # 2.19.4's own strategy code: both call iterator.end_host for
        # every host in the play; only end_play additionally raises
        # AnsibleEndPlay, which the playbook executor handles by ending
        # THIS play only - so the observable behavior matches).
        @hosts.each do |other|
          next if @halted_hosts.includes?(other.name)
          @halted_hosts.add(other.name)
          @ended_hosts.add(other.name)
        end
      when "end_role"
        # Per-host role-scoped early return (ansible-core 2.18+).
        # Ansible consumes the role's remaining tasks for this host
        # silently in the iterator - no banners, no recap counters - and
        # stops at the role's implicit `role_complete` boundary, so
        # parent roles and role dependencies are unaffected. Keyed on
        # the role INVOCATION (Task#role_invocation_id for a dynamic
        # include_role, the role path for a static one): verified against
        # ansible-core 2.19.4 that a looped include_role whose first
        # item ends the role still runs the second item in full.
        if key = task.role_invocation_id || task.role_path
          ended = (@role_ended_hosts[key] ||= Set(String).new)
          ended.add(host.name)
        else
          # Ansible rejects end_role outside a role at PARSE time
          # ("Cannot execute 'end_role' from outside of a role") - a
          # play-level one is caught before any play runs
          # (krikri-playbook.cr's own flattened-list check); this branch
          # only covers one reached through a dynamic include_tasks:
          # body, where the file is loaded too late for that check.
          # Fails the task for this host instead of aborting the run -
          # the same "which tasks ran" divergence the role-private
          # custom-module scope cut already documents.
          connection_host = host.name
          puts "failed: [#{connection_host}]".colorize(:red)
          puts "  Cannot execute 'end_role' from outside of a role".colorize(:red)
          @results[host.name]["failed"] += 1
          @halted_hosts.add(host.name)
        end
      when "reset_connection"
        # Drop the host's persistent connection state (resident plugin
        # daemons + ssh ControlMaster sockets); the next task reopens
        # fresh connections. Ansible's result carries msg
        # "reset connection" (or "no connection, nothing to reset") and
        # counts in no recap bucket - a META: vv line only - so nothing
        # is printed or counted here either.
        SSHManager.reset_connection(host.name)
      when "noop"
        # Ansible's own doc: "this literally does 'nothing'."
      when "refresh_inventory"
        # Ansible's own doc, verified live: refreshing does NOT add
        # hosts to (or remove them from) the CURRENT play's own host
        # loop - only a LATER play's own `hosts:` pattern match sees the
        # new data, since that's computed fresh from the shared
        # Inventory object each time (krikri-playbook.cr's own per-play
        # `matched_hosts = inventory.get_hosts(...)`). Re-parsing and
        # reload_from!-ing in place (rather than just swapping in a new
        # Inventory reference) is what makes that "shared object" premise
        # true without any callback plumbing back up to krikri-playbook.cr -
        # see Inventory#reload_from!'s own comment. A no-op (not an
        # error) when no inventory_path was given - the `ansible` ad-hoc
        # CLI's own TaskExecutor never passes one, and a single synthetic
        # ad-hoc task has no later play to ever observe a refresh anyway.
        if (path = @inventory_path) && (inv = @inventory)
          inv.reload_from!(InventoryParser.parse(path, @playbook_dir != "." ? @playbook_dir : nil))
          @hv_generation += 1
        end
      else
        # Only clear_facts/flush_handlers/end_host/end_play/
        # clear_host_errors/noop/refresh_inventory parse (see
        # PlaybookParser.parse_meta_task), so clear_facts is the only
        # other action to dispatch on here. Confirmed via cli_spec.cr's
        # own pre-existing "reflects a register:/set_fact:/meta:
        # clear_facts... in another host's hostvars" spec:
        # ansible-playbook's clear_facts drops a plain (non-cacheable)
        # set_fact value too, not just gathered facts - so @set_facts
        # is cleared right alongside @facts to keep the two stores
        # consistent (a ghost @set_facts entry would otherwise keep
        # getting injected at the high tier after the clear).
        @facts[host.name].clear
        @set_facts[host.name].clear
        @set_fact_origins[host.name]?.try(&.clear)
        @facts_dict_cache.delete(host.name)
        @hv_generation += 1
      end
    end

    # The strategy-time unknown-meta-action abort (see execute_meta's own
    # comment): the [ERROR] block goes to STDERR - banners already on
    # stdout - with the task's Origin (the task's own mapping position,
    # the origin Ansible's task-level errors carry), then the run stops with
    # rc 1 and no recap. Ansible's block closes with one blank line.
    # Process.exit rather than `exit`: this runs inside the executor's
    # per-task exception paths (including the --forks worker fiber's
    # generic rescue), which would swallow the ExitException `exit`
    # raises; both streams are flushed explicitly first.
    private def abort_invalid_meta_action(task : Task, action : String) : Nil
      STDERR.puts "[ERROR]: invalid meta action requested: #{action}".colorize(:red)
      path = task.source_file
      if path && task.source_line > 0 && File.file?(path)
        lines = File.read_lines(path)
        STDERR.puts origin_context_block(path, lines, task.source_line, task.source_col)
        STDERR.puts ""
      end
      STDOUT.flush
      STDERR.flush
      Process.exit(1)
    end
  end
end
