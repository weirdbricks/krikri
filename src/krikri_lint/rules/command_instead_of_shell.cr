module Krikri
  module Lint
    # Upstream parity: ansible-lint's command-instead-of-shell
    # (severity HIGH, tags command-shell/idiom). Fires on `shell:`
    # tasks whose command contains none of the shell-feature
    # characters after Jinja is stripped; `executable:` exempts.
    class CommandInsteadOfShellRule < Rule
      SHELL_CHARS = "&|<>;$\n*[]{}?`!"

      def id : String
        "command-instead-of-shell"
      end

      def severity : Severity
        Severity::HIGH
      end

      def tags : Array(String)
        ["command-shell", "idiom"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          next unless ["shell", "ansible.builtin.shell"].includes?(task.module_name)
          next if task.has_param?("executable")
          next if shell_feature_in?(unjinja(cmd_text(task)))
          violations << Violation.new(
            file.path, task.line, 0, id, severity,
            "Shell should only be used when piping, redirecting or chaining commands (and Ansible would be preferred for some of those!)"
          )
        end
      end

      private def cmd_text(task : LintTask) : String
        parts = [] of String
        action = task.action_node
        if action.is_a?(YAML::Nodes::Scalar)
          return action.value.to_s
        end
        NodeUtil.each_entry(task.node) do |k, v|
          key = k.as?(YAML::Nodes::Scalar).try(&.value) || next
          next if TaskWalker.modifier?(key) || key == task.module_name
          collect(v, parts)
        end
        action = task.action_node.as?(YAML::Nodes::Mapping)
        if action && (cmd = NodeUtil.entry(action, "cmd"))
          collect(cmd[1], parts)
        end
        parts.join(" ")
      end

      private def collect(node : YAML::Nodes::Node, parts : Array(String))
        case node
        when YAML::Nodes::Scalar
          parts << node.value.to_s
        when YAML::Nodes::Sequence
          node.nodes.each { |child| collect(child, parts) }
        end
      end

      private def unjinja(text : String) : String
        text.gsub(/\{\{.*?\}\}/, "JINJA")
      end

      private def shell_feature_in?(text : String) : Bool
        text.each_char.any? { |char| SHELL_CHARS.includes?(char) }
      end
    end
  end
end
