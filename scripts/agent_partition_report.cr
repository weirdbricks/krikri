#!/usr/bin/env crystal
#
# Measures how a real role would partition under a
# target-side agent, WITHOUT executing anything.
#
# Item 5 ("ship the play, not the tasks") claims N x RTT -> ~1 RTT per
# play. That figure assumes the whole play can run target-side in one
# go. It cannot: copy/template/script/unarchive/assemble read the
# CONTROLLER's filesystem, lookup() reads the controller's environment,
# and hostvars spans hosts. So the real figure is
# N x RTT -> (number of agent runs) x RTT, where a run is a maximal
# stretch of consecutive agent-eligible tasks.
#
# This script computes that run count statically, so the decision to
# build item 5 (or not) rests on a number rather than on the estimate in
# the plan. No hosts, no execution, no side effects - it parses and
# classifies.
#
# Usage:
#   crystal run scripts/agent_partition_report.cr -- <playbook.yml> [...]
#   crystal run scripts/agent_partition_report.cr -- --roles-dir <dir>
#
# The classification is deliberately CONSERVATIVE in the same sense
# TaskBatcher.plan is: anything it cannot prove self-contained is called
# controller-bound. A real implementation could only ever do worse than
# this, never better, so the run counts printed here are a LOWER bound on
# how fragmented a role would be - i.e. an UPPER bound on item 5's win.

require "colorize"
require "../src/krikri/playbook_parser"

module AgentPartition
  # Modules whose implementation reads the controller's filesystem
  # before dispatch - see the staging chain in
  # executor.cr (resolve_role_relative_src, inline_copy_source_content,
  # stage_unarchive_remote_src, stage_script_src, stage_assemble_dir),
  # plus TemplateActionPlugin which renders on the controller.
  CONTROLLER_FILE_MODULES = %w[
    copy template script unarchive assemble fetch
  ]

  # Controller-side action plugins today. Split deliberately, because
  # the distinction decides item 5's answer:
  #
  # PURE ones evaluate an expression against the vars context and
  # produce a result. They touch NO controller resource - an agent
  # holding the context could run them, and `debug`'s output streams
  # back like any other result. They are controller-side today as an
  # implementation choice (ActionPluginManager), not a constraint.
  #
  # `pause:` genuinely needs the controller: it reads the operator's
  # terminal.
  PURE_ACTION_MODULES     = %w[debug assert fail set_fact]
  CONTROLLER_ONLY_MODULES = %w[pause]

  record Finding, task_name : String, reason : String

  # strict:   classify as the engine behaves TODAY (pure action plugins
  #           stay on the controller).
  # movable:  assume the pure action plugins are moved into the agent,
  #           which is a prerequisite change item 5 would need anyway.
  enum Mode
    Strict
    Movable
  end

  class Report
    getter total = 0
    getter controller_bound = 0
    getter runs = [] of Int32
    getter reasons = Hash(String, Int32).new(0)
    # A controller-bound task is NOT automatically free: copy/template/
    # script/unarchive stage on the controller and then DISPATCH to the
    # target, so they still cost a round trip. debug/assert/fail/
    # set_fact/pause and includes cost none.
    getter controller_dispatches = 0
    getter samples = [] of Finding

    @current_run = 0

    def initialize(@mode : Mode = Mode::Strict)
    end

    def visit(tasks : Array(Krikri::Task))
      tasks.each do |task|
        # block:/rescue:/always: - recurse so nested tasks are counted,
        # and treat the structure itself as a boundary rather than
        # pretending an agent could run a whole block unaided.
        nested = {task.block_tasks, task.rescue_tasks, task.always_tasks}
        if nested.any? { |list| list && !list.empty? }
          flush("block/rescue/always structure")
          nested.each { |list| visit(list) if list }
          next
        end

        @total += 1
        if reason = controller_reason(task)
          @controller_bound += 1
          @controller_dispatches += 1 if costs_round_trip?(task)
          @reasons[reason] += 1
          @samples << Finding.new(task.name, reason) if @samples.size < 8
          flush(reason)
        else
          @current_run += 1
        end
      end
    end

    def finish
      flush("end of play")
    end

    private def flush(_reason : String)
      @runs << @current_run if @current_run > 0
      @current_run = 0
    end

    # Does this controller-bound task still make a remote call?
    private def costs_round_trip?(task : Krikri::Task) : Bool
      simple = task.module_name.split('.').last
      return false if PURE_ACTION_MODULES.includes?(simple)
      return false if CONTROLLER_ONLY_MODULES.includes?(simple)
      return false if simple.starts_with?("_include") || simple.starts_with?("_import")
      # fetch pulls over its own SSH connection; copy/template/script/
      # unarchive/assemble stage locally then dispatch. Both are a trip.
      true
    end

    # nil = agent-eligible. A String = the reason it must stay on the
    # controller. Split in two purely to keep each half readable.
    private def controller_reason(task : Krikri::Task) : String?
      module_reason(task) || task_feature_reason(task) || expression_reason(task)
    end

    private def module_reason(task : Krikri::Task) : String?
      simple = task.module_name.split('.').last

      return "controller file access (#{simple})" if CONTROLLER_FILE_MODULES.includes?(simple)
      return "needs the operator terminal (#{simple})" if CONTROLLER_ONLY_MODULES.includes?(simple)
      if PURE_ACTION_MODULES.includes?(simple)
        return @mode.strict? ? "controller action plugin today (#{simple})" : nil
      end
      return "include/import (dynamic)" if simple.starts_with?("_include") || simple.starts_with?("_import")
      nil
    end

    private def task_feature_reason(task : Krikri::Task) : String?
      return "delegate_to" if task.delegate_to
      return "connection: override" if task.connection
      return "run_once" if task.run_once
      return "async" if task.async_seconds
      return "until: (controller retry loop)" if task.until_condition
      nil
    end

    private def expression_reason(task : Krikri::Task) : String?
      # lookup()/query() reach the controller's env/FS/subprocess from
      # inside expression evaluation, so ANY expression text carrying
      # one pins the task to the controller.
      if expr = expression_texts(task).find { |text| text.includes?("lookup(") || text.includes?("query(") }
        _ = expr
        return "lookup()/query() in an expression"
      end

      # hostvars/groups span hosts; a single agent has one host's view.
      if expression_texts(task).any? { |text| text.includes?("hostvars") || text.includes?("groups[") }
        return "cross-host reference (hostvars/groups)"
      end

      nil
    end

    private def expression_texts(task : Krikri::Task) : Array(String)
      texts = [] of String
      task.params.each_value { |v| texts << v }
      task.vars.each_value { |v| texts << v.to_s }
      {task.when_condition, task.changed_when, task.failed_when, task.until_condition}.each do |expr|
        texts << expr if expr
      end
      texts
    end
  end
