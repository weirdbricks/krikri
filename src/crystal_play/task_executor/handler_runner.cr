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
      
      # Run all notified handlers
      # Handlers run in the order they are defined, not the order they were notified
      # This matches Ansible behavior
      def run(
        execute_callback : Proc(Task, Host, JSON::Any),
        results : Hash(String, Hash(String, Int32)),
        diff_mode : Bool
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
            next if already_ran[host.name].includes?(handler.name)

            # Check if handler should run for this host
            if should_run_handler?(handler, host)
              already_ran[host.name].add(handler.name)

              unless handler_triggered
                puts "HANDLER [#{handler.name}]".colorize(:cyan).bold
                handler_triggered = true
              end

              # Execute handler using the callback
              result = execute_callback.call(handler, host)

              # Display result
              ResultDisplay.display_result(host, result, diff_mode)

              # Update stats
              ResultDisplay.update_stats(results[host.name], result)
            end
          end

          puts "" if handler_triggered
        end
      end
      
      # Check if a handler should run for a host
      # Handler runs if notified by name or by listen topic
      private def should_run_handler?(handler : Task, host : Host) : Bool
        # Check by handler name
        return true if @notified_handlers[host.name].includes?(handler.name)
        
        # Check by listen topic
        if listen_topic = handler.listen
          return true if @notified_handlers[host.name].includes?(listen_topic)
        end
        
        false
      end
  end
end
