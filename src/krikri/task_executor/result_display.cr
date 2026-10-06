require "json"
require "colorize"
require "../host"
require "../timing_profile"
require "../variable_substitutor/filter_core"
require "../argspec_validator"
require "./error_block"

module Krikri
  # A module result's "failed" flag read the way Ansible's Python
  # truthiness reads it: the wire protocol normally carries a JSON bool,
  # but ansible-core's TaskExecutor puts INTEGER 0 in the async
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
    # ansible-playbook -v and above append a small JSON dump to every
    # "skipping:" line. A when:-false skip carries the RAW when: condition
    # under "false_condition" (a literal YAML false stays an unquoted
    # `false`, anything written as a string keeps its quotes); a looped
    # skip adds the item; a fully-skipped loop's trailing line carries
    # {"msg": "All items skipped"} (live-verified vs 2.19.11). Default
    # verbosity prints no dump at all.
    def self.skip_line_suffix(when_text : String? = nil, item : JSON::Any? = nil, all_skipped : Bool = false) : String
      return "" unless RunOptions.verbosity >= 1
      dump = if all_skipped
               {"changed" => JSON::Any.new(false), "msg" => JSON::Any.new("All items skipped")} of String => JSON::Any
             else
               d = {} of String => JSON::Any
               if when_text
                 d["false_condition"] = case when_text
                                        when "false" then JSON::Any.new(false)
                                        when "true"  then JSON::Any.new(true)
                                        else              JSON::Any.new(when_text)
                                        end
               end
               d["item"] = item if item
               d
             end
      return "" if dump.empty?
      " => #{ResultDisplay.dump_suffix(JSON::Any.new(dump))}"
    end

    # Single-line sorted JSON dump at -v/-vv; Ansible's pretty 4-space-indent
    # shape from -vvv up. Shared by every skip suffix helper.
    def self.dump_suffix(value : JSON::Any) : String
      RunOptions.verbosity >= 3 ? dump_pretty(value) : python_json_dump(value)
    end

    # The -v suffix for a skipped result that carries a full module payload
    # (check-mode skips, plugin-side skipped: results): real dumps the whole
    # cleaned result - the "skipped"/"failed" flags and the "invocation"
    # block are absent from the visible dump at -v/-vv (invocation only
    # shows at -vvv; live-verified vs 2.19.11). A looped skip's dump
    # additionally carries ansible_loop_var + the item, same as ok/changed
    # loop dumps.
    def self.skip_result_suffix(result : JSON::Any, item : JSON::Any? = nil, loop_var_name : String? = nil) : String
      return "" unless RunOptions.verbosity >= 1
      top = result.as_h
      return "" if top.empty?
      cleaned = RunOptions.verbosity >= 3 ? top.reject("skipped", "skipped_reason", "failed") : top.reject("skipped", "skipped_reason", "failed", "invocation", "warnings", "deprecations")
      if item
        var_name = loop_var_name.try { |name| !name.empty? ? name : nil } || "item"
        cleaned["ansible_loop_var"] = JSON::Any.new(var_name)
        cleaned[var_name] = item
      end
      return "" if cleaned.empty?
      " => #{ResultDisplay.dump_suffix(JSON::Any.new(cleaned))}"
    end

    # Warning texts already printed this run (real Display.warning dedups).
    @@warned_texts = Set(String).new

    # Core-emitted deprecation lines already printed this run (real
    # Display._deprecated dedups on the formatted message) and the
    # one-time "Deprecation warnings can be disabled" hint Ansible prints
    # before the first deprecation of a run - both shared across every
    # deprecation source, exactly like Ansible's Display state.
    @@deprecation_texts = Set(String).new
    @@deprecation_hint_seen = false

    # One core-side param deprecation (the module bootstrap's
    # removed_in_version warning, or a result's `_ansible_core_deprecations`
    # entry) on stderr - deduped per distinct text, with the one-time
    # "can be disabled" hint before the first one. Also called directly
    # from the argspec validator (a removed param deprecates when the
    # module's run returns - see validate's deprecation gate).
    def self.emit_core_deprecation(text : String) : Nil
      line = "[DEPRECATION WARNING]: #{text}"
      return unless @@deprecation_texts.add?(line)
      unless @@deprecation_hint_seen
        @@deprecation_hint_seen = true
        STDERR.puts "[WARNING]: Deprecation warnings can be disabled by setting `deprecation_warnings=False` in ansible.cfg.".colorize(:light_magenta)
      end
      STDERR.puts line.colorize(:light_magenta)
    end

    # An action-plugin warning raised while validating task args (the
    # service plugin's `Ignoring "X" as it is not used in "systemd"` for
    # its UNUSED_PARAMS): one console line per distinct message per run,
    # exactly like Ansible's Display.warning dedupe.
    @@action_warnings = Set(String).new

    def self.emit_action_warning(text : String) : Nil
      line = "[WARNING]: #{text}"
      return unless @@action_warnings.add?(line)
      STDERR.puts line.colorize(:light_magenta)
    end

    # A collection-redirect deprecation (community.mysql.<module> ->
    # ansible.mysql.<module>): one [DEPRECATION WARNING] console line per
    # distinct message per run through emit_core_deprecation, exactly like
    # Ansible's Display. nil module names (pseudo-tasks) and non-redirected
    # modules are no-ops.
    def self.emit_module_redirect_deprecation(module_name : String?) : Nil
      return unless module_name
      if text = Krikri::PlaybookParser.redirect_deprecation_text(module_name)
        emit_core_deprecation(text)
      end
    end

    # Removed-param deprecations whose stderr printing is deferred until
    # the module's actual outcome is known (stashed by the argspec
    # validator when validation passes - see its deprecation gate): real
    # carries the deprecation in the module RESULT, so an uncaught module
    # exception drops it while a normal or fail_json return shows it.
    # Keyed by module name; consumed (or dropped) at the result's display
    # point, the one place every task outcome passes through.
    @@pending_module_deprecations = Hash(String, Array(String)).new

    def self.stash_pending_module_deprecations(module_name : String, texts : Array(String)) : Nil
      return if texts.empty?
      held = @@pending_module_deprecations[module_name]?
      if held
        texts.each { |text| held << text unless held.includes?(text) }
      else
        @@pending_module_deprecations[module_name] = texts.dup
      end
    end

    # Emits the stashed removed-param deprecations for this module unless
    # the result says the module never ran (skip, unreachable, connection
    # failure) or died with an uncaught exception (Ansible's crash wrapper
    # drops the collected deprecations - live-verified vs 2.19.11 with
    # openssl_pkcs12's maciter_size). Consumes the stash either way.
    def self.consume_pending_module_deprecations(result : JSON::Any, module_name : String?) : Nil
      return if module_name.nil?
      pending = @@pending_module_deprecations.delete(module_name)
      return unless pending
      top = result.as_h?
      return if top.nil?
      return if top["skipped"]?.try(&.as_bool?)
      return if top["unreachable"]?.try(&.as_bool?)
      return if top["_connection_failure"]?.try(&.as_bool?)
      return if module_crash_result?(result)
      pending.each { |text| emit_core_deprecation(text) }
    end

    # The result shape of an uncaught module exception (the plugins'
    # module_crash_result/unhandled_error mimicry): Ansible's module wrapper
    # builds that result WITHOUT the deprecations the module bootstrap
    # collected, so `_ansible_core_deprecations` riding on it must not be
    # displayed (live-verified vs 2.19.11 with openssl_pkcs12's
    # maciter_size: the crash shows no [DEPRECATION WARNING] while the
    # same params' fail_json and success results do).
    def self.module_crash_result?(result : JSON::Any) : Bool
      return false unless Krikri.result_failed_flag(result)
      (result["msg"]?.try(&.as_s?) || "").starts_with?("Task failed: Module failed: ")
    end

    # Display task result with appropriate formatting.
    # item_label is set for looped tasks, rendering `ok: [host] => (item=x)`
    # to match how Ansible annotates per-iteration output.
    # source_task carries the task's parsed source position and module
    # identity so a failed result can render ansible-core 2.19's
    # `[ERROR]: Task failed:` block (see ErrorBlock) before the fatal/
    # failed line; nil (or a task without a parsed position) suppresses
    # the block.
    def self.display_result(host : Host, result : JSON::Any, diff_mode : Bool, item_label : String? = nil, ignore_errors : Bool = false, no_log : Bool = false, module_name : String? = nil, delegate_target : String? = nil, source_task : Task? = nil, loop_item : JSON::Any? = nil, loop_var_name : String? = nil) : Nil
      TimingProfile.measure("display.result", "display") do
        display_result_measured(host, result, diff_mode, item_label, ignore_errors, no_log, module_name, delegate_target, source_task, loop_item, loop_var_name)
      end
    end

    private def self.display_result_measured(host : Host, result : JSON::Any, diff_mode : Bool, item_label : String? = nil, ignore_errors : Bool = false, no_log : Bool = false, module_name : String? = nil, delegate_target : String? = nil, source_task : Task? = nil, loop_item : JSON::Any? = nil, loop_var_name : String? = nil) : Nil
      # A validation-passed removed-param deprecation waits for this
      # result to learn whether Ansible's module run would have shown it
      # (normal/fail_json return) or dropped it (uncaught crash, skip,
      # unreachable) - emit it before anything else this result prints.
      consume_pending_module_deprecations(result, module_name)

      # delegate_to: renders the host line as Ansible does:
      # `ok: [source -> target]` - the task ran against the delegate
      # target even though it reports under the play host.
      host_label = delegate_target ? "#{host.name} -> #{delegate_target}" : host.name
      changed = result["changed"]?.try(&.as_bool) || false
      failed = Krikri.result_failed_flag(result)
      # as_s? (not as_s): the debug action plugin keeps a whole-span
      # container msg natively (a real dict/list - see its own re-parse),
      # so a naive as_s cast crashes the whole display fiber on it.
      # A NON-STRING msg (fail's action puts the raw task arg in
      # result['msg'] - `fail: {msg: 50}` carries the int 50;
      # live-verified vs 2.19.11) renders through Python repr for the
      # [ERROR] block: the block is TEXT, the fatal dump below uses the
      # native result as-is.
      msg = result["msg"]?.try { |raw| raw.as_s? || ResultDisplay.python_repr(raw) } || ""

      # Core-emitted deprecations (a module's result carrying the
      # `_ansible_core_deprecations` marker - e.g. ansible.posix.mount's
      # `warnings`-in-exit_json deprecation) print on stderr BEFORE the
      # module-warnings block: Ansible emits the deprecation inside the
      # module's own _return_formatted, before any self.warn() calls it
      # makes afterwards. The formatted [DEPRECATION WARNING] line dedups
      # like every Display message, and the "Deprecation warnings can be
      # disabled" hint prints once per run before the first deprecation -
      # both live-verified against 2.19.11 with two mount tasks back to
      # back (second one silent). The marker itself is engine-internal
      # (stripped below, like the `_ansible_*` register strip) - the
      # result's real `deprecations` list stays untouched for register.
      # An uncaught module exception's result is the one shape that shows
      # nothing: Ansible's crash wrapper rebuilds the result without the
      # collected deprecations (see module_crash_result?).
      unless module_crash_result?(result)
        result["_ansible_core_deprecations"]?.try(&.as_a?).try &.each do |deprecation|
          text = deprecation.as_s? || deprecation.to_s
          emit_core_deprecation(text)
        end
      end

      # Module warnings (result["warnings"]) print as `[WARNING]: <text>` on
      # stderr BEFORE the status line, each distinct text once per run -
      # ansible's Display.warning dedups on the message (live-verified vs
      # 2.19.11 with find's "Skipped '<path>' path due to this access issue").
      result["warnings"]?.try(&.as_a?).try &.each do |warning|
        text = warning.as_s? || warning.to_s
        next unless @@warned_texts.add?(text)
        STDERR.puts "[WARNING]: #{text.strip}".colorize(:light_magenta)
      end
      emit_debug_template_error_warning(source_task, result)

      # Console lines a controller-side action plugin produced ITSELF
      # rather than through the result (pause's "Pausing for N seconds"
      # and its ctrl+C hint). Ansible's action plugin writes those with
      # Display.display() while the task is still running, so they always
      # land between the task's own output and this item's status line -
      # once per loop item, in iteration order. Displaying them here (the
      # per-item display point for both the plain and the LOOPED path)
      # reproduces that placement without the action plugin having to
      # write to the shared output stream, which would put every item's
      # banner ahead of the very first item's "ok:" on the looped path.
      result["_ansible_pause_console"]?.try(&.as_a?).try &.each do |line|
        puts line.as_s? || line.to_s
      end

      # Ansible's callback (CallbackBase._dump_results) drops these top-level
      # keys before any dump at verbosity < 3: `warnings`/`deprecations` are
      # only ever shown as their own [WARNING] lines, `invocation` is hidden
      # unless -vvv (getent-style results carry one for `register`). At -vvv
      # and above Ansible keeps all of them inside the dumps.
      if Krikri::RunOptions.verbosity < 3 && (top = result.as_h?) && (top.has_key?("warnings") || top.has_key?("invocation") || top.has_key?("deprecations") || top.has_key?("_ansible_core_deprecations") || top.has_key?("_ansible_pause_console"))
        result = JSON::Any.new(top.reject("warnings", "invocation", "deprecations", "_ansible_core_deprecations", "_ansible_pause_console"))
      end

      # no_log: print the status line and NOTHING else - no msg, no
      # stdout, no diff, no error detail. ansible-playbook shows
      # exactly `changed: [host]` / `ok: [host]` for such a task and
      # leaks nothing even under -v (verified against 2.19.4). This is a
      # security control, so it is applied before any other branch below
      # can print part of the result.
      if no_log
        # Ansible 2.19 DOES print the error block for a failed no_log task
        # (with the raw, uncensored message - an upstream leak), but
        # krikri deliberately does not replicate that leak: the block
        # would echo the secret this control exists to hide. Everything
        # else matches Ansible 2.19.11: a solo failed no_log task prints the
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
        # Ansible censors the loop item too under no_log - the item
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

      # A failed (non-loop) task's ansible-core 2.19 display is ONE
      # line: `fatal: [host]: FAILED! => {json}` with the whole result
      # JSON dumped sorted (live-verified: a command: failure shows
      # `fatal: [target]: FAILED! => {"changed": true, "cmd": [...],
      # "msg": "non-zero return code", "rc": 1, ...}`). The engine's old
      # display printed `failed: [host]` plus a separate `  Message:`
      # line - a different word AND a different shape than anything real
      # produces (found live via modules_systems.yml's wrong-checksum
      # rescue probe, where the recap-parity task-status diff flagged
      # fatal-vs-failed on the one failing task in the whole play).
      # Loop-item failures keep the loop display below unchanged - Ansible's
      # loop-failure line uses a different shape again
      # (`failed: [host] (item=X) => {json}`), and the engine's own
      # loop display (`failed: [host] => (item=X)` plus detail lines) is
      # a documented, deliberately-not-yet-matched cosmetic gap - so only
      # the NON-loop (no item_label) case takes the single-line dump.
      if failed && item_label.nil?
        # Ansible's stdout callbacks strip failed/skipped/_ansible_* before
        # dumping (as_callback_task_result), so the FAILED! dump carries
        # neither "failed": true nor any _ansible_* key.
        emit_task_error_block(source_task, result, msg)
        # Ansible 2.19.11's fatal dump has three shapes:
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
          dump = ResultDisplay.dump_suffix(JSON::Any.new({"msg" => JSON::Any.new(msg)}))
          puts "fatal: [#{host_label}]: FAILED! => #{dump}".colorize(:red)
        elsif result["_ansible_verbose_always"]?.try(&.as_bool) == true
          # A debug task's own failed result (failed_when:) dumps msg-ONLY
          # pretty (Ansible 2.19.11: {"msg": "fw"} - the verbose-always path
          # with debug's msg-only clean; live-verified) - the generic
          # clean kept changed/failed_when_result in the dump.
          cleaned = module_name.try(&.ends_with?("debug")) ? debug_clean_result(result) : clean_for_display(result)
          puts "fatal: [#{host_label}]: FAILED! => #{dump_pretty(cleaned)}".colorize(:red)
        else
          # Ansible's _dump_results flips to pretty (indent=4) for every dump
          # at -vvv, fatal lines included - not just the ok/changed ones.
          puts "fatal: [#{host_label}]: FAILED! => #{ResultDisplay.dump_suffix(clean_for_display(result))}".colorize(:red)
        end
        # ansible-playbook prints a bare "...ignoring" line right
        # after a failed task's output when ignore_errors: caught it
        # (live-verified against a real run) - the single-line dump above
        # replaced the old multi-line failure display, which carried this
        # suffix in its now-unreachable tail, so it has to be re-emitted
        # here or ignored non-loop failures silently lose it.
        puts "...ignoring".colorize(:red) if ignore_errors
        return
      end

      # Loop-item failures: Ansible's shape is a single line per failed item,
      # `failed: [host] (item=X) => {json}` (item BEFORE the `=>`, the whole
      # result dumped inline sorted), with `...ignoring` printed ONCE after
      # the whole loop rather than per item (finish_looped_task owns that).
      # The old path printed `failed: [host] => (item=X)` plus a `  Message:`
      # /`  Exit code:` detail block and a per-item `...ignoring` - a
      # different word-order, extra lines, and repeated suffix vs real.
      if failed && !item_label.nil?
        # Ansible's default callback runs its exception handling (the error
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
        # Ansible's strategy merges the loop item itself into every per-item
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

      # Ansible appends the full result JSON (pretty, 4-space indent,
      # sorted keys) to the status line when the run is verbose OR the
      # result carries _ansible_verbose_always (the debug and assert
      # action plugins tag their results that way). At default verbosity
      # without the tag, Ansible prints ONLY the status line - never a msg
      # body - so the engine's old `  msg` display for successful tasks
      # is gone: a non-verbose success shows just `ok: [host]`.
      verbose_always = !failed &&
                       result["_ansible_verbose_always"]?.try(&.as_bool) == true &&
                       result["_ansible_verbose_override"]?.try(&.as_bool) != true

      # Ansible's callback prints a file diff BEFORE the task's own status
      # line (live-verified against 2.19.11: diff block, blank, `changed:
      # [host]`), so the diff prints here, ahead of every status branch
      # below; the trailing blank line inside display_diff separates it
      # from the status line.
      if diff_mode && result["diff"]?
        display_diff(result["diff"])
      end

      if verbose_always
        cleaned = module_name.try(&.ends_with?("debug")) ? debug_clean_result(result) : clean_for_display(result)
        puts "#{status}: [#{host_label}]#{suffix} => #{dump_pretty(cleaned)}"
      elsif Krikri::RunOptions.verbosity >= 1
        # Real -v/-vv appends the whole (cleaned) result as a single-line
        # sorted JSON dump to every ok/changed status line; at -vvv and
        # above the dump flips to Ansible's pretty 4-space-indented shape.
        # A looped item's dump carries the merged loop keys
        # (ansible_loop_var + the item under the loop var's name), same
        # as the failed-item path below.
        cleaned = clean_for_display(result)
        if item_label && (item = loop_item)
          h = cleaned.as_h.try(&.dup) || Hash(String, JSON::Any).new
          var_name = loop_var_name.try { |name| !name.empty? ? name : nil } || "item"
          h["ansible_loop_var"] = JSON::Any.new(var_name)
          h[var_name] = item
          cleaned = JSON::Any.new(h)
        end
        dump = Krikri::RunOptions.verbosity >= 3 ? dump_pretty(cleaned) : ResultDisplay.python_json_dump(cleaned)
        puts "#{status}: [#{host_label}]#{suffix} => #{dump}"
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
        # just absent) - Ansible's chdir-before-execution failure
        # fails the module with rc: null (its run_command never spawned
        # anything, live-verified against 2.19.4), and `.as_i` on a
        # JSON null hard-crashed the whole engine here where
        # ansible-playbook simply omits the Exit code line.
        if rc_value = result["rc"]?
          unless rc_value.raw == nil
            puts "  Exit code: #{rc_value.as_i}".colorize(:red)
          end
        end

        # ansible-playbook always prints a bare "...ignoring" line
        # right after a failed task's own output when ignore_errors:
        # caught it - verified directly against a ansible-playbook
        # run. This was previously never printed at all for a normal
        # ignored failure (only added, narrowly, for the when:-raises-
        # an-exception case - see WhenEvaluationError's own history);
        # fixed here so every ignored failure gets it, matching
        # Ansible regardless of why the task failed.
        puts "...ignoring".colorize(:red) if ignore_errors
      end
    end

    # Builds and prints ansible-core 2.19's `[ERROR]: Task failed:`
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
      if (idx = result["_ansible_that_index"]?.try(&.as_i64?)) &&
         (msg.starts_with?("Task failed: Error while evaluating conditional") ||
         msg.starts_with?("Task failed: Syntax error in expression"))
        emit_assert_that_chain(source_task, msg["Task failed: ".size..], idx.to_i)
        return
      end
      return if msg.includes?("Error while evaluating conditional")
      # Non-boolean conditional failures are likewise emitted by
      # emit_when_error_chain (with the when: value's own Origin); a
      # second block here would duplicate it wrapped in a bogus
      # "Module failed:" segment. The compile-time filter/test-name
      # wording is the same story (conditional_evaluation_failure?
      # now recognizes it there).
      return if msg.includes?("Conditional result") ||
                msg.includes?("Syntax error in expression")

      origin = error_origin_context(source_task)
      return unless origin

      # A fail_json(exception=ex) result (Ansible 2.19 composes its error
      # header as "<msg>: <exception str>" from the ErrorSummary chain,
      # while the dumped result keeps the bare msg and drops the
      # exception key entirely). Krikri plugins signal this with a
      # real exception text under the `exception` key - the
      # "(traceback unavailable)" placeholder base_plugin injects when
      # no exception was passed is NOT part of the chain in real
      # (fail_json only builds an ErrorSummary for an actual
      # exception), so it is ignored here.
      if (exc = result["exception"]?.try(&.as_s?)) && !exc.empty? &&
         exc != "(traceback unavailable)"
        # Ansible's own _text_utils.concat_message (ported on ErrorBlock)
        # strips a trailing ". " from the left side - "Error, could not
        # touch target." + "[Errno 20] ..." collapses to "...target: [Errno 20] ...".
        msg = ErrorBlock.concat_message(msg, exc)
      end
      # A plugin whose block text differs from the fatal msg (fetch's slurp
      # failure) hands the block its own text via _ansible_error_detail.
      msg = result["_ansible_error_detail"]?.try(&.as_s?) || msg
      # failed_when: turned an otherwise successful module result into a
      # failure: Ansible's block is just "Task failed: Action failed."
      if result["failed_when_result"]?.try(&.as_bool?) == true && result["msg"]?.try(&.as_s?).to_s.empty?
        root = ErrorBlock::Node.new("Task failed.", source_context: origin)
        ErrorBlock.emit(root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new("Action failed.")))
        return
      end
      # A failed result carrying _ansible_fail_param names the task param
      # whose VALUE Ansible's action plugin attached as the raise's obj
      # (add_host's "Groups must be specified as a list." AnsibleActionFail):
      # the chain cannot collapse - Ansible's cause event carries the param
      # value's own Origin, producing the two-segment block with the
      # brief "Task failed: <msg>." header line.
      if (fail_param = result["_ansible_fail_param"]?.try(&.as_s?)) &&
         (param_origin = task_param_value_origin(source_task, fail_param))
        root = ErrorBlock::Node.new("Task failed.", source_context: origin)
        cause = ErrorBlock::Node.new(msg, source_context: param_origin)
        ErrorBlock.emit(root.with_chain(ErrorBlock::DIRECT_CAUSE, true, cause))
        return
      end
      # A plugin flagging _ansible_action_level failed in Ansible's controller-
      # side ACTION plugin (a bare AnsibleActionFail: no "Module failed."
      # middle segment), e.g. assemble's remote_src: false isdir() check.
      # _ansible_error_origin additionally points the CAUSE segment at the
      # file the crash happened in (Ansible's event source context comes
      # from the offending value's own origin tag): template:'s
      # `#jinja2:` directive TypeError reports against the TEMPLATE file,
      # with no line/column (round 1500121, apolloclark.packetbeat).
      if result["_ansible_action_level"]?.try(&.as_bool?) == true
        root = ErrorBlock::Node.new("Task failed.", source_context: origin)
        cause = ErrorBlock::Node.new(msg)
        if (crash_path = result["_ansible_error_origin"]?.try(&.as_s?)) && !crash_path.empty?
          cause.source_context = "Origin: #{crash_path}"
        end
        ErrorBlock.emit(root.with_chain(ErrorBlock::DIRECT_CAUSE, true, cause))
        return
      end
      # set_fact's validate_variable_name failure: Ansible's cause carries
      # the invalid key's own Origin (the mapping key inside the task)
      # plus a fixed help_text paragraph, so the chain cannot collapse.
      if (match = msg.match(/\ATask failed: Invalid variable name '(.*)'\.\z/)) &&
         source_task.module_name.try { |name| name.split(".").last } == "set_fact"
        key = match[1]
        inner = "Invalid variable name '#{key}'."
        root = ErrorBlock::Node.new("Task failed.", source_context: origin)
        if key_origin = set_fact_key_origin(source_task, key)
          cause = ErrorBlock::Node.new(inner, source_context: key_origin,
            help_text: "Variable names must be strings starting with a letter or underscore character, and contain only letters, numbers and underscores.")
        else
          cause = ErrorBlock::Node.new(inner)
        end
        ErrorBlock.emit(root.with_chain(ErrorBlock::DIRECT_CAUSE, true, cause))
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
            dash = item_line.index!("- ")
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

    # Origin context of a set_fact mapping key named `key`: the key's own
    # line/column inside the task, found by scanning the task's source
    # lines for the key followed by ':' (a quoted key points at the
    # opening quote, like Ansible's per-key Origin).
    private def self.set_fact_key_origin(task : Task, key : String) : String?
      path = task.source_file
      return nil unless path && task.source_line > 0 && File.file?(path)

      lines = File.read_lines(path)
      # A QUOTED key carries its colon AFTER the closing quote
      # (`"bad-name": 1`), so a bare "<key>:" needle never matches it -
      # Ansible still points its per-key Origin at the opening quote, and at
      # the same column as the bare form (live-verified vs 2.19.11: both
      # `bad-name: 1` and `"bad-name": 1` give column 9 on an
      # 8-space-indented line). Match whichever spelling occurs first.
      needles = {"\"#{key}\":", "'#{key}':", "#{key}:"}
      ((task.source_line - 1)...lines.size).each do |idx|
        line = lines[idx]
        at = needles.compact_map { |needle| line.index(needle) }.min?
        next unless at
        # only a mapping key: nothing but whitespace before it
        next unless line[0...at].strip.empty?
        return ErrorBlock.origin_context(path, idx + 1, at + 1)
      end
      nil
    end

    # The Origin of a task param's VALUE (the position Ansible's
    # AnsibleActionFail obj= attaches as the failing event's source
    # context - e.g. add_host's `groups: 5` points at the 5, column of
    # the value, not the key). Same best-effort text scan as
    # set_fact_key_origin above, but the caret lands on the first
    # non-space character after `key:`.
    private def self.task_param_value_origin(task : Task, key : String) : String?
      path = task.source_file
      return nil unless path && task.source_line > 0 && File.file?(path)

      lines = File.read_lines(path)
      needle = "#{key}:"
      ((task.source_line - 1)...lines.size).each do |idx|
        line = lines[idx]
        at = line.index(needle)
        next unless at
        prefix = line[0...at]
        # only a mapping key: nothing but whitespace/quotes before it
        stripped = prefix.strip
        next unless stripped.empty? || (stripped.size == 1 && {"'", '"'}.includes?(stripped))
        col = at + needle.size
        while col < line.size && line[col] == ' '
          col += 1
        end
        return ErrorBlock.origin_context(path, idx + 1, col + 1)
      end
      nil
    end

    private def self.error_origin_context(task : Task) : String?
      path = task.source_file
      return nil unless path && task.source_line > 0
      ErrorBlock.origin_context(path, task.source_line, task.source_col > 0 ? task.source_col : nil)
    end

    # The cause chain ansible-core 2.19 builds for each failure
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
    #   carrying Ansible's exact wording.
    # - every other module-level failure: "Module failed." + the result
    #   message (the module API's own wrapper), collapsed.
    private def self.task_error_chain(module_name : String?, msg : String, origin : String) : ErrorBlock::Node
      root = ErrorBlock::Node.new("Task failed.", source_context: origin)

      # set_fact's strict cacheable: conversion failure (a plain
      # convert_bool TypeError - no result contribution, no handling
      # chain): the fatal msg is the whole collapsed-chain brief and the
      # block is the single collapsed segment carrying the raw error.
      if msg.starts_with?("Task failed: The value '") &&
         msg.includes?(" is not a valid boolean. Valid booleans include: ") &&
         module_name.try { |name| name.split(".").last } == "set_fact"
        return root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg["Task failed: ".size..]))
      end

      # An argspec-validation failure we emitted has Ansible's own chain
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
        # Ansible's template action plugin raises AnsibleActionFail
        # directly for every arg-validation failure (state/src+dest/
        # newline_sequence) - a bare raise, no exception context, so
        # Ansible's renderer COLLAPSES the chain into one segment. Only the
        # _find_needle failure is re-raised inside `except` (its
        # AnsibleFileNotFound becomes the __context__), producing the
        # two-segment handling chain (live-verified against 2.19.11:
        # newline_sequence: 15 collapses, a missing relative src does
        # not).
        if msg.starts_with?("Could not find or access '")
          root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg).with_chain(ErrorBlock::HANDLING, false, ErrorBlock::Node.new(msg)))
        else
          root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg))
        end
      when "set_fact"
        # Ansible's set_fact action plugin raises AnsibleActionFail
        # directly (no key/value pairs) - bare action-level failure,
        # collapsed chain, no middle segment.
        root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg))
      when "unarchive"
        # Ansible's unarchive action raises a non-contributing AnsibleError
        # for a controller-side src miss (live-verified: the fatal msg
        # carries the "Task failed: " brief prefix itself and the block
        # is the single collapsed segment).
        inner = msg.starts_with?("Task failed: ") ? msg["Task failed: ".size..] : msg
        root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(inner))
      when "script"
        if msg.starts_with?("Could not find or access '")
          # script:'s controller-side src miss: real re-raises the
          # loader's file-not-found inside `except` - the same two-segment
          # handling chain as template's (live-verified against 2.19.11).
          root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg).with_chain(ErrorBlock::HANDLING, false, ErrorBlock::Node.new(msg)))
        else
          root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new("Module failed.").with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg)))
        end
      when "fail", "assert", "debug"
        # debug's failed_when rejection is an ACTION-level failure in real
        # ("Task failed: Action failed: fw", live-verified vs 2.19.11) -
        # the action plugin owns the whole result.
        root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new("Action failed.").with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg)))
      else
        # copy:'s controller-side src miss (both the remote-host variant,
        # whose fatal msg carries the "Task failed: " brief prefix, and
        # the local-connection variant, whose fatal msg carries the
        # "Unexpected AnsibleActionFail error: " prefix itself - both
        # live-verified): the chain is the collapsed
        # "Unexpected AnsibleActionFail error." shape carrying Ansible's
        # full not-found text (now including the Searched-in list).
        if (msg.starts_with?("Task failed: Could not find or access '") ||
           msg.starts_with?("Unexpected AnsibleActionFail error: Could not find or access '")) &&
           msg.includes?("see the remote_src option")
          not_found = msg.sub(/\A(?:Task failed: |Unexpected AnsibleActionFail error: )/, "")
          root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new("Unexpected AnsibleActionFail error.").with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(not_found)))
        elsif module_name.try(&.ends_with?(".copy")) &&
              {"src and content are mutually exclusive", "src (or content) is required", "dest is required"}.includes?(msg)
          # copy's action-level src/content conflict (raised before
          # argspec validation, ordering live-verified against 2.19.11):
          # Ansible's chain is the action-level "Action failed." shape.
          root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new("Action failed.").with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg)))
        else
          root.with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new("Module failed.").with_chain(ErrorBlock::DIRECT_CAUSE, true, ErrorBlock::Node.new(msg)))
        end
      end
    end

    # Display an ad-hoc `ansible` command's result, matching
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
    # -o/--one-line switches to Ansible's deprecated `oneline`
    # callback shape - everything on ONE line: command-shaped results
    # render as `host | STATUS | rc=N | (stdout) ...` with newlines
    # escaped (verified against ansible-core 2.19.4's
    # plugins/callback/oneline.py), everything else renders the result
    # JSON compact (indent=0, newlines stripped) instead of pretty.
    # There is no krikri-playbook equivalent to mirror - the playbook CLI
    # has no -o.
    class_property? adhoc_oneline : Bool = false

    # -t/--tree DIR: additionally log each result as pretty JSON in
    # DIR/<hostname>, like Ansible's tree callback plugin.
    class_property adhoc_tree_dir : String? = nil

    # Ansible's ad-hoc ("minimal" and "oneline") callbacks pass the
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
    # Ansible's minimal/oneline callbacks: unreachable wins over
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

      connection_host = host.name

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
        # color (Ansible does NOT color stderr separately here).
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

    # The exact JSON string Ansible's ad-hoc stdout callbacks dump
    # after the `host | STATUS => ` prefix. The result dict the callbacks
    # see has already been through Ansible's cleaning pipeline by
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

    # Ansible strips `failed`/`skipped` and every private `_ansible_*`
    # key from the callback-visible result, recursively
    # (executor/task_result.py's _IGNORE + vars/clean.py's
    # strip_internal_keys).
    private def self.clean_for_display(value : JSON::Any, top_level : Bool = true) : JSON::Any
      case raw = value.raw
      when Hash
        cleaned = Hash(String, JSON::Any).new
        raw.each do |key, v|
          # `failed`/`skipped` only leave the TOP-level result (a registered
          # skipped result printed via debug var: keeps its nested `skipped`)
          next if top_level && (key == "failed" || key == "skipped" || key == "exception")
          # Ansible's callback POPS `diff` out of every result before dumping
          # (it renders as the diff section only, and only in diff mode) -
          # status-line dumps must never carry it. Registered variables
          # keep their `diff` key (a check-mode template result registers
          # "diff": []), and those go through debug_clean_result instead.
          next if top_level && key == "diff"
          next if key.starts_with?("_ansible_")
          cleaned[key] = clean_for_display(v, false)
        end
        JSON::Any.new(cleaned)
      when Array
        JSON::Any.new(raw.map { |item| clean_for_display(item, false) })
      else
        value
      end
    end

    # Ansible's CallbackBase._clean_results for a debug action, run
    # before the verbose dump: a msg: result keeps ONLY msg (plus keys
    # Ansible's own pipeline strips later - failed/skipped/_ansible_* are
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

    # Display diff (delegates to specific diff types). Ansible's callback
    # prints a file diff BEFORE the task's status line - the diff block,
    # one blank line, then `changed: [host]` (live-verified 2.19.11) -
    # and starts it immediately after the TASK banner with no leading
    # blank of its own.
    def self.display_diff(diff : JSON::Any) : Nil
      # lineinfile's diff is a LIST of diff dicts (content entry + a file
      # attributes entry); an empty list (a no-change run) renders
      # nothing, like Ansible's callback skipping the empty diff.
      if (arr = diff.as_a?)
        arr.each { |entry| display_diff_entry(entry) }
      else
        display_diff_entry(diff)
      end
    end

    def self.display_diff_entry(diff : JSON::Any) : Nil
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

    # Display attribute diff (for file attributes like mode, owner).
    # Ansible's callback renders a DICT diff exactly like a content diff:
    # both sides are pretty-printed as sorted 4-space-indented JSON and
    # fed through the unified differ (live-verified vs 2.19.11 --diff:
    # `--- before` / `+++ after` / `@@ -1,5 +1,5 @@` with the JSON lines
    # as +/-/context), not a per-key `- key: value` listing.
    def self.display_attribute_diff(diff : JSON::Any) : Nil
      puts "--- before".colorize(:red).bold
      puts "+++ after".colorize(:green).bold

      show_unified_diff(python_pretty_json(diff["before"]), python_pretty_json(diff["after"]))
      puts ""
    end

    # Python's json.dumps(obj, sort_keys=True, indent=4): sorted keys,
    # 4-space indent, ": " separators, trailing newline (Ansible's
    # difflib-based renderer feeds it both sides with trailing
    # newlines - no "\ No newline at end of file" markers ever appear).
    def self.python_pretty_json(value : JSON::Any) : String
      String.build do |io|
        pretty_json_write(value, io, 0)
      end
    end

    private def self.pretty_json_write(value : JSON::Any, io : IO, depth : Int32) : Nil
      pad = "    " * (depth + 1)
      close_pad = "    " * depth
      case raw = value.raw
      when Hash
        io << "{\n"
        raw.keys.sort.each_with_index do |key, idx|
          io << pad << key.to_json << ": "
          pretty_json_write(raw[key], io, depth + 1)
          io << ",\n" if idx < raw.size - 1
        end
        io << "\n" << close_pad << "}"
      when Array
        io << "[\n"
        raw.each_with_index do |item, idx|
          io << pad
          pretty_json_write(item, io, depth + 1)
          io << ",\n" if idx < raw.size - 1
        end
        io << "\n" << close_pad << "]"
      when Nil
        io << "null"
      when Bool
        io << raw.to_s
      when String
        io << raw.to_json
      else
        io << raw.to_s
      end
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
        # Ansible's own recap counters overlap, not mutually
        # exclusive: "ok" counts every successful task (changed or not),
        # and "changed" is a separate tally on top of that - verified
        # against a ansible-playbook run (ok=3, changed=2 for 2
        # changed + 1 unchanged successful tasks), not assumed.
        stats["ok"] += 1
        stats["changed"] += 1 if changed

        # A task that failed but was caught by ignore_errors: still
        # increments "ok" (and "changed") above - Ansible's own
        # strategy/__init__.py does the exact same `increment('ok', ...)`
        # + `increment('ignored', ...)` pair for this case (verified
        # against its source, not assumed) - but it ALSO increments a
        # separate "ignored" counter alongside, which this recap had no
        # key for at all until now.
        stats["ignored"] += 1 if failed && ignore_errors
      end
    end

    # Show recap of all host results, matching ansible-playbook's
    # v2_playbook_on_stats byte-for-byte: host column padded to 26 plain
    # (37 when colorized, padding applied AROUND the ANSI-wrapped name
    # the way Ansible's `%-37s` does), then " : ", then the seven counters
    # each shaped `lead=%-4s` and joined with single spaces - so every
    # counter carries trailing padding, including the last one.
    def self.show_recap(hosts : Array(Host), results : Hash(String, Hash(String, Int32))) : Nil
      # Sorted by host name, matching ansible-playbook - this used
      # to print in inventory order, so a recap for db1/web1/web2 came
      # out web1, web2, db1 and could not be diffed against a real run.
      hosts.sort_by(&.name).each do |host|
        # A host can reach the recap with no results at all: krikri-playbook.cr
        # adds every play's hosts to the recap list *before* deciding
        # whether the play has any tasks to run, so a playbook whose plays
        # are all skipped (no tasks, or none matching --tags) used to crash
        # here with `Missing hash key`. Zeroes are the honest recap for a
        # host nothing ran on - but such a host is then left out of the printout
        # (see the all-zero check below), like ansible-playbook.
        stats = results[host.name]? || {
          "ok" => 0, "changed" => 0, "unreachable" => 0, "failed" => 0, "skipped" => 0, "rescued" => 0, "ignored" => 0,
        }

        unreachable = stats["unreachable"]? || 0
        skipped = stats["skipped"]? || 0
        rescued = stats["rescued"]? || 0
        ignored = stats["ignored"]? || 0

        # Ansible only lists a host once some counter for it is non-zero: a play
        # with no tasks, a --tags filter that matches nothing, or nothing but
        # meta tasks (which record no stats) leaves the recap without that
        # host's line, while a `when: false` task (skipped=1) still prints one.
        next if [stats["ok"]? || 0, stats["changed"]? || 0, unreachable, stats["failed"]? || 0, skipped, rescued, ignored].all?(&.zero?)

        # Ansible's colorize(lead, num, color) shapes `lead=%-4s` and colors
        # the WHOLE field only when num != 0 (zero counters stay plain
        # even on a tty). rescued shares ok's green, ignored shares
        # changed's warning color - both per Ansible's own v2_playbook_on_stats.
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
                       # Ansible's hostcolor colored branch pads the ANSI-wrapped name to
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

    # Serializes *result* the way Ansible dumps a failed task's JSON:
    # keys sorted alphabetically at every level, single line, Python's
    # json.dumps default separators (", " between items, ": " after keys).
    def self.python_json_dump(result : JSON::Any) : String
      python_json_value(result)
    end

    # Python's repr() of a value, matching how Ansible renders a loop
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
