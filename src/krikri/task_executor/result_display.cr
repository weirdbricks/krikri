require "json"
require "colorize"
require "../host"
require "../timing_profile"
require "../variable_substitutor/filter_core"
require "../argspec_validator"
require "./error_block"

module Krikri
  # A module result's "failed" flag read the way real Ansible's Python
  # truthiness reads it: the wire protocol normally carries a JSON bool,
  # but real ansible-core's TaskExecutor puts INTEGER 0 in the async
  # fire-and-forget launch result ("failed: 0" - confirmed via the
  # podman-diff async_status cases), and a hard as_bool cast crashes the
  # executor on it. 0 is falsy, 1 truthy, matching Python.
  def self.result_failed_flag(result : JSON::Any) : Bool
    case raw = result["failed"]?.try(&.raw)
    when Bool  then raw
    when Int64 then raw != 0
    else            false
    end
  end

  # ResultDisplay - Handles displaying task results and diffs
  module ResultDisplay
    # Warning texts already printed this run (real Display.warning dedups).
    @@warned_texts = Set(String).new

    # Display task result with appropriate formatting.
    # item_label is set for looped tasks, rendering `ok: [host] => (item=x)`
    # to match how Ansible annotates per-iteration output.
    # source_task carries the task's parsed source position and module
    # identity so a failed result can render real ansible-core 2.19's
    # `[ERROR]: Task failed:` block (see ErrorBlock) before the fatal/
    # failed line; nil (or a task without a parsed position) suppresses
    # the block.
    def self.display_result(host : Host, result : JSON::Any, diff_mode : Bool, item_label : String? = nil, ignore_errors : Bool = false, no_log : Bool = false, module_name : String? = nil, delegate_target : String? = nil, source_task : Task? = nil, loop_item : JSON::Any? = nil, loop_var_name : String? = nil) : Nil
      TimingProfile.measure("display.result", "display") do
        display_result_measured(host, result, diff_mode, item_label, ignore_errors, no_log, module_name, delegate_target, source_task, loop_item, loop_var_name)
      end
    end

    private def self.display_result_measured(host : Host, result : JSON::Any, diff_mode : Bool, item_label : String? = nil, ignore_errors : Bool = false, no_log : Bool = false, module_name : String? = nil, delegate_target : String? = nil, source_task : Task? = nil, loop_item : JSON::Any? = nil, loop_var_name : String? = nil) : Nil
      # delegate_to: renders the host line as real Ansible does:
      # `ok: [source -> target]` - the task ran against the delegate
      # target even though it reports under the play host.
      host_label = delegate_target ? "#{host.connection_host} -> #{delegate_target}" : host.connection_host
      changed = result["changed"]?.try(&.as_bool) || false
      failed = Krikri.result_failed_flag(result)
      # as_s? (not as_s): the debug action plugin keeps a whole-span
      # container msg natively (a real dict/list - see its own re-parse),
      # so a naive as_s cast crashes the whole display fiber on it.
      msg = result["msg"]?.try(&.as_s?) || ""

      # Module warnings (result["warnings"]) print as `[WARNING]: <text>` on
      # stderr BEFORE the status line, each distinct text once per run - real
      # ansible's Display.warning dedups on the message (live-verified vs
      # 2.19.11 with find's "Skipped '<path>' path due to this access issue").
      result["warnings"]?.try(&.as_a?).try &.each do |warning|
        text = warning.as_s? || warning.to_s
        next unless @@warned_texts.add?(text)
        STDERR.puts "[WARNING]: #{text.strip}".colorize(:light_magenta)
      end
      emit_debug_template_error_warning(source_task, result)

      # Real's callback (CallbackBase._dump_results) drops these top-level
      # keys before any dump at verbosity < 3: `warnings`/`deprecations` are
      # only ever shown as their own [WARNING] lines, `invocation` is hidden
      # unless -vvv (getent-style results carry one for `register`).
      if (top = result.as_h?) && (top.has_key?("warnings") || top.has_key?("invocation") || top.has_key?("deprecations"))
        result = JSON::Any.new(top.reject("warnings", "invocation", "deprecations"))
      end

      # no_log: print the status line and NOTHING else - no msg, no
      # stdout, no diff, no error detail. Real ansible-playbook shows
      # exactly `changed: [host]` / `ok: [host]` for such a task and
      # leaks nothing even under -v (verified against 2.19.4). This is a
      # security control, so it is applied before any other branch below
      # can print part of the result.
      if no_log
        # Real 2.19 DOES print the error block for a failed no_log task
        # (with the raw, uncensored message - an upstream leak), but
        # krikri deliberately does not replicate that leak: the block
        # would echo the secret this control exists to hide. Everything
        # else matches real 2.19.11: a solo failed no_log task prints the
        # censored fatal dump (which carries no secret) plus "...ignoring"
        # when ignore_errors: caught it; ok/changed and looped results
        # stay bare status lines (live-verified against 2.19.11).
        if failed && item_label.nil?
          puts "fatal: [#{host_label}]: FAILED! => {\"censored\": \"the output has been hidden due to the fact that 'no_log: true' was specified for this result\", \"changed\": #{changed}}".colorize(:red)
          puts "...ignoring".colorize(:red) if ignore_errors
          return
        end
        status_only = if failed
                        "failed".colorize(:red).bold
                      elsif changed
                        "changed".colorize(:yellow)
                      else
                        "ok".colorize(:green)
                      end
        # Real Ansible censors the loop item too under no_log - the item
        # value can itself be a secret (e.g. `loop: "{{ keepass_attrs }}"`
        # on a credential-reading task), so `(item=<value>)` must never
        # print verbatim.
        suffix_only = item_label ? " => (item=(censored due to no_log))" : ""
        puts "#{status_only}: [#{host_label}]#{suffix_only}"
        return
      end

      # Status indicator
      status = if failed
                 "failed".colorize(:red).bold
               elsif changed
                 "changed".colorize(:yellow)
               else
                 "ok".colorize(:green)
               end

      suffix = item_label ? " => (item=#{item_label})" : ""

      # A failed (non-loop) task's real ansible-core 2.19 display is ONE
      # line: `fatal: [host]: FAILED! => {json}` with the whole result
      # JSON dumped sorted (live-verified: a command: failure shows
      # `fatal: [target]: FAILED! => {"changed": true, "cmd": [...],
      # "msg": "non-zero return code", "rc": 1, ...}`). The engine's old
      # display printed `failed: [host]` plus a separate `  Message:`
      # line - a different word AND a different shape than anything real
      # produces (found live via modules_systems.yml's wrong-checksum
      # rescue probe, where the recap-parity task-status diff flagged
      # fatal-vs-failed on the one failing task in the whole play).
      # Loop-item failures keep the loop display below unchanged - real's
      # loop-failure line uses a different shape again
      # (`failed: [host] (item=X) => {json}`), and the engine's own
      # loop display (`failed: [host] => (item=X)` plus detail lines) is
      # a documented, deliberately-not-yet-matched cosmetic gap - so only
      # the NON-loop (no item_label) case takes the single-line dump.
      if failed && item_label.nil?
        # Real's stdout callbacks strip failed/skipped/_ansible_* before
        # dumping (as_callback_task_result), so the FAILED! dump carries
        # neither "failed": true nor any _ansible_* key.
        emit_task_error_block(source_task, result, msg)
        # Real 2.19.11's fatal dump has three shapes:
        # - a task-level when:/loop-source failure (marked by
        #   when_error_result) dumps ONLY the msg:
        #   {"msg": "Task failed: ..."} - no changed key (live-verified
        #   with and without register:/ignore_errors:).
        # - an action failure that tagged its result
        #   _ansible_verbose_always (assert: does, unless quiet:) dumps
        #   the whole result pretty-printed, 4-space indent, sorted keys
        #   (live-verified: assert: failure).
        # - every other failure dumps the whole result single-line.
        if result["_ansible_task_error_msg_only"]?.try(&.as_bool) == true
          puts "fatal: [#{host_label}]: FAILED! => {\"msg\": #{msg.to_json}}".colorize(:red)
        elsif result["_ansible_verbose_always"]?.try(&.as_bool) == true
          puts "fatal: [#{host_label}]: FAILED! => #{dump_pretty(clean_for_display(result))}".colorize(:red)
        else
          puts "fatal: [#{host_label}]: FAILED! => #{ResultDisplay.python_json_dump(clean_for_display(result))}".colorize(:red)
        end
        # Real ansible-playbook prints a bare "...ignoring" line right
        # after a failed task's output when ignore_errors: caught it
        # (live-verified against a real run) - the single-line dump above
        # replaced the old multi-line failure display, which carried this
        # suffix in its now-unreachable tail, so it has to be re-emitted
        # here or ignored non-loop failures silently lose it.
        puts "...ignoring".colorize(:red) if ignore_errors
        return
      end

      # Loop-item failures: real's shape is a single line per failed item,
      # `failed: [host] (item=X) => {json}` (item BEFORE the `=>`, the whole
      # result dumped inline sorted), with `...ignoring` printed ONCE after
      # the whole loop rather than per item (finish_looped_task owns that).
      # The old path printed `failed: [host] => (item=X)` plus a `  Message:`
      # /`  Exit code:` detail block and a per-item `...ignoring` - a
      # different word-order, extra lines, and repeated suffix vs real.
      if failed && !item_label.nil?
        # Real's default callback runs its exception handling (the error
        # block) once per failed ITEM result, before that item's line;
        # ErrorBlock's Display-level dedup collapses identical repeats.
        emit_task_error_block(source_task, result, msg)
        if result["_ansible_task_error_msg_only"]?.try(&.as_bool) == true
          # A when:-failed loop item is a task-level failure: real dumps
          # the msg alone, with no changed key and no loop-item keys
          # (live-verified: a looped when: failure shows
          # `failed: [host] (item=N) => {"msg": "Task failed: ..."}`).
          puts "failed: [#{host_label}] (item=#{item_label}) => {\"msg\": #{msg.to_json}}".colorize(:red)
          return
        end
        dumped = clean_for_display(result)
        # Real's strategy merges the loop item itself into every per-item
        # result before the callback dumps it, so a failed item's dump
        # carries "ansible_loop_var" plus the item under the loop var's
        # name (live-verified: a looped fail: item shows
        # {"ansible_loop_var": "item", "changed": false, "item": "x",
        # "msg": ...}). Module results reach display without those keys,
        # so restore them here.
        if item = loop_item
          h = dumped.as_h.try(&.dup) || Hash(String, JSON::Any).new
          var_name = loop_var_name.try { |name| !name.empty? ? name : nil } || "item"
          h["ansible_loop_var"] = JSON::Any.new(var_name)
          h[var_name] = item
          dumped = JSON::Any.new(h)
        end
        if result["_ansible_verbose_always"]?.try(&.as_bool) == true
          puts "failed: [#{host_label}] (item=#{item_label}) => #{dump_pretty(dumped)}".colorize(:red)
        else
          puts "failed: [#{host_label}] (item=#{item_label}) => #{ResultDisplay.python_json_dump(dumped)}".colorize(:red)
        end
        return
      end

      # Real ansible appends the full result JSON (pretty, 4-space indent,
      # sorted keys) to the status line when the run is verbose OR the
      # result carries _ansible_verbose_always (the debug and assert
      # action plugins tag their results that way). At default verbosity
      # without the tag, real prints ONLY the status line - never a msg
      # body - so the engine's old `  msg` display for successful tasks
      # is gone: a non-verbose success shows just `ok: [host]`.
      verbose_always = !failed &&
                       result["_ansible_verbose_always"]?.try(&.as_bool) == true &&
                       result["_ansible_verbose_override"]?.try(&.as_bool) != true

      if verbose_always
        cleaned = module_name.try(&.ends_with?("debug")) ? debug_clean_result(result) : clean_for_display(result)
        puts "#{status}: [#{host_label}]#{suffix} => #{dump_pretty(cleaned)}"
      else
        puts "#{status}: [#{host_label}]#{suffix}"
      end

      # If failed, show additional error details
      if failed
        # Show error message
        if msg && !msg.empty?
          puts "  Message: #{msg}".colorize(:red)
        end

        # Show stderr if available
        if stderr = result["stderr"]?.try(&.as_s)
          if !stderr.empty?
            puts "  Error output:".colorize(:red)
            stderr.lines.each do |line|
              puts "    #{line}".colorize(:red)
            end
          end
        end

        # Show stdout if available (might have partial output)
        if stdout = result["stdout"]?.try(&.as_s)
          if !stdout.empty?
            puts "  Output:".colorize(:yellow)
            stdout.lines.each do |line|
              puts "    #{line}".colorize(:yellow)
            end
          end
        end

        # Show exit code if available. rc can legitimately be NULL (not
        # just absent) - real Ansible's chdir-before-execution failure
        # fails the module with rc: null (its run_command never spawned
        # anything, live-verified against 2.19.4), and `.as_i` on a
        # JSON null hard-crashed the whole engine here where real
        # ansible-playbook simply omits the Exit code line.
        if rc_value = result["rc"]?
          unless rc_value.raw == nil
            puts "  Exit code: #{rc_value.as_i}".colorize(:red)
          end
        end

        # Real ansible-playbook always prints a bare "...ignoring" line
        # right after a failed task's own output when ignore_errors:
        # caught it - verified directly against a real ansible-playbook
        # run. This was previously never printed at all for a normal
        # ignored failure (only added, narrowly, for the when:-raises-
        # an-exception case - see WhenEvaluationError's own history);
        # fixed here so every ignored failure gets it, matching real
        # Ansible regardless of why the task failed.
        puts "...ignoring".colorize(:red) if ignore_errors
      end

      # Display diff if present and diff_mode enabled
      if diff_mode && result["diff"]?
        display_diff(result["diff"])
      end
    end

    # Builds and prints real ansible-core 2.19's `[ERROR]: Task failed:`
    # block for a failed task result, labeled with the task's parsed
    # playbook origin. No-op when the task has no parsed position, the
    # failure is a conditional-evaluation failure (whose two-level chain
    # is emitted by TaskExecutor's own emit_when_error_chain, including
    # the `when:` value's own Origin), or no_log is hiding the result.
    private def self.emit_task_error_block(source_task : Task?, result : JSON::Any, msg : String) : Nil
      return unless source_task
      return if source_task.no_log?
      # Task-arg finalization failures ("Task failed: Finalization of task
      # args for ...") get their own multi-level block from the executor
      # (emit_finalization_error_block) before the fatal line.
      return if msg.starts_with?("Task failed: Finalization of task args for")
      # assert:'s that: conditional failure: two-level chain, the second
      # Origin pointing at the failing that: item (index carried in the
      # internal _ansible_that_index key; when: failures are emitted by
      # TaskExecutor's own emit_when_error_chain instead).
      if (idx = result["_ansible_that_index"]?.try(&.as_i64?)) && msg.starts_with?("Task failed: Error while evaluating conditional")
        emit_assert_that_chain(source_task, msg["Task failed: ".size..], idx.to_i)
        return
      end
      return if msg.includes?("Error while evaluating conditional")
      # Non-boolean conditional failures are likewise emitted by
      # emit_when_error_chain (with the when: value's own Origin); a
      # second block here would duplicate it wrapped in a bogus
      # "Module failed:" segment.
      return if msg.includes?("Conditional result")

      origin = error_origin_context(source_task)
      return unless origin

      # A plugin whose block text differs from the fatal msg (fetch's slurp
      # failure) hands the block its own text via _ansible_error_detail.
      msg = result["_ansible_error_detail"]?.try(&.as_s?) || msg
      # A plugin flagging _ansible_action_level failed in real's controller-
      # side ACTION plugin (a bare AnsibleActionFail: no "Module failed."
      # middle segment), e.g. assemble's remote_src: false isdir() check.
      if result["_ansible_action_level"]?.try(&.as_bool?) == true
        root = ErrorBlock::Node.new("Task failed.", source_context: origin)
        ErrorBlock.emit(root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg)))
        return
      end
      ErrorBlock.emit(task_error_chain(source_task.module_name, msg, origin))
    end

    # `debug: var: undefined_name` renders the error inline ("<< error 1 - ...
    # >>", see DebugActionPlugin) and real ALSO prints a "[WARNING]:
    # Encountered 1 template error." block on stderr naming the var: value's
    # Origin (live-verified 2.19.11); deduped like every Display.warning.
    private def self.emit_debug_template_error_warning(task : Task?, result : JSON::Any) : Nil
      return unless task && (hash = result.as_h?)
      hash.each_value do |value|
        next unless (text = value.as_s?) && (m = text.match(/\A<< error (\d+) - (.*) >>\z/))
        path = task.source_file
        next unless path && task.source_line > 0 && File.file?(path)
        lines = File.read_lines(path)
        origin = nil
        ((task.source_line - 1)...Math.min(lines.size, task.source_line + 40)).each do |idx|
          line = lines[idx]
          next unless (at = line.index(/\bvar:\s*/))
          rest = line[(at + 4)..]
          origin = ErrorBlock.origin_context(path, idx + 1, at + 4 + (rest.size - rest.lstrip.size) + 1)
          break
        end
        next unless origin
        warning = "[WARNING]: Encountered #{m[1]} template error.\nerror #{m[1]} - #{m[2]}\n#{origin}\n\n"
        STDERR.puts warning if @@warned_texts.add?(warning)
      end
    end

    private def self.emit_assert_that_chain(task : Task, inner : String, index : Int32) : Nil
      task_origin = error_origin_context(task)
      item_origin = assert_that_origin(task, index)
      return unless task_origin && item_origin

      root = ErrorBlock::Node.new("Task failed.", source_context: task_origin)
      cause = ErrorBlock::Node.new(inner, source_context: item_origin)
      ErrorBlock.emit(root.with_chain(ErrorBlock::DIRECT_CAUSE, true, cause))
    end

    # Origin context of assert's that: item number `index` (0-based): the
    # scalar's own line/column, found by scanning the task's source lines
    # (the parser tracks per-task, not per-list-item, positions).
    private def self.assert_that_origin(task : Task, index : Int32) : String?
      path = task.source_file
      return nil unless path && task.source_line > 0 && File.file?(path)

      lines = File.read_lines(path)
      ((task.source_line - 1)...lines.size).each do |idx|
        line = lines[idx]
        key_at = line.index("that:")
        next unless key_at && line[0...key_at].strip.empty?
        rest = line[(key_at + 5)..]
        unless rest.strip.empty?
          column = key_at + 5 + (rest.size - rest.lstrip.size) + 1
          return ErrorBlock.origin_context(path, idx + 1, column)
        end

        count = 0
        ((idx + 1)...lines.size).each do |item_idx|
          item_line = lines[item_idx]
          stripped = item_line.strip
          next if stripped.empty? || stripped.starts_with?('#')
          break unless stripped.starts_with?("- ")
          if count == index
            dash = item_line.index("- ").not_nil!
            item_rest = item_line[(dash + 2)..]
            column = dash + 2 + (item_rest.size - item_rest.lstrip.size) + 1
            return ErrorBlock.origin_context(path, item_idx + 1, column)
          end
          count += 1
        end
        return nil
      end
      nil
    end

    private def self.error_origin_context(task : Task) : String?
      path = task.source_file
      return nil unless path && task.source_line > 0
      ErrorBlock.origin_context(path, task.source_line, task.source_col > 0 ? task.source_col : nil)
    end

    # The cause chain real ansible-core 2.19 builds for each failure
    # class, as an ErrorBlock event tree rooted at the task-level
    # AnsibleTaskError ("Task failed."):
    #
    # - template (its action plugin re-raises the loader's file-not-found
    #   inside `except` without `raise ... from`): the two-segment
    #   handling chain - live-verified against 2.19.11.
    # - fail/assert (action-level failures): "Action failed." + the
    #   result message.
    # - copy's controller-side src miss (its action raises
    #   `AnsibleActionFail(result=result) from ex` with an empty message,
    #   so the type name becomes the middle segment): collapsed chain
    #   carrying real's exact wording.
    # - every other module-level failure: "Module failed." + the result
    #   message (the module API's own wrapper), collapsed.
    private def self.task_error_chain(module_name : String?, msg : String, origin : String) : ErrorBlock::Node
      root = ErrorBlock::Node.new("Task failed.", source_context: origin)

      # An argspec-validation failure we emitted has real's own chain
      # shape, which differs from every other failure class: module-level
      # validation (the generated spec table) is the generic collapsed
      # "Module failed." chain - this matters for template:, whose usual
      # two-segment handling chain would wrongly duplicate the message -
      # while action-only directives (debug/assert/fail/...) fail with
      # NO middle segment at all.
      if kind = module_name.try { |name| ArgspecValidator.failure_kind?(name, msg) }
        case kind
        when :action
          return root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg))
        else
          return root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new("Module failed.").with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg)))
        end
      end

      short = module_name.try { |name| name.split(".").last }
      case short
      when "template"
        root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg).with_chain(ErrorBlock::HANDLING, false, ErrorBlock::Node.new(msg)))
      when "fail", "assert"
        root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new("Action failed.").with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg)))
      else
        if (match = msg.match(/\ATask failed: Could not find or access '([^']*)' on the Ansible Controller\./)) &&
           msg.includes?("If you are using a module and expect the file to exist on the remote, see the remote_src option")
          not_found = "Could not find or access '#{match[1]}' on the Ansible Controller.\nIf you are using a module and expect the file to exist on the remote, see the remote_src option"
          root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new("Unexpected AnsibleActionFail error.").with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(not_found)))
        elsif (match = msg.match(/\AUnexpected AnsibleActionFail error: Could not find or access '([^']*)' on the Ansible Controller\./)) &&
              msg.includes?("If you are using a module and expect the file to exist on the remote, see the remote_src option")
          # copy:'s controller-side src miss on a LOCAL connection: real
          # 2.19.11's fatal msg carries the "Unexpected AnsibleActionFail
          # error: " prefix itself (no "Task failed: " prefix), and the
          # block chain is the same collapsed shape
          # (live-verified: copy: with a missing src under -c local).
          not_found = "Could not find or access '#{match[1]}' on the Ansible Controller.\nIf you are using a module and expect the file to exist on the remote, see the remote_src option"
          root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new("Unexpected AnsibleActionFail error.").with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(not_found)))
        elsif module_name.try(&.ends_with?(".copy")) &&
              {"src and content are mutually exclusive", "src (or content) is required", "dest is required"}.includes?(msg)
          # copy's action-level src/content conflict (raised before
          # argspec validation, ordering live-verified against 2.19.11):
          # real's chain is the action-level "Action failed." shape.
          root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new("Action failed.").with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg)))
        else
          root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new("Module failed.").with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg)))
        end
      end
    end

    # Display an ad-hoc `ansible` command's result, matching real
    # ansible's own default ("minimal") callback: `host | STATUS | rc=N >>`
    # followed by raw stdout for command-shaped modules (rc + stdout
    # present - command/shell/script/raw), or `host | STATUS => {...}`
    # pretty-printed JSON for every other module. Deliberately NOT
    # ResultDisplay.display_result - that one renders ansible-playbook's
    # own "ok: [host]" TASK-recap style, a different output convention
    # ansible's ad-hoc CLI has never used.
    # Ad-hoc-only output modifiers, set by krikri.cr (the `ansible`
    # counterpart binary) from its own CLI flags:
    #
    # -o/--one-line switches to real Ansible's deprecated `oneline`
    # callback shape - everything on ONE line: command-shaped results
    # render as `host | STATUS | rc=N | (stdout) ...` with newlines
    # escaped (verified against ansible-core 2.19.4's
    # plugins/callback/oneline.py), everything else renders the result
    # JSON compact (indent=0, newlines stripped) instead of pretty.
    # There is no krikri-playbook equivalent to mirror - the playbook CLI
    # has no -o.
    class_property? adhoc_oneline : Bool = false

    # -t/--tree DIR: additionally log each result as pretty JSON in
    # DIR/<hostname>, like real Ansible's tree callback plugin.
    class_property adhoc_tree_dir : String? = nil

    # Real ansible's ad-hoc ("minimal" and "oneline") callbacks pass the
    # ENTIRE multi-line result buffer to `Display.display(msg, color=...)`,
    # whose `stringc()` wraps EACH line of the buffer individually with
    # one shared SGR code (`\e[<code>m<line>\e[0m`, joined by "\n") after
    # stripping one trailing newline - so the whole block gets the same
    # color, not just the status word. Codes come from ansible.constants'
    # COLOR_CODES (verified byte-for-byte against ansible-core 2.19.4 via
    # `ANSIBLE_FORCE_COLOR=1 ansible ... | xxd`): yellow=0;33 (changed),
    # green=0;32 (ok), red=0;31 (failed), and bright red=1;31 (unreachable)
    # - a distinct bold variant, NOT plain red.
    private ADHOC_COLOR_CODES = {
      changed:     "0;33",
      ok:          "0;32",
      failed:      "0;31",
      unreachable: "1;31",
    }

    # Replicates ansible's `Display.display(buffer, color=...)` byte-for-
    # byte for a fixed color: strips one trailing newline, wraps each
    # remaining line in the SGR sequence, re-adds the newline. With color
    # disabled (non-tty unless ANSIBLE_FORCE_COLOR=1) the buffer passes
    # through untouched, matching ansible's own nocolor path.
    private def self.adhoc_display(buffer : String, color_code : String) : Nil
      unless Colorize.enabled?
        print buffer
        return
      end
      body = buffer.ends_with?('\n') ? buffer.chomp('\n') : buffer
      wrapped = body.split('\n').map { |line| "\e[#{color_code}m#{line}\e[0m" }.join("\n")
      print wrapped + "\n"
    end

    # Returns {state word, SGR color code} for an ad-hoc result, mirroring
    # real ansible's minimal/oneline callbacks: unreachable wins over
    # failed, failed over changed. Public so the state-to-color mapping
    # (especially unreachable's distinct bright red, not plain red) can
    # be regression-tested without a live host.
    def self.adhoc_state_and_color(changed : Bool, failed : Bool, unreachable : Bool) : {String, String}
      if unreachable
        {"UNREACHABLE!", ADHOC_COLOR_CODES[:unreachable]}
      elsif failed
        {"FAILED!", ADHOC_COLOR_CODES[:failed]}
      elsif changed
        {"CHANGED", ADHOC_COLOR_CODES[:changed]}
      else
        {"SUCCESS", ADHOC_COLOR_CODES[:ok]}
      end
    end

    def self.display_adhoc_result(host : Host, result : JSON::Any, diff_mode : Bool = false, module_name : String? = nil) : Nil
      changed = result["changed"]?.try(&.as_bool) || false
      failed = Krikri.result_failed_flag(result)
      unreachable = result["unreachable"]?.try(&.as_bool) || false

      state, color_code = adhoc_state_and_color(changed, failed, unreachable)

      connection_host = host.vars["ansible_host"]?.try(&.as_s?) || host.name

      rc = result["rc"]?.try(&.as_i?)
      stdout = result["stdout"]?.try(&.as_s?)
      if adhoc_oneline?
        if rc && stdout
          escaped = stdout.gsub('\n', "\\n").gsub('\r', "\\r")
          buffer = String.build do |str|
            str << "#{connection_host} | #{state} | rc=#{rc} | (stdout) #{escaped}"
            if (stderr = result["stderr"]?.try(&.as_s?)) && !stderr.empty?
              str << " | (stderr) #{stderr.gsub('\n', "\\n").gsub('\r', "\\r")}"
            end
          end
          adhoc_display(buffer, color_code)
        else
          adhoc_display("#{connection_host} | #{state} => #{adhoc_result_json(result, module_name, oneline: true)}", color_code)
        end
      elsif rc && stdout
        # Same shape as ansible's minimal callback `_command_generic_msg`:
        # header line, then raw stdout, then stderr - all one buffer, one
        # color (real ansible does NOT color stderr separately here).
        buffer = String.build do |str|
          str << "#{connection_host} | #{state} | rc=#{rc} >>\n"
          str << stdout
          if (stderr = result["stderr"]?.try(&.as_s?)) && !stderr.empty?
            str << stderr
          end
        end
        adhoc_display("#{buffer}\n", color_code)
      else
        adhoc_display("#{connection_host} | #{state} => #{adhoc_result_json(result, module_name)}", color_code)
      end

      if diff_mode && result["diff"]?
        display_diff(result["diff"])
      end

      if tree_dir = adhoc_tree_dir
        # Real tree.py writes _dump_results(result.result) with no indent
        # override - normally a single compact, sorted line with Python's
        # default (", "/": ") separators and no trailing newline (raw
        # fd.write); a _ansible_verbose_always-tagged result (debug) still
        # flips indent_conditions to indent=4, so that one dumps pretty.
        # No debug _clean_results pop here - tree.py never calls it
        # (verified live: the tree file keeps "changed": false for debug).
        Dir.mkdir_p(tree_dir)
        cleaned = clean_for_display(result)
        tree_dump = if result["_ansible_verbose_always"]?.try(&.as_bool)
                      dump_pretty(cleaned)
                    else
                      dump_compact(cleaned, ", ")
                    end
        # Same sanitization as the fact cache: a host name with "/" (or
        # "." / "..") from a dynamic inventory must not turn --tree into
        # an arbitrary-path write.
        safe_name = host.name.gsub('/', '_')
        safe_name = "_dot_" if safe_name.empty? || safe_name == "." || safe_name == ".."
        File.write(File.join(tree_dir, safe_name), tree_dump)
      end
    end

    # The exact JSON string real Ansible's ad-hoc stdout callbacks dump
    # after the `host | STATUS => ` prefix. The result dict the callbacks
    # see has already been through real Ansible's cleaning pipeline by
    # the time it is dumped: executor/task_result.py's
    # as_callback_task_result strips `failed`/`skipped` for EVERY stdout
    # callback (a real FAILED! => dump does not contain "failed": true -
    # live-verified against 2.19.4), and _dump_results strips the private
    # `_ansible_*` keys and dumps with sort_keys=True. A debug task
    # additionally goes through _clean_results - but ONLY in the minimal
    # (pretty) path: oneline.py never calls it, so an `-o` debug dump
    # keeps its other keys (verified live). Status derivation stays with
    # the caller - stripping here is display-only.
    def self.adhoc_result_json(result : JSON::Any, module_name : String? = nil, oneline : Bool = false) : String
      failed = Krikri.result_failed_flag(result)
      unreachable = result["unreachable"]?.try(&.as_bool) || false
      verbose_always = result["_ansible_verbose_always"]?.try(&.as_bool) || false
      cleaned = clean_for_display(result)

      if oneline
        # Real oneline.py dumps with indent=0: Python's json.dumps then
        # uses (",", ": ") separators - no space after commas. A result
        # tagged _ansible_verbose_always (debug) flips _dump_results'
        # indent_conditions to indent=4, and the callback's own
        # .replace('\n', '') then just strips the newlines, leaving the
        # 4-space indents in the line verbatim.
        verbose_always ? dump_pretty(cleaned).gsub('\n', "") : dump_compact(cleaned, ",")
      else
        # Real minimal.py dumps with indent=4 (both the SUCCESS and the
        # FAILED! branches), not Crystal's 2-space default - and applies
        # its debug _clean_results pop-to-msg for a successful debug task.
        if !failed && !unreachable && module_name.try(&.ends_with?("debug")) && cleaned["msg"]?
          cleaned = JSON::Any.new({"msg" => cleaned["msg"]})
        end
        dump_pretty(cleaned)
      end
    end

    # Real Ansible strips `failed`/`skipped` and every private `_ansible_*`
    # key from the callback-visible result, recursively
    # (executor/task_result.py's _IGNORE + vars/clean.py's
    # strip_internal_keys).
    private def self.clean_for_display(value : JSON::Any) : JSON::Any
      case raw = value.raw
      when Hash
        cleaned = Hash(String, JSON::Any).new
        raw.each do |key, v|
          next if key == "failed" || key == "skipped" || key.starts_with?("_ansible_")
          cleaned[key] = clean_for_display(v)
        end
        JSON::Any.new(cleaned)
      when Array
        JSON::Any.new(raw.map { |item| clean_for_display(item) })
      else
        value
      end
    end

    # Real ansible's CallbackBase._clean_results for a debug action, run
    # before the verbose dump: a msg: result keeps ONLY msg (plus keys
    # real's own pipeline strips later - failed/skipped/_ansible_* are
    # already gone via clean_for_display), a var: result additionally
    # drops the _hide_in_debug bookkeeping keys. clean_for_display must
    # run first - it strips exactly the keys _dump_results would.
    private def self.debug_clean_result(result : JSON::Any) : JSON::Any
      cleaned = clean_for_display(result)
      if h = cleaned.as_h?
        if result["msg"]?
          h.select! { |key, _| {"msg", "exception", "warnings", "deprecations"}.includes?(key) || key.starts_with?('_') }
        else
          ["changed", "failed", "skipped", "invocation", "skip_reason",
           "ansible_loop_var", "ansible_index_var", "ansible_loop"].each { |key| h.delete(key) }
        end
      end
      cleaned
    end

    # _dump_results(indent=4, sort_keys=True) - real minimal-callback JSON
    # dump shape.
    private def self.dump_pretty(result : JSON::Any) : String
      VariableSubstitutor::FilterCore.sort_json_keys(result).to_pretty_json("    ")
    end

    # Python json.dumps' compact shapes: separators (", "/": ") when no
    # indent is given (tree callback), (", "/": " -> ",", ": ") with
    # indent=0 (oneline callback).
    private def self.dump_compact(result : JSON::Any, item_sep : String) : String
      String.build { |io| dump_compact_io(VariableSubstitutor::FilterCore.sort_json_keys(result), io, item_sep) }
    end

    private def self.dump_compact_io(value : JSON::Any, io : IO, item_sep : String) : Nil
      case raw = value.raw
      when Nil
        io << "null"
      when Bool
        io << raw
      when String
        raw.to_json(io)
      when Int64, Int32, Float64
        io << raw
      when Array
        io << '['
        raw.each_with_index do |item, index|
          io << item_sep if index > 0
          dump_compact_io(item, io, item_sep)
        end
        io << ']'
      when Hash
        io << '{'
        raw.each_with_index do |(key, item), index|
          io << item_sep if index > 0
          key.to_s.to_json(io)
          io << ": "
          dump_compact_io(item, io, item_sep)
        end
        io << '}'
      else
        raw.to_s.to_json(io)
      end
    end

    # Display diff (delegates to specific diff types)
    def self.display_diff(diff : JSON::Any) : Nil
      puts ""

      # Content diff (copy, template)
      if diff["before"]? && diff["after"]? && diff["before"].as_s? && diff["after"].as_s?
        display_content_diff(diff)
        # Attribute diff (file)
      elsif diff["before"]?.try(&.as_h?) && diff["after"]?.try(&.as_h?)
        display_attribute_diff(diff)
      end
    end

    # Display content diff (for file content changes)
    def self.display_content_diff(diff : JSON::Any) : Nil
      before = diff["before"].as_s
      after = diff["after"].as_s
      before_header = diff["before_header"]?.try(&.as_s) || "before"
      after_header = diff["after_header"]?.try(&.as_s) || "after"

      puts "--- #{before_header}".colorize(:red).bold
      puts "+++ #{after_header}".colorize(:green).bold

      show_unified_diff(before, after)
      puts ""
    end

    # Display attribute diff (for file attributes like mode, owner)
    def self.display_attribute_diff(diff : JSON::Any) : Nil
      before = diff["before"].as_h
      after = diff["after"].as_h

      puts "--- before".colorize(:red).bold
      puts "+++ after".colorize(:green).bold

      # Show changes
      all_keys = (before.keys + after.keys).uniq.sort
      all_keys.each do |key|
        before_val = before[key]?
        after_val = after[key]?

        if before_val && after_val && before_val.to_s != after_val.to_s
          puts "-  #{key}: \"#{before_val}\"".colorize(:red)
          puts "+  #{key}: \"#{after_val}\"".colorize(:green)
        elsif before_val && !after_val
          puts "-  #{key}: \"#{before_val}\"".colorize(:red)
        elsif after_val && !before_val
          puts "+  #{key}: \"#{after_val}\"".colorize(:green)
        end
      end
      puts ""
    end

    # Show unified diff using system diff command
    def self.show_unified_diff(before : String, after : String) : Nil
      # Create temp files for diff
      before_file = "/tmp/krikri-playbook-before-#{Random::Secure.hex(4)}"
      after_file = "/tmp/krikri-playbook-after-#{Random::Secure.hex(4)}"

      File.write(before_file, before)
      File.write(after_file, after)

      # Run diff command
      diff_output = `diff -u #{before_file} #{after_file} 2>/dev/null`

      # Cleanup
      File.delete(before_file) if File.exists?(before_file)
      File.delete(after_file) if File.exists?(after_file)

      # Skip first two lines (--- and +++ headers, we show our own)
      lines = diff_output.lines
      return if lines.size < 3

      # Colorize and display
      lines[2..-1].each do |line|
        colored = case line[0]?
                  when '-'
                    line.colorize(:red)
                  when '+'
                    line.colorize(:green)
                  when '@'
                    line.colorize(:cyan).bold
                  else
                    line
                  end
        puts colored
      end
    end

    # Update stats based on task result. A failure with ignore_errors: yes
    # still displays as failed (see display_result) but doesn't count
    # toward the host's failure tally - matching Ansible, where an
    # ignored failure doesn't fail the play or the process exit code.
    def self.update_stats(stats : Hash(String, Int32), result : JSON::Any, ignore_errors : Bool = false) : Nil
      changed = result["changed"]?.try(&.as_bool) || false
      failed = Krikri.result_failed_flag(result)

      if failed && !ignore_errors
        stats["failed"] += 1
      else
        # Real Ansible's own recap counters overlap, not mutually
        # exclusive: "ok" counts every successful task (changed or not),
        # and "changed" is a separate tally on top of that - verified
        # against a real ansible-playbook run (ok=3, changed=2 for 2
        # changed + 1 unchanged successful tasks), not assumed.
        stats["ok"] += 1
        stats["changed"] += 1 if changed

        # A task that failed but was caught by ignore_errors: still
        # increments "ok" (and "changed") above - real Ansible's own
        # strategy/__init__.py does the exact same `increment('ok', ...)`
        # + `increment('ignored', ...)` pair for this case (verified
        # against its source, not assumed) - but it ALSO increments a
        # separate "ignored" counter alongside, which this recap had no
        # key for at all until now.
        stats["ignored"] += 1 if failed && ignore_errors
      end
    end

    # Show recap of all host results, matching real ansible-playbook's
    # v2_playbook_on_stats byte-for-byte: host column padded to 26 plain
    # (37 when colorized, padding applied AROUND the ANSI-wrapped name
    # the way real's `%-37s` does), then " : ", then the seven counters
    # each shaped `lead=%-4s` and joined with single spaces - so every
    # counter carries trailing padding, including the last one.
    def self.show_recap(hosts : Array(Host), results : Hash(String, Hash(String, Int32))) : Nil
      # Sorted by host name, matching real ansible-playbook - this used
      # to print in inventory order, so a recap for db1/web1/web2 came
      # out web1, web2, db1 and could not be diffed against a real run.
      hosts.sort_by(&.name).each do |host|
        # A host can reach the recap with no results at all: krikri-playbook.cr
        # adds every play's hosts to the recap list *before* deciding
        # whether the play has any tasks to run, so a playbook whose plays
        # are all skipped (no tasks, or none matching --tags) used to crash
        # here with `Missing hash key`. Zeroes are the honest recap for a
        # host nothing ran on, and match what real ansible-playbook prints.
        stats = results[host.name]? || {
          "ok" => 0, "changed" => 0, "unreachable" => 0, "failed" => 0, "skipped" => 0, "rescued" => 0, "ignored" => 0,
        }

        unreachable = stats["unreachable"]? || 0
        skipped = stats["skipped"]? || 0
        rescued = stats["rescued"]? || 0
        ignored = stats["ignored"]? || 0

        # Real's colorize(lead, num, color) shapes `lead=%-4s` and colors
        # the WHOLE field only when num != 0 (zero counters stay plain
        # even on a tty). rescued shares ok's green, ignored shares
        # changed's warning color - both per real's own v2_playbook_on_stats.
        counters = [
          {"ok", stats["ok"], :green},
          {"changed", stats["changed"], :yellow},
          {"unreachable", unreachable, :red},
          {"failed", stats["failed"], :red},
          {"skipped", skipped, :cyan},
          {"rescued", rescued, :green},
          {"ignored", ignored, :yellow},
        ] of {String, Int32, Symbol}

        parts = counters.map do |label, num, color|
          field = "#{label}=#{num}".ljust(label.size + 5)
          if num != 0 && Colorize.enabled?
            field.colorize(color).to_s
          else
            field
          end
        end

        host_field = if Colorize.enabled?
                       # Real's hostcolor colored branch pads the ANSI-wrapped name to
                       # 37 (26 visible + 11 for the escape bytes); failure or
                       # unreachability wins over changed, which wins over plain ok.
                       color = if stats["failed"] != 0 || unreachable != 0
                                 :red
                               elsif stats["changed"] != 0
                                 :yellow
                               else
                                 :green
                               end
                       host.name.colorize(color).to_s.ljust(37)
                     else
                       host.name.ljust(26)
                     end

        puts "#{host_field} : #{parts.join(" ")}"
      end
    end

    # Serializes *result* the way real Ansible dumps a failed task's JSON:
    # keys sorted alphabetically at every level, single line, Python's
    # json.dumps default separators (", " between items, ": " after keys).
    def self.python_json_dump(result : JSON::Any) : String
      python_json_value(result)
    end

    # Python's repr() of a value, matching how real Ansible renders a loop
    # item in its `failed:`/`changed:` display (`True`/`False`/`None`,
    # single-quoted strings/dict-keys, insertion-order dict `{k: v}`, `[..]`
    # lists) - distinct from the JSON dump used for the result object, which
    # stays lower-case true/false.
    def self.python_repr(value : JSON::Any) : String
      case raw = value.raw
      when Hash(String, JSON::Any)
        inner = raw.map { |k, v| "'#{k}': #{python_repr(v)}" }.join(", ")
        "{#{inner}}"
      when Array(JSON::Any)
        "[" + raw.map { |v| python_repr(v) }.join(", ") + "]"
      when Nil
        "None"
      when Bool
        raw ? "True" : "False"
      when Int64, Int32, Float64
        raw.to_s
      else
        "'" + value.to_s.gsub("\\", "\\\\").gsub("'", "\\'") + "'"
      end
    end

    private def self.python_json_value(value : JSON::Any) : String
      case raw = value.raw
      when Hash(String, JSON::Any)
        "{#{raw.to_a.sort_by(&.[0]).map { |k, v| %("#{k}": #{python_json_value(v)}) }.join(", ")}}"
      when Array(JSON::Any)
        "[#{raw.map { |item| python_json_value(item) }.join(", ")}]"
      when Nil
        "null"
      when Bool
        raw ? "true" : "false"
      when Int64, Float64
        raw.to_s
      else
        value.to_s.to_json
      end
    end
  end
end
