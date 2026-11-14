require "json"
require "colorize"
require "../host"
require "../playbook_parser"
require "./result_display"

module Krikri
  # HandlerRunner - Manages handler notification and execution
  # Handlers are notified during task execution and run at the end of the play
  class HandlerRunner
    property handlers : Array(Task)
    property hosts : Array(Host)

    # Track which handlers have been notified for each host
    @notified_handlers : Hash(String, Set(String))

    # True while #run's handler flush is executing - suppresses the
    # "Notification for handler ... has been saved." -vv line for
    # notifications raised by handlers themselves (Ansible only prints it
    # for regular-task results).
    @in_flush = false

    # Flush-time state used to attach notifications raised WHILE the
    # flush is running (a handler notifying another handler) to the
    # handler copy they execute on - see #attachments_for_notification.
    # Per host, the precomputed per-handler rendered names (empty for an
    # unusable handler - its name must never even be resolved, see
    # TaskExecutor#run_handlers).
    @flush_attachments : Hash(String, Set(Int32))? = nil
    @flush_rendered_names : Hash(String, Array(String))? = nil
    @flush_name_resolver : Proc(Task, Host, String)? = nil
    @flush_unusable_handlers : Set(Task)? = nil

    def initialize(@handlers : Array(Task), @hosts : Array(Host))
      @notified_handlers = Hash(String, Set(String)).new

      @hosts.each do |host|
        @notified_handlers[host.name] = Set(String).new
      end
    end

    # Notify a handler (by name or listen topic)
    # Handlers can be notified multiple times but only run once
    def notify(host : Host, handler_name : String) : Nil
      @notified_handlers[host.name].add(handler_name)
      # Ansible's strategy prints this (display.vv) per notification saved
      # from a REGULAR task's result - but not from within the handlers
      # phase itself, where the notification applies immediately instead.
      if !@in_flush && Krikri::RunOptions.verbosity >= 2
        puts "Notification for handler #{handler_name} has been saved."
      elsif @in_flush && (attachments = @flush_attachments) && (rendered_names = @flush_rendered_names) && (resolver = @flush_name_resolver)
        # A notification raised by a handler DURING the flush attaches
        # immediately to the copy it will run on (Ansible's strategy
        # processes notifications in the HANDLERS state the same way) -
        # without this, a handler notifying one still AHEAD in definition
        # order would never become eligible and its target would only
        # ever run through the backward-notification second pass.
        attachments[host.name].concat(
          attachments_for_notification(host, handler_name, rendered_names[host.name], resolver, @flush_unusable_handlers))
      end
    end

    # Check if any handlers were notified
    def any_notified? : Bool
      @notified_handlers.values.any?(&.size.> 0)
    end

    # Clears every host's notified-handler set, so a subsequent #run
    # call (from a later `meta: flush_handlers`, or the final end-of-
    # play flush) only picks up handlers notified SINCE the last flush,
    # not ones already run. Ansible's own flush_handlers has this
    # same "only runs what's still pending" semantics - a handler
    # already flushed once doesn't run a second time just because the
    # end-of-play flush also fires.
    def clear_notified! : Nil
      @hosts.each { |host| @notified_handlers[host.name].clear }
    end

    # Run all notified handlers
    # Handlers run in the order they are defined, not the order they were notified
    # This matches Ansible behavior
    #
    # *name_resolver* renders a handler's own `name:` against its real
    # vars_context (mirrors TaskExecutor#render_task_name_for_display -
    # HandlerRunner has no vars_context machinery of its own, so this is
    # threaded in the same way *execute_callback* already is). Needed
    # because a role-loaded handler's name is frequently itself a
    # template (`prometheus.prometheus`'s own `_common` role:
    # `name: "Restart {{ _common_service_name }}"`) - matching against
    # the raw, unrendered `handler.name` (as this used to) never equals
    # any real notify: string.
    # *ignore_errors_resolver* resolves a handler's (possibly templated)
    # `ignore_errors:` against its real scope, threaded the same way
    # (mirrors TaskExecutor#resolve_task_ignore_errors): a failing
    # handler caught by it must print "...ignoring" and count ok +
    # ignored in the recap, never failed (issue #1112) - the same
    # resolution execute_handler_internal's own halt decision uses, so
    # display, stats and halting can never disagree.
    # *halted_hosts* - hosts a prior task already failed on (unrescued,
    # no ignore_errors:) for this run. Ansible never runs a
    # halted host's own notified handlers at the end-of-play flush -
    # once a host is out, it's out entirely, handlers included.
    # Previously unfiltered: @hosts.each below ran unconditionally, so
    # a host whose LAST regular task failed (round 83's
    # robertdebock.keepalived: "Start keepalived" times out and halts
    # the host) still ran its own previously-notified "Restart
    # keepalived" handler at the implicit end-of-play flush, since
    # that flush happens after halt_if_failed already halted the host
    # but before this method had any way to know. Ansible shows
    # exactly one failure (the halting task); krikri-playbook showed
    # two (the halting task, then the handler that should never have
    # run).
    def run(
      execute_callback : Proc(Task, Host, JSON::Any),
      results : Hash(String, Hash(String, Int32)),
      diff_mode : Bool,
      name_resolver : Proc(Task, Host, String)? = nil,
      halted_hosts : Set(String)? = nil,
      unusable_handlers : Set(Task)? = nil,
      ignore_errors_resolver : Proc(Task, Host, Bool)? = nil,
    )
      return unless any_notified?

      bannered = Set(Int32).new
      @in_flush = true

      # Attach every pending notification to the handler COPY it will
      # actually run on, resolved the way Ansible resolves notifications
      # at flush time (search_handlers_by_notification): execution is
      # still forward definition order, but a notification attaches to
      # the LAST handler matching its name ("last handler loaded with
      # the same name wins"), and, via the separate listen: loop, to the
      # last definition of each distinct handler name whose listen:
      # covers it. Matching the FIRST copy instead made the wrong copy
      # run whenever a role's handlers exist twice - loaded statically
      # as a dependency AND again through a later include_role: (issue
      # #804, 0x0i.geth: the dependency copy of "Reload systemd units"
      # sits before geth's own "Restart Geth service" in the handler
      # list while the include_role copy lands after it, so matching the
      # first copy ran "Reload systemd units" before "Restart Geth
      # service" where ansible ran them the other way around).
      attachments = Hash(String, Set(Int32)).new
      rendered_names = Hash(String, Array(String)).new
      @hosts.each do |host|
        targets = Set(Int32).new
        per_host_names = @handlers.map do |handler|
          if unusable_handlers.try(&.includes?(handler))
            ""
          else
            name_resolver.try(&.call(handler, host)) || handler.name
          end
        end
        rendered_names[host.name] = per_host_names
        @notified_handlers[host.name].each do |notification|
          targets.concat(attachments_for_notification(host, notification, per_host_names, name_resolver, unusable_handlers))
        end
        attachments[host.name] = targets
      end
      @flush_attachments = attachments
      @flush_rendered_names = rendered_names
      @flush_name_resolver = name_resolver
      @flush_unusable_handlers = unusable_handlers

      # A handler runs at most once per host, no matter how many times
      # it was notified - and, since include_role: (possibly looped) can
      # dynamically add further Task objects that happen to share a name
      # with an existing handler (e.g. the same role included twice),
      # no matter how many distinct Task objects share that name either.
      already_ran = Hash(String, Set(String)).new
      @hosts.each { |host| already_ran[host.name] = Set(String).new }

      # Handlers run in definition order. A handler notified by another
      # handler that sits EARLIER in that order has already been passed
      # by the time the notification lands, so Ansible makes ONE
      # further pass for those - and exactly one: notifications raised
      # during that second pass are dropped when the flush ends.
      # Verified against ansible-core 2.19.4: a handler notifying an
      # earlier one runs "H2 H1"; a self-notifying handler runs exactly
      # TWICE; a backward chain C->B->A runs "C B" and never reaches A.
      # Names that must run again in the second pass: a handler is only
      # eligible if it was notified AFTER it had already been reached in
      # pass one. A notification for a handler still AHEAD in definition
      # order is picked up by pass one itself and must not run twice
      # ("first" notifying "second" runs H1 H2, not H1 H2 H2).
      second_pass = Hash(String, Set(String)).new
      @hosts.each { |host| second_pass[host.name] = Set(String).new }

      2.times do |pass|
        @handlers.each_with_index do |handler, handler_index|
          next if unusable_handlers.try(&.includes?(handler))
          @hosts.each do |host|
            run_handler_on_host(handler, handler_index, host, pass,
              execute_callback, results, diff_mode, name_resolver, halted_hosts,
              ignore_errors_resolver, attachments[host.name], already_ran[host.name],
              second_pass[host.name], bannered)
          end
        end

        # Anything notified during the SECOND pass is discarded, matching
        # Ansible - so the loop is bounded at two passes regardless
        # of how handlers notify each other.
        break if pass == 1
      end

      @in_flush = false
      @flush_attachments = nil
      @flush_rendered_names = nil
      @flush_name_resolver = nil
      @flush_unusable_handlers = nil
      clear_notified!
    end

    # Runs *handler* on *host* for *pass* if eligible; returns true when
    # the handler actually triggered (for the blank-line display after a
    # handler that ran on at least one host).
    private def run_handler_on_host(handler : Task, handler_index : Int32, host : Host,
                                    pass : Int32,
                                    execute_callback : Proc(Task, Host, JSON::Any),
                                    results : Hash(String, Hash(String, Int32)),
                                    diff_mode : Bool,
                                    name_resolver : Proc(Task, Host, String)?,
                                    halted_hosts : Set(String)?,
                                    ignore_errors_resolver : Proc(Task, Host, Bool)?,
                                    attached : Set(Int32),
                                    already_ran : Set(String),
                                    second_pass : Set(String),
                                    bannered : Set(Int32)) : Bool
      return false if halted_hosts.try(&.includes?(host.name))

      rendered_name = name_resolver.try(&.call(handler, host)) || handler.name

      return false unless eligible_this_pass?(pass, handler_index, rendered_name,
                            attached, already_ran, second_pass)
      already_ran.add(rendered_name)

      # ansible reaches VariableManager.get_vars for a handler only when
      # a flush actually runs it, so its parse-time reserved-name warning
      # prints here (issue #473) - once per Task object, never for a
      # handler nothing notified.
      if text = handler.pending_reserved_warning
        handler.pending_reserved_warning = nil
        STDERR.print text
      end

      # Display-only role prefix (verified live against
      # ansible-core 2.19.12: "RUNNING HANDLER [myrole : my
      # handler]") - reads handler.role_name directly rather
      # than folding into rendered_name, which
      # should_run_handler?/eligible_this_pass? also use for
      # notify: MATCHING; prefixing that shared value would
      # make a plain `notify: my handler` stop matching a
      # role handler's own bare notified name.
      role_prefix = (rn = handler.role_name) ? "#{rn} : " : ""
      print_handler_display(handler, handler_index, rendered_name, host, bannered, role_prefix)

      # Execute handler using the callback
      result = execute_callback.call(handler, host)

      # Anything this handler notified that sits at or BEFORE its
      # own position has already been passed, so it needs the
      # second pass. Collected during pass one only -
      # Ansible drops notifications raised during the second.
      if pass == 0 && (result["changed"]?.try(&.as_bool?) == true)
        # Read from the handler's OWN notify: list rather than
        # diffing @notified_handlers - that is a Set, so a
        # handler re-notifying something already notified (most
        # obviously itself) changes nothing there and the
        # re-notification would be invisible.
        handler.notify.try &.each do |raised|
          # Match against each candidate's RENDERED name (same resolver
          # everything else here matches with), not the raw handler.name:
          # the whole reason name_resolver exists is that a role-loaded
          # handler's name is frequently itself a template, so a handler
          # notifying an earlier handler BY that rendered name (the exact
          # case this backward-notification pass exists for) never found
          # its target and silently didn't fire the second pass.
          index = @handlers.index do |candidate|
            rendered_candidate = name_resolver.try(&.call(candidate, host)) || candidate.name
            rendered_candidate == raised || candidate.name == raised
          end
          second_pass.add(raised) if index && index <= handler_index
        end
      end

      # A handler whose own `when:` evaluated false already
      # printed its own "skipping: [host]" line inside
      # execute_handler_internal (mirroring a regular task's
      # when:-skip). ResultDisplay#display_result has no notion
      # of "skipped" at all - it would otherwise print a second,
      # contradictory "ok:" line right underneath, and
      # #update_stats would count it toward "ok" instead of
      # "skipped" in the recap.
      record_handler_result(result, results[host.name], host, handler, diff_mode,
        handler_result_ignore_errors(handler, result, host, ignore_errors_resolver))

      true
    end

    # The -vv/console display block for one handler run: Ansible's default
    # callback prints one "NOTIFIED HANDLER <name> for <host>" line per
    # host the handler was newly notified on, then the RUNNING HANDLER
    # banner (once per handler), then the same `task path:` line a
    # regular task gets under its banner.
    private def print_handler_display(handler : Task, handler_index : Int32,
                                      rendered_name : String, host : Host,
                                      bannered : Set(Int32), role_prefix : String) : Nil
      if Krikri::RunOptions.verbosity >= 2 && !Krikri::Oneline.enabled?
        puts "NOTIFIED HANDLER #{rendered_name} for #{host.name}"
      end
      unless bannered.includes?(handler_index)
        Krikri::OutputBanner.banner("RUNNING HANDLER [#{role_prefix}#{rendered_name}]")
        # Same per-task timestamp-line treatment as regular tasks (the
        # handler shows up in the TASKS RECAP under its own name,
        # live-verified) - recorded once per handler, where the banner is.
        Krikri::ProfileTasks.record_task_start(handler, rendered_name)
        bannered << handler_index
      end
      if Krikri::RunOptions.verbosity >= 2 && !Krikri::Oneline.enabled? && (file = handler.source_file) && handler.source_line > 0
        puts "task path: #{File.expand_path(file)}:#{handler.source_line}"
      end
    end

    # Whether *handler* runs for *host* on this pass. Pass one is the
    # ordinary definition-order sweep, restricted to the handler copies
    # the pending notifications actually attach to (see
    # #attachments_for_notification); pass two runs only what a handler
    # re-notified from BEHIND it, regardless of having already run -
    # which is how a self-notifying handler ends up running twice.
    private def eligible_this_pass?(pass : Int32, handler_index : Int32,
                                    rendered_name : String,
                                    attached : Set(Int32),
                                    already_ran : Set(String),
                                    second_pass : Set(String)) : Bool
      return second_pass.includes?(rendered_name) unless pass == 0

      !already_ran.includes?(rendered_name) && attached.includes?(handler_index)
    end

    # A failing handler caught by ignore_errors: must print its
    # "...ignoring" and count ok + ignored, never failed, in the recap
    # exactly like a regular task's ignored failure (issue #1112).
    # Resolved through the threaded resolver against the handler's real
    # scope - the same resolution execute_handler_internal's halt
    # decision already uses - so a templated `ignore_errors: "{{
    # ansible_check_mode }}"` follows the live value, not the parse-time
    # guess; without a resolver the guess stands.
    #
    # A failure raised before the handler's keywords were post-validated
    # (a raising when:) only honours a literal boolean, exactly like a
    # regular task's - see Task#ignore_errors_before_keyword_templating?.
    private def handler_result_ignore_errors(handler : Task, result : JSON::Any, host : Host,
                                             ignore_errors_resolver : Proc(Task, Host, Bool)?) : Bool
      return handler.ignore_errors_before_keyword_templating? if Krikri.pre_keyword_failure_result?(result)
      if resolver = ignore_errors_resolver
        resolver.call(handler, host)
      else
        handler.ignore_errors?
      end
    end

    # Records one handler result: a when:-skipped handler, a looped
    # handler that already printed its own per-item lines, or an
    # ordinary one that still needs displaying.
    private def record_handler_result(result : JSON::Any, stats : Hash(String, Int32),
                                      host : Host, handler : Task, diff_mode : Bool,
                                      ignore_errors : Bool) : Nil
      if result["handler_unreachable_counted"]?.try(&.as_bool)
        # The unreachable was already booked (fatal report, unreachable
        # stat, host halted) inside TaskExecutor#execute_handler_internal -
        # this step must neither display a second line nor recount it.
        return
      end
      if result["handler_include_failure"]?.try(&.as_bool) || result["handler_include_counted"]?.try(&.as_bool)
        # A handler include_tasks: whose file is missing already printed
        # its own fatal shape AND counted the failure (and halted the
        # host) inside TaskExecutor#fail_include_tasks_file_not_found -
        # this step must neither display a second line nor recount it.
        # handler_include_counted is the looped include's twin: every
        # iteration's ok/skip/failure was booked inside
        # #execute_handler_include_loop itself.
        return
      end
      if result["skipped"]?.try(&.as_bool)
        stats["skipped"] = (stats["skipped"]? || 0) + 1
      elsif result["already_displayed"]?.try(&.as_bool)
        # A looped handler (execute_handler_loop) already printed
        # its own per-item result lines - only the stats (from
        # its changed:/failed: aggregate across every item) still
        # need recording here, not a second summary display line.
        ResultDisplay.update_stats(stats, result, ignore_errors)
      else
        # no_log: a handler is as capable of holding a secret as
        # any other task, and this is the non-looped handler's
        # own display path - the looped one goes through
        # execute_handler_loop, which passes it too. This standalone
        # HandlerRunner class has no live vars_context to re-resolve a
        # templated no_log: against (unlike TaskExecutor's own call
        # sites - see resolve_task_no_log there), so a templated value
        # still falls back to the parse-time guess here specifically -
        # same pre-existing gap as before this fix, not a regression.
        ResultDisplay.display_result(host, result, diff_mode, ignore_errors: ignore_errors, no_log: handler.no_log?, module_name: handler.module_name, source_task: handler)
        ResultDisplay.update_stats(stats, result, ignore_errors)
      end
    end

    # Which handler indices (copies) a single notification attaches to,
    # mirroring Ansible's search_handlers_by_notification. Ansible walks
    # the play's handler BLOCKS in reverse (a later block's copy wins
    # over an earlier block's) but each block FORWARD, so among
    # same-named copies inside ONE block the first definition is the one
    # that runs, while a later block's copy still beats an earlier
    # block's. Flattening that into a single global reverse sweep made
    # the last definition win everywhere: issue #804 needed the
    # include_role copy to win over the statically-loaded dependency copy
    # (separate blocks), but issue #1254 hit the other half, where the
    # block-local copy ansible ran was the FIRST same-named definition.
    # The name pass stops at the first match, and the listen pass then
    # attaches every handler whose listen: covers the notification in the
    # same order, deduped by handler name so that among same-named copies
    # only that block-order-first one is notified.
    private def attachments_for_notification(host : Host, notification : String,
                                             rendered_names : Array(String),
                                             name_resolver : Proc(Task, Host, String)?,
                                             unusable_handlers : Set(Task)?) : Array(Int32)
      targets = [] of Int32

      # Rendered names are precomputed per flush for the handlers known
      # then; a handler appended DURING the flush (a handler's own
      # include_role:) sits beyond the array and is rendered on demand
      # here.
      rendered_at = ->(index : Int32) : String {
        if index < rendered_names.size
          rendered_names[index]
        else
          handler = @handlers[index]
          if unusable_handlers.try(&.includes?(handler))
            ""
          else
            name_resolver.try(&.call(handler, host)) || handler.name
          end
        end
      }

      ordered_indices = handler_indices_in_block_order

      ordered_indices.each do |index|
        handler = @handlers[index]
        next if unusable_handlers.try(&.includes?(handler))
        if name_matches_notification?(handler, rendered_at.call(index), notification)
          targets << index
          break
        end
      end

      seen_names = Set(String).new
      ordered_indices.each do |index|
        handler = @handlers[index]
        next if unusable_handlers.try(&.includes?(handler))
        next unless (handler.listen || [] of String).includes?(notification)
        rendered = rendered_at.call(index)
        next if !rendered.empty? && seen_names.includes?(rendered)
        seen_names << rendered
        targets << index
      end

      targets
    end

    # Handler indices in Ansible's resolution order: blocks from last to
    # first, each block's own handlers in definition order. Handlers a
    # dynamic include_role: appends mid-run carry a block id beyond the
    # play's static ones (see Task#handler_block_id), so they keep
    # winning over everything loaded before them.
    private def handler_indices_in_block_order : Array(Int32)
      by_block = Hash(Int32, Array(Int32)).new
      @handlers.each_with_index do |handler, index|
        (by_block[handler.handler_block_id] ||= [] of Int32) << index
      end
      by_block.keys.sort!.reverse!.flat_map { |block_id| by_block[block_id] }
    end

    # The name-attachment predicate shared by every flush-time resolution
    # path: the notification answers to the handler's rendered name, its
    # raw one, or the role-qualified "<qualifier> : <name>" form.
    private def name_matches_notification?(handler : Task, rendered_name : String, notification : String) : Bool
      return true if rendered_name == notification || handler.name == notification

      if idx = notification.rindex(" : ")
        return notification[(idx + 3)..] == rendered_name
      end
      false
    end
  end
end
