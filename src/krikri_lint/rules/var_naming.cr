module Krikri
  module Lint
    # Upstream parity: ansible-lint's var-naming rule family
    # (severity MEDIUM, tags idiom). Checks var identifiers in play
    # vars, task vars, set_fact keys, and register against Ansible's
    # reserved names and the ^[a-z_][a-z0-9_]*$ pattern.
    class VarNamingRule < Rule
      PATTERN = /^[a-z_][a-z0-9_]*$/

      # ansible.vars.reserved.get_reserved_names() - stable core set.
      RESERVED = %w[
        action always any_errors_fatal become become_exe become_flags
        become_method become_user block changed_when check_mode
        collections connection debugger delay delegate_to delegate_facts
        diff environment failed_when failed_when_result force_handlers
        gather_facts gather_subset gather_timeout handlers ignore_errors
        ignore_unreachable import_playbook import_role import_tasks
        include include_role include_tasks include_vars listen load_vars
        local_action loop loop_control module_defaults name no_log notify
        order poll port post_tasks pre_tasks private_role_vars register
        remote_user rescue roles run_once tags tasks throttle timeout
        until vars vars_files when with_
      ]

      ALLOWED_SPECIAL = %w[
        ansible_facts ansible_become_user ansible_connection ansible_host
        ansible_python_interpreter ansible_user ansible_remote_tmp
      ]

      def id : String
        "var-naming"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["idiom"]
      end

      def applies_to : Array(FileType)
        [FileType::PLAYBOOK, FileType::TASKS, FileType::HANDLERS,
         FileType::VARS, FileType::DEFAULTS]
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        root = file.root || return
        if (mapping = root.as?(YAML::Nodes::Mapping)) && file.file_type.vars?
          # Upstream's matchyaml checks vars-file keys for pattern
          # violations only (reserved names are not flagged there).
          NodeUtil.each_entry(mapping) do |k, _|
            next unless key = k.as?(YAML::Nodes::Scalar).try(&.value)
            next if key.includes?("{{")
            unless key.matches?(PATTERN)
              violations << Violation.new(file.path, NodeUtil.line(k),
                NodeUtil.column(k), "var-naming[pattern]", severity,
                "Variables names should match ^[a-z_][a-z0-9_]*$ regex. (#{key}) (vars: #{key})",
                nil)
            end
          end
          return
        end
        if list = root.as?(YAML::Nodes::Sequence)
          list.nodes.each do |item|
            play = item.as?(YAML::Nodes::Mapping) || next
            check_vars_section(violations, file, play)
          end
        end
        TaskWalker.each_task(file) do |task|
          check_vars_section(violations, file, task.node)
          if task.bare_module == "set_fact"
            action = task.action_node.as?(YAML::Nodes::Mapping)
            action.try do |action_mapping|
              NodeUtil.each_entry(action_mapping) do |k, _|
                next unless key = k.as?(YAML::Nodes::Scalar).try(&.value)
                next if key.starts_with?("__") || key == "cacheable"
                check_ident(violations, file, key, line: NodeUtil.line(k), column: NodeUtil.column(k),
                  source: "set_fact", task_line: task.line)
              end
            end
          end
          if (reg = task.task_value("register")) && reg.matches?(/^[a-zA-Z_]/)
            check_ident(violations, file, reg, line: task.line, column: 0,
              source: "register", task_line: task.line)
          end
        end
      end

      private def check_vars_section(violations : Array(Violation), file : PositionedFile, node : YAML::Nodes::Mapping, _prefix : String? = nil) : Nil
        if (entry = NodeUtil.entry(node, "vars")) &&
           (vars = entry[1].as?(YAML::Nodes::Mapping))
          NodeUtil.each_entry(vars) do |k, _|
            next unless key = k.as?(YAML::Nodes::Scalar).try(&.value)
            check_ident(violations, file, key, line: NodeUtil.line(k), column: NodeUtil.column(k),
              source: "vars")
          end
        end
      end

      private def check_ident(violations : Array(Violation), file : PositionedFile, ident : String, line : Int32,
                              column : Int32, source : String, task_line : Int32? = nil) : Nil
        return if ALLOWED_SPECIAL.includes?(ident)
        # Upstream allows jinja-templated var names (no-jinja is not
        # emitted; templated names skip all other checks too).
        return if ident.includes?("{{")
        if RESERVED.includes?(ident)
          violations << Violation.new(file.path, line, column,
            "var-naming[no-reserved]", severity,
            "Variables names must not be Ansible reserved names. (#{ident}) (#{source}: #{ident})",
            task_line)
          return
        end
        return if ident.starts_with?("__")
        unless ident.matches?(PATTERN)
          violations << Violation.new(file.path, line, column,
            "var-naming[pattern]", severity,
            "Variables names should match ^[a-z_][a-z0-9_]*$ regex. (#{ident}) (#{source}: #{ident})",
            task_line)
        end
      end
    end
  end
end
