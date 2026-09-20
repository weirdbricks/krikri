module Krikri
  module Lint
    # Upstream parity: ansible-lint's run-once rule (severity MEDIUM,
    # tags idiom). run-once[task] for truthy run_once tasks;
    # run-once[play] for strategy: free plays.
    class RunOnceRule < Rule
      def id : String
        "run-once"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["idiom"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        if TaskWalker.playbook_root?(file)
          list = file.root.as(YAML::Nodes::Sequence)
          list.nodes.each do |item|
            play = item.as?(YAML::Nodes::Mapping) || next
            if (entry = NodeUtil.entry(play, "strategy")) &&
               NodeUtil.scalar_value(entry[1]) == "free"
              violations << Violation.new(file.path, NodeUtil.line(play), 0,
                "run-once[play]", severity, "Play uses strategy: free",
                NodeUtil.line(play))
            end
          end
        end
        TaskWalker.each_task(file) do |task|
          value = task.task_value("run_once")
          next unless value && !%w[false no off 0].includes?(value.downcase)
          violations << Violation.new(file.path, task.line, 0,
            "run-once[task]", severity,
            "Using run_once may behave differently if strategy is set to free.",
            task.line)
        end
      end
    end
  end
end
