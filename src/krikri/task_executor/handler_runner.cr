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

    def initialize(@handlers : Array(Task), @hosts : Array(Host))
      @notified_handlers = Hash(String, Set(String)).new

      @hosts.each do |host|
        @notified_handlers[host.name] = Set(String).new
      end
    end

    # Notify a handler (by name or listen topic)
    # Handlers can be notified multiple times but only run once
    def notify(host : Host, handler_name : String)
      @notified_handlers[host.name].add(handler_name)
    end

    # Check if any handlers were notified
    def any_notified? : Bool
      @notified_handlers.values.any?(&.size.> 0)
    end

    # Clears every host's notified-handler set, so a subsequent #run
    # call (from a later `meta: flush_handlers`, or the final end-of-
    # play flush) only picks up handlers notified SINCE the last flush,
    # not ones already run. Real Ansible's own flush_handlers has this
    # same "only runs what's still pending" semantics - a handler
    # already flushed once doesn't run a second time just because the
    # end-of-play flush also fires.
    def clear_notified!
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
    # *halted_hosts* - hosts a prior task already failed on (unrescued,
    # no ignore_errors:) for this run. Real Ansible never runs a
    # halted host's own notified handlers at the end-of-play flush -
    # once a host is out, it's out entirely, handlers included.
    # Previously unfiltered: @hosts.each below ran unconditionally, so
    # a host whose LAST regular task failed (round 83's
    # robertdebock.keepalived: "Start keepalived" times out and halts
    # the host) still ran its own previously-notified "Restart
    # keepalived" handler at the implicit end-of-play flush, since
    # that flush happens after halt_if_failed already halted the host
    # but before this method had any way to know. Real Ansible shows
    # exactly one failure (the halting task); krikri-playbook showed
    # two (the halting task, then the handler that should never have
    # run).
    def run(
      execute_callback : Proc(Task, Host, JSON::Any),
      results : Hash(String, Hash(String, Int32)),
      diff_mode : Bool,
      name_resolver : Proc(Task, Host, String)? = nil,
      halted_hosts : Set(String)? = nil,
    )
      return unless any_notified?

      puts "RUNNING HANDLER".colorize(:white).bold
      puts "*" * 70

      # A handler runs at most once per host, no matter how many times
      # it was notified - and, since include_role: (possibly looped) can
      # dynamically add further Task objects that happen to share a name
      # with an existing handler (e.g. the same role included twice),
      # no matter how many distinct Task objects share that name either.
      already_ran = Hash(String, Set(String)).new
      @hosts.each { |host| already_ran[host.name] = Set(String).new }

      # Handlers run in definition order. A handler notified by another
      # handler that sits EARLIER in that order has already been passed
      # by the time the notification lands, so real Ansible makes ONE
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
          handler_triggered = false

          @hosts.each do |host|
            next if halted_hosts.try(&.includes?(host.name))

            rendered_name = name_resolver.try(&.call(handler, host)) || handler.name

            if eligible_this_pass?(pass, handler, host, rendered_name,
                 already_ran[host.name], second_pass[host.name])
              already_ran[host.name].add(rendered_name)

              unless handler_triggered
                # Display-only role prefix (verified live against
                # ansible-core 2.19.12: "RUNNING HANDLER [myrole : my
                # handler]") - reads handler.role_name directly rather
                # than folding into rendered_name, which
                # should_run_handler?/eligible_this_pass? also use for
                # notify: MATCHING; prefixing that shared value would
                # make a plain `notify: my handler` stop matching a
                # role handler's own bare notified name.
                role_prefix = (rn = handler.role_name) ? "#{rn} : " : ""
                puts "HANDLER [#{role_prefix}#{rendered_name}]".colorize(:cyan).bold
                handler_triggered = true
              end

              # Execute handler using the callback
              result = execute_callback.call(handler, host)

              # Anything this handler notified that sits at or BEFORE its
              # own position has already been passed, so it needs the
              # second pass. Collected during pass one only - real
              # Ansible drops notifications raised during the second.
              if pass == 0 && (result["changed"]?.try(&.as_bool?) == true)
                # Read from the handler's OWN notify: list rather than
                # diffing @notified_handlers - that is a Set, so a
                # handler re-notifying something already notified (most
                # obviously itself) changes nothing there and the
                # re-notification would be invisible.
                handler.notify.try &.each do |raised|
                  index = @handlers.index { |candidate| candidate.name == raised }
                  second_pass[host.name].add(raised) if index && index <= handler_index
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
              record_handler_result(result, results[host.name], host, handler, diff_mode)
            end
          end

          puts "" if handler_triggered
        end

        # Anything notified during the SECOND pass is discarded, matching
        # real Ansible - so the loop is bounded at two passes regardless
        # of how handlers notify each other.
        break if pass == 1
      end

      clear_notified!
    end

    # Whether *handler* runs for *host* on this pass. Pass one is the
    # ordinary definition-order sweep; pass two runs only what a handler
    # re-notified from BEHIND it, regardless of having already run -
    # which is how a self-notifying handler ends up running twice.
    private def eligible_this_pass?(pass : Int32, handler : Task, host : Host,
                                    rendered_name : String,
                                    already_ran : Set(String),
                                    second_pass : Set(String)) : Bool
      return second_pass.includes?(rendered_name) unless pass == 0

      !already_ran.includes?(rendered_name) &&
        should_run_handler?(handler, host, rendered_name)
    end

    # Records one handler result: a when:-skipped handler, a looped
    # handler that already printed its own per-item lines, or an
    # ordinary one that still needs displaying.
    private def record_handler_result(result : JSON::Any, stats : Hash(String, Int32),
                                      host : Host, handler : Task, diff_mode : Bool) : Nil
      if result["skipped"]?.try(&.as_bool)
        stats["skipped"] = (stats["skipped"]? || 0) + 1
      elsif result["already_displayed"]?.try(&.as_bool)
        # A looped handler (execute_handler_loop) already printed
        # its own per-item result lines - only the stats (from
        # its changed:/failed: aggregate across every item) still
        # need recording here, not a second summary display line.
        ResultDisplay.update_stats(stats, result)
      else
        # no_log: a handler is as capable of holding a secret as
        # any other task, and this is the non-looped handler's
        # own display path - the looped one goes through
        # execute_handler_loop, which passes it too.
        ResultDisplay.display_result(host, result, diff_mode, no_log: handler.no_log?)
        ResultDisplay.update_stats(stats, result)
      end
    end

    # Check if a handler should run for a host
    # Handler runs if notified by name (rendered or raw) or by listen topic
    private def should_run_handler?(handler : Task, host : Host, rendered_name : String) : Bool
      notified = @notified_handlers[host.name]

      # Check by handler name - both the rendered (real) name and the
      # raw one (in case a caller notified using the literal template
      # text, or name_resolver wasn't supplied at all).
      return true if notified.includes?(rendered_name) || notified.includes?(handler.name)

      # Check by listen topic
      if listen_topic = handler.listen
        return true if notified.includes?(listen_topic)
      end

      # Role-qualified notify: form ("<anything> : <handler name>") -
      # real Ansible auto-namespaces a role-loaded handler with a
      # qualifier (the FQCN of whichever role the handler's own
      # inclusion chain traces back to - not always the role that
      # literally defines handlers/main.yml, e.g. `prometheus.
      # prometheus`'s own `_common` role's handlers get qualified with
      # the CALLING role's name, not `_common`'s own) and matches on
      # that exact computed qualifier. Replicating that formula exactly
      # is real, non-trivial work; this instead matches ANY "X : name"
      # shaped notify string against the handler's own bare rendered
      # name, ignoring what X actually is - a handler name legitimately
      # containing " : " as part of its own literal text is exceedingly
      # rare, and this covers every qualifier value without needing to
      # compute the one true correct one. Found live via
      # prometheus.prometheus.pushgateway's own `_common`-defined
      # handler (round 28's continuation) - notify: "{{
      # ansible_parent_role_names | first }} : Restart {{
      # _common_service_name }}" never matched "Restart pushgateway"
      # (the handler's own bare rendered name) at all before this.
      notified.any? { |nval| (idx = nval.rindex(" : ")) && nval[(idx + 3)..] == rendered_name }
    end
  end
end
