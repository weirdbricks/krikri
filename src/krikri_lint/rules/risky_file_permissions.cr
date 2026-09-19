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

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          next unless MODULES.includes?(task.module_name) ||
                      MODULES_WITH_CREATE.has_key?(task.module_name)
          bare = task.bare_module

          if mode = task.param("mode")
            next if mode == "preserve" && MODULES_WITH_PRESERVE.includes?(task.module_name)
            # mode: preserve on a module that doesn't support it is itself
            # a violation, handled below via the mode check.
          end

          default_create = MODULES_WITH_CREATE[task.module_name]?
          unless default_create.nil?
            create = truthy?(task.param("create"), default_create)
            if !create || task.param("mode")
              next
            end
            violations << violation_for(task, file)
            next
          end

          mode = task.param("mode")
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

      private def truthy?(value : String?, default : Bool) : Bool
        return default if value.nil?
        %w[true yes on 1].includes?(value.downcase)
      end

      private def violation_for(task : LintTask, file : PositionedFile) : Violation
        Violation.new(
          file.path, task.line, NodeUtil.column(task.node), id, severity,
          "Missing or unsupported mode parameter can cause unexpected file permissions based on version of Ansible being used. Be explicit, like `mode: 0644` to avoid hitting this rule. Special `preserve` value is accepted only by `copy`, `template` modules."
        )
      end
    end
  end
end
