module Krikri
  module Lint
    # Upstream parity: partial-become (severity VERY_HIGH, tags
    # unpredictability). `become_user` without a `become` at the same
    # level is almost always a mistake: the task silently runs as
    # whatever user, not the one named. Two sub-tags:
    # partial-become[play] on a play, partial-become[task] on a task.
    class PartialBecomeRule < Rule
      MESSAGE = "`become_user` should have a corresponding `become` " \
                "at the same level as itself."

      def id : String
        "partial-become"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["unpredictability"]
      end

      def applies_to : Array(FileType)
        [FileType::PLAYBOOK]
      end

      # Task-oriented: a `# noqa:` anywhere in the task's body
      # suppresses the violation, as upstream's matchtask path does.
      def task_scoped? : Bool
        true
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        root = file.root
        plays = root.as?(YAML::Nodes::Sequence)
        return unless plays
        plays.nodes.each do |item|
          play = item.as?(YAML::Nodes::Mapping) || next
          next unless partial?(play)
          line = NodeUtil.line(play)
          violations << Violation.new(file.path, line, 0,
            "partial-become[play]", severity, MESSAGE, line)
        end
        TaskWalker.each_task(file) do |task|
          next unless partial?(task.node)
          violations << Violation.new(file.path, task.line, 0,
            "partial-become[task]", severity, MESSAGE, task.line)
        end
      end

      # `become_user` present, `become` absent - at this level only.
      # Upstream compares the key's presence in the same mapping, so a
      # `become` inherited from the play does not count.
      private def partial?(node : YAML::Nodes::Mapping) : Bool
        !NodeUtil.entry(node, "become_user").nil? &&
          NodeUtil.entry(node, "become").nil?
      end
    end
  end
end
