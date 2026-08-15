require "json"
require "colorize"
require "../host"
require "../playbook_parser"
require "./result_display"

module CrystalPlay
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
      def run(
        execute_callback : Proc(Task, Host, JSON::Any),
        results : Hash(String, Hash(String, Int32)),
        diff_mode : Bool,
        name_resolver : Proc(Task, Host, String)? = nil
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

        # Handlers run in definition order
        @handlers.each do |handler|
          handler_triggered = false

          @hosts.each do |host|
            rendered_name = name_resolver.try(&.call(handler, host)) || handler.name
            next if already_ran[host.name].includes?(rendered_name)

            # Check if handler should run for this host
            if should_run_handler?(handler, host, rendered_name)
              already_ran[host.name].add(rendered_name)

              unless handler_triggered
                puts "HANDLER [#{rendered_name}]".colorize(:cyan).bold
                handler_triggered = true
              end

              # Execute handler using the callback
              result = execute_callback.call(handler, host)

              # A handler whose own `when:` evaluated false already
              # printed its own "skipping: [host]" line inside
              # execute_handler_internal (mirroring a regular task's
              # when:-skip). ResultDisplay#display_result has no notion
              # of "skipped" at all - it would otherwise print a second,
              # contradictory "ok:" line right underneath, and
              # #update_stats would count it toward "ok" instead of
              # "skipped" in the recap.
              if result["skipped"]?.try(&.as_bool)
                results[host.name]["skipped"] = (results[host.name]["skipped"]? || 0) + 1
              elsif result["already_displayed"]?.try(&.as_bool)
                # A looped handler (execute_handler_loop) already printed
                # its own per-item result lines - only the stats (from
                # its changed:/failed: aggregate across every item) still
                # need recording here, not a second summary display line.
                ResultDisplay.update_stats(results[host.name], result)
              else
                ResultDisplay.display_result(host, result, diff_mode)
                ResultDisplay.update_stats(results[host.name], result)
              end
            end
          end

          puts "" if handler_triggered
        end

        clear_notified!
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
        notified.any? { |n| (idx = n.rindex(" : ")) && n[(idx + 3)..] == rendered_name }
      end
  end
end
