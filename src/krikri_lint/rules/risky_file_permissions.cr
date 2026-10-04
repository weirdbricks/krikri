module Krikri
  module Lint
    # Upstream parity: ansible-lint's risky-file-permissions
    # (severity VERY_HIGH, tags unpredictability). Flags file-creating
    # modules without an explicit mode, honoring upstream's exemptions
    # (state absent/link, recurse, replace default, mode preserve rules,
    # create-aware modules).
    class RiskyFilePermissionsRule < Rule
      MODULES = %w[
        archive assemble copy file get_url replace template
        community.general.archive ansible.builtin.assemble
        ansible.builtin.copy ansible.builtin.file ansible.builtin.get_url
        ansible.builtin.replace ansible.builtin.template
      ]

      MODULES_WITH_CREATE = {
        "blockinfile"                 => false,
        "ansible.builtin.blockinfile" => false,
        "htpasswd"                    => true,
        "community.general.htpasswd"  => true,
        "ini_file"                    => true,
        "community.general.ini_file"  => true,
        "lineinfile"                  => false,
        "ansible.builtin.lineinfile"  => false,
      }

      MODULES_WITH_PRESERVE = %w[copy template ansible.builtin.copy
        ansible.builtin.template]

      def id : String
        "risky-file-permissions"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["unpredictability"]
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
          next unless MODULES.includes?(task.module_name) ||
                      MODULES_WITH_CREATE.has_key?(task.module_name)
          bare = task.bare_module
          mode = mode_param(task)

          if mode
            next if mode == "preserve" && MODULES_WITH_PRESERVE.includes?(task.module_name)
            # mode: preserve on a module that doesn't support it is itself
            # a violation, handled below via the mode check.
          end

          default_create = MODULES_WITH_CREATE[task.module_name]?
          unless default_create.nil?
            create = truthy?(task.param("create"), default_create)
            if !create || mode
              next
            end
            violations << violation_for(task, file)
            next
          end

          if mode == "preserve" && !MODULES_WITH_PRESERVE.includes?(task.module_name)
            violations << violation_for(task, file)
            next
          end

          state = task.param("state")
          next if state == "absent"
          next if state == "link"
          next if task.has_param?("recurse")
          next if bare == "file" && (state.nil? || state == "file")
          next if bare == "replace" && mode.nil?
          next if mode == "preserve"
          next if mode

          violations << violation_for(task, file)
        end
      end

      # Upstream sees a plain null scalar (mode: null / ~ / a bare key)
      # as Python None, so "mode is None" behaves like the parameter
      # being absent; a quoted "null" stays a string, and a non-scalar
      # value (mapping/sequence) still counts as a present mode.
      private def mode_param(task : LintTask) : String?
        [task.action_node, task.args_node].each do |source|
          mapping = source.as?(YAML::Nodes::Mapping) || next
          if (entry = NodeUtil.entry(mapping, "mode"))
            node = entry[1]
            return "" unless node.is_a?(YAML::Nodes::Scalar)
            value = node.value
            return nil if node.style == YAML::ScalarStyle::PLAIN &&
                          (value.nil? || NULL_LITERALS.includes?(value))
            return value
          end
        end
        nil
      end

      private def truthy?(value : String?, default : Bool) : Bool
        return default if value.nil?
        %w[true yes on 1].includes?(value.downcase)
      end

      NULL_LITERALS = ["null", "Null", "NULL", "~"]

      private def violation_for(task : LintTask, file : PositionedFile) : Violation
        # Upstream's matchtask returns True, so the match message is the
        # rule's shortdesc; the long description is doc-only.
        Violation.new(
          file.path, task.line, 0, id, severity,
          "File permissions unset or incorrect.",
          task.line
        )
      end
    end
  end
end
