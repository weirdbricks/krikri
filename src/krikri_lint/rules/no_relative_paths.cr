module Krikri
  module Lint
    # Upstream parity: ansible-lint's no-relative-paths (severity HIGH,
    # tags idiom). A copy/template `src` that climbs back into the role's
    # files/ or templates/ folder from somewhere else depends on where
    # the playbook lives, not on the directory the task file is in.
    class NoRelativePathsRule < Rule
      # Upstream's _module_to_path_folder. win_template's folder is
      # "win_templates", not "templates".
      MODULE_TO_PATH_FOLDER = {
        "copy"         => "files",
        "win_copy"     => "files",
        "template"     => "templates",
        "win_template" => "win_templates",
      }

      def id : String
        "no-relative-paths"
      end

      def severity : Severity
        Severity::HIGH
      end

      def tags : Array(String)
        ["idiom"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      # Task-oriented: violations belong to an enclosing task, so a
      # `# noqa:` anywhere in that task's body suppresses them.
      def task_scoped? : Bool
        true
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          folder = MODULE_TO_PATH_FOLDER[resolved_module(task)]?
          next unless folder
          src = action_src(task) || next
          next unless src.includes?("../#{folder}")
          # Upstream's matchtask match carries the task's start line and
          # no column.
          violations << Violation.new(
            file.path, task.line, 0, id, severity,
            "The src argument should not use a relative path.", task.line,
          )
        end
      end

      # Upstream's __ansible_module__ keeps ansible.legacy. and
      # collection spellings as written but reduces a resolvable
      # ansible.builtin. core module to its short name (ansible.builtin.copy
      # is matched, ansible.windows.win_copy and ansible.legacy.copy are
      # not - verified against 25.2.1).
      private def resolved_module(task : LintTask) : String
        name = task.module_name
        return name unless name.starts_with?("ansible.builtin.")
        bare = name.sub("ansible.builtin.", "")
        MODERNIZATION.builtin?(bare) ? bare : name
      end

      # Upstream reads src from the task's normalized action only; a src
      # written under a task-level `args:` mapping is not part of it
      # (verified against 25.2.1).
      private def action_src(task : LintTask) : String?
        mapping = task.action_node.as?(YAML::Nodes::Mapping) || return nil
        entry = NodeUtil.entry(mapping, "src") || return nil
        NodeUtil.scalar_value(entry[1])
      end
    end
  end
end
