module Krikri
  module Lint
    # Upstream parity: ansible-lint's key-order (severity LOW, tags
    # formatting). name goes first, block/rescue/always go last; all
    # other keys (including the module) share the middle rank.
    class KeyOrderRule < Rule
      SORTER = %w[name block rescue always]

      def id : String
        "key-order"
      end

      def severity : Severity
        Severity::LOW
      end

      def tags : Array(String)
        ["formatting"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        root = file.root || return
        list = root.as?(YAML::Nodes::Sequence) || return
        if TaskWalker.playbook_root?(file)
          list.nodes.each do |item|
            play = item.as?(YAML::Nodes::Mapping) || next
            check_mapping(play, "play", file, violations)
            %w[pre_tasks tasks post_tasks handlers].each do |section|
              if (entry = NodeUtil.entry(play, section)) &&
                 (tasks_list = entry[1].as?(YAML::Nodes::Sequence))
                walk_tasks(tasks_list, file, violations)
              end
            end
          end
        else
          walk_tasks(list, file, violations)
        end
      end

      # Walks task lists including block parents (TaskWalker skips
      # block parent mappings, but upstream checks their key order too).
      private def walk_tasks(list : YAML::Nodes::Sequence, file : PositionedFile,
                             violations : Array(Violation)) : Nil
        list.nodes.each do |item|
          node = item.as?(YAML::Nodes::Mapping) || next
          if !NodeUtil.entry(node, "block").nil?
            check_mapping(node, "task", file, violations)
            %w[block rescue always].each do |section|
              if (entry = NodeUtil.entry(node, section)) &&
                 (sub = entry[1].as?(YAML::Nodes::Sequence))
                walk_tasks(sub, file, violations)
              end
            end
            next
          end
          check_mapping(node, "task", file, violations)
        end
      end

      private def check_mapping(node : YAML::Nodes::Mapping, kind : String,
                                file : PositionedFile, violations : Array(Violation)) : Nil
        keys = [] of String
        NodeUtil.each_entry(node) do |k, _|
          next unless key = k.as?(YAML::Nodes::Scalar).try(&.value)
          # upstream excludes annotation keys and keys starting with _
          next if key.starts_with?("_") ||
                  %w[comment].includes?(key)
          keys << key
        end
        sorted = keys.sort { |a, b| rank(a) <=> rank(b) }
        return if keys == sorted
        tag = kind == "play" ? "key-order[play]" : "key-order[task]"
        column = kind == "play" ? NodeUtil.column(node) : 0
        violations << Violation.new(file.path, NodeUtil.line(node),
          column, tag, severity,
          "You can improve the #{kind} key order to: #{sorted.join(", ")}",
          NodeUtil.line(node))
      end

      # Upstream's SORTER_TASKS has an explicit None entry between name
      # and block: every unranked key (modules, when, notify...) shares
      # rank 1, block/rescue/always are 2/3/4.
      private def rank(key : String) : Int32
        case key
        when "name"   then 0
        when "block"  then 2
        when "rescue" then 3
        when "always" then 4
        else               1
        end
      end
    end
  end
end
