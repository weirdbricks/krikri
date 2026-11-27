module Krikri
  module Lint
    # Upstream parity: ansible-lint's only-builtins rule (severity MEDIUM,
    # tags opt-in,experimental). Reports a task whose action is not a
    # builtin, so a playbook can be pinned to the core modules only.
    class OnlyBuiltinsRule < Rule
      # Upstream's fqcn.builtins, verbatim. The rule compares the action
      # name as written against this fixed list, so a newer builtin alias
      # that is missing here (dnf5, systemd_service) is still reported -
      # unlike fqcn[action-core], which resolves through the loader.
      ALLOWED_MODULES = %w[
        add_host apt apt_key apt_repository assemble assert async_status
        blockinfile command copy cron debconf debug dnf dpkg_selections
        expect fail fetch file find gather_facts get_url getent git group
        group_by hostname import_playbook import_role import_tasks include
        include_role include_tasks include_vars iptables known_hosts
        lineinfile meta package package_facts pause ping pip raw reboot
        replace rpm_key script service service_facts set_fact set_stats
        setup shell slurp stat subversion systemd sysvinit tempfile
        template unarchive uri user wait_for wait_for_connection yum
        yum_repository
      ]

      # Upstream allows any module under these collections, existing or not.
      ALLOWED_COLLECTIONS = %w[ansible.builtin ansible.legacy]

      def id : String
        "only-builtins"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["opt-in", "experimental"]
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
          module_name = action_module(task)
          next if ALLOWED_MODULES.includes?(module_name)
          next if ALLOWED_COLLECTIONS.any? { |prefix| module_name.starts_with?("#{prefix}.") }
          violations << Violation.new(file.path, task.line, 0, id, severity,
            "Use only builtin actions.", task.line)
        end
      end

      # An `action:`/`local_action:` directive names its module inside the
      # value, and upstream resolves it before the rule sees the task, so
      # `action: ansible.posix.sysctl ...` is judged as that module rather
      # than as the directive keyword.
      private def action_module(task : LintTask) : String
        name = task.module_name
        return name unless name == "action" || name == "local_action"
        if free_form = NodeUtil.scalar_value(task.action_node)
          return free_form.split(' ', 2).first? || name
        end
        if mapping = task.action_node.as?(YAML::Nodes::Mapping)
          if (entry = NodeUtil.entry(mapping, "module")) &&
             (value = NodeUtil.scalar_value(entry[1]))
            return value
          end
        end
        name
      end
    end
  end
end