end

# --- driver ---------------------------------------------------------

playbooks = ARGV.reject(&.starts_with?("--"))
if playbooks.empty?
  STDERR.puts "usage: agent_partition_report.cr <playbook.yml> [...]"
  exit 1
end

# STATIC-VISIBILITY CAVEAT, stated up front because it bounds everything
# below: the parser does not expand `include_tasks:`/`include_role:`,
# because those are dynamic by definition - the file they name can be
# templated and is only known at run time. So a role that is mostly
# includes (devsec.hardening.os_hardening is: ~95 tasks at run time)
# shows only its statically-visible top-level tasks here. Every include
# is itself counted as a run boundary, which is the conservative
# reading, but the per-role totals are NOT the role's runtime task
# count. Treat the SHAPE as the finding, not the absolute numbers.
printf("%-38s %6s %6s %6s %7s %6s %6s\n",
  "playbook", "tasks", "ctrl", "runs", "avg run", "ctrl'", "runs'")
puts "-" * 82

total_tasks = 0
total_runs = 0
total_runs_movable = 0
total_dispatches_movable = 0
all_reasons = Hash(String, Int32).new(0)

playbooks.each do |path|
  begin
    playbook = Krikri::PlaybookParser.parse(path)
  rescue ex
    printf("%-42s %s\n", File.basename(path), "PARSE FAILED: #{ex.message.to_s[0, 28]}")
    next
  end

  report = AgentPartition::Report.new(AgentPartition::Mode::Strict)
  playbook.plays.each { |play| report.visit(play.tasks) }
  report.finish

  movable = AgentPartition::Report.new(AgentPartition::Mode::Movable)
  playbook.plays.each { |play| movable.visit(play.tasks) }
  movable.finish

  runs = report.runs
  avg = runs.empty? ? 0.0 : runs.sum / runs.size.to_f
  total_tasks += report.total
  total_runs += runs.size
  total_runs_movable += movable.runs.size
  total_dispatches_movable += movable.controller_dispatches
  movable.reasons.each { |k, v| all_reasons[k] += v }

  printf("%-38s %6d %6d %6d %7.1f %6d %6d\n",
    File.basename(path, ".yml")[0, 38], report.total, report.controller_bound,
    runs.size, avg, movable.controller_bound, movable.runs.size)
end

puts
puts "ctrl/runs   = as the engine behaves TODAY"
puts "ctrl'/runs' = if debug/assert/fail/set_fact move into the agent"
puts
puts "TOTAL: #{total_tasks} statically-visible tasks"
puts "  agent runs (movable mode):        #{total_runs_movable}"
puts "  controller tasks still dispatching: #{total_dispatches_movable}"
trips = total_runs_movable + total_dispatches_movable
puts "  => round trips under item 5:      ~#{trips}"
puts
puts "The comparison baseline is NOT #{total_tasks}. Task batching (item 3)"
puts "already collapses consecutive tasks into one trip, so the engine as it"
puts "stands today is well below one trip per task - measured on"
puts "os_hardening: 79 round trips for ~95 runtime tasks. Item 5's marginal"
puts "value is (today's batched trips) - (#{trips}), not (#{total_tasks}) - (#{trips})."
puts
puts "Why tasks stay on the controller (movable mode - the real blockers):"
all_reasons.to_a.sort_by { |(_, v)| -v }.each do |reason, count|
  puts "  #{count.to_s.rjust(4)}  #{reason}"
end
