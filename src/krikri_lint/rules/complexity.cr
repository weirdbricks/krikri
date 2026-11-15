module Krikri
  module Lint
    # Upstream parity: ansible-lint's complexity rule (severity MEDIUM,
    # tags experimental, idiom). Two tags exist:
    #  - complexity[play]: a play's `tasks:` list is longer than the
    #    allowed maximum.
    #  - complexity[nesting]: a block is nested too deeply.
    class ComplexityRule < Rule
      # ansiblelint.config.Options defaults; upstream exposes no CLI flag
      # or config-file key that overrides either of them.
      MAX_TASKS       = 100
      MAX_BLOCK_DEPTH =  20

      def id : String
        "complexity"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["experimental", "idiom"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      # Task-oriented: violations belong to an enclosing play/task, so a
      # `# noqa:` anywhere in that body suppresses them.
      def task_scoped? : Bool
        true
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        list = file.root.try(&.as?(YAML::Nodes::Sequence)) || return
        if TaskWalker.playbook_root?(file)
          list.nodes.each do |item|
            play = item.as?(YAML::Nodes::Mapping) || next
            check_play_tasks(file, play, violations)
            check_nesting(file, play, violations)
          end
        else
          check_nesting_in_list(file, list, 0, violations)
        end
      end

      private def check_play_tasks(file : PositionedFile,
                                   play : YAML::Nodes::Mapping,
                                   violations : Array(Violation)) : Nil
        tasks = NodeUtil.entry(play, "tasks").try(&.[1])
          .try(&.as?(YAML::Nodes::Sequence)) || return
        return unless tasks.nodes.size > MAX_TASKS
        line = NodeUtil.line(play)
        violations << Violation.new(file.path, line, NodeUtil.column(play),
          "complexity[play]", severity,
          "Maximum tasks allowed in a play is #{MAX_TASKS}.", line)
      end

      # Upstream's block depth is the count of enclosing block list
      # positions, so a top-level block is depth 0 and only a block
      # whose depth exceeds MAX_BLOCK_DEPTH is reported.
      private def check_nesting(file : PositionedFile,
                                play : YAML::Nodes::Mapping,
                                violations : Array(Violation)) : Nil
        %w[pre_tasks tasks post_tasks handlers].each do |section|
          sub = NodeUtil.entry(play, section).try(&.[1])
            .try(&.as?(YAML::Nodes::Sequence)) || next
          check_nesting_in_list(file, sub, 0, violations)
        end
      end

      private def check_nesting_in_list(file : PositionedFile,
                                        list : YAML::Nodes::Sequence,
                                        depth : Int32,
                                        violations : Array(Violation)) : Nil
        list.nodes.each do |item|
          node = item.as?(YAML::Nodes::Mapping) || next
          if (block = NodeUtil.entry(node, "block").try(&.[1])
               .try(&.as?(YAML::Nodes::Sequence)))
            if depth > MAX_BLOCK_DEPTH
              violations << Violation.new(file.path, NodeUtil.line(node), 0,
                "complexity[nesting]", severity,
                "Replace nested block with an include_tasks to make code easier to maintain. " \
                "Maximum block depth allowed is #{MAX_BLOCK_DEPTH}.",
                NodeUtil.line(node))
            end
            check_nesting_in_list(file, block, depth + 1, violations)
          end
          %w[rescue always].each do |section|
            sub = NodeUtil.entry(node, section).try(&.[1])
              .try(&.as?(YAML::Nodes::Sequence)) || next
            check_nesting_in_list(file, sub, depth, violations)
          end
        end
      end
    end
  end
end
