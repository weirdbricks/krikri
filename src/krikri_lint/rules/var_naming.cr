module Krikri
  module Lint
    # Upstream parity: ansible-lint's var-naming rule family
    # (severity MEDIUM, tags idiom). Checks var identifiers in play
    # vars, task vars, set_fact keys, and register against Ansible's
    # reserved names and the ^[a-z_][a-z0-9_]*$ pattern, plus
    # no-role-prefix: keys in role defaults/vars files, keys on
    # playbook `roles:` entries, and vars/set_fact/register on
    # include_role/import_role tasks must use the role's name as
    # prefix (FQCN role names skip the prefix/pattern checks).
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

      # ansiblelint.constants.PLAYBOOK_ROLE_KEYWORDS - keys of a play's
      # `roles:` entry that are not role variables.
      ROLE_KEYWORDS = %w[
        any_errors_fatal become become_exe become_flags become_method
        become_user check_mode collections connection debugger
        delegate_facts delegate_to diff environment ignore_errors
        ignore_unreachable module_defaults name role no_log port
        remote_user run_once tags throttle timeout vars when
      ]

      # ansiblelint.text.is_fqcn_or_name: ^\w+(\.\w+){2,100}$|^\w+$
      private FQCN_OR_NAME = /^\w+$|^\w+(\.\w+){2,100}$/

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
        if (mapping = root.as?(YAML::Nodes::Mapping)) &&
           (file.file_type.vars? || file.file_type == FileType::DEFAULTS)
          # Upstream matchyaml treats role defaults/vars files (kind
          # "vars") like vars files: full checks on the top-level keys,
          # with the role's directory name as the expected prefix
          # (var-naming[no-role-prefix]).
          prefix, from_fqcn = role_prefix(file.path)
          NodeUtil.each_entry(mapping) do |k, _|
            next unless key = k.as?(YAML::Nodes::Scalar).try(&.value)
            check_ident(violations, file, key, line: NodeUtil.line(k),
              column: NodeUtil.column(k), source: "vars",
              prefix: prefix, from_fqcn: from_fqcn)
          end
          return
        end
        if list = root.as?(YAML::Nodes::Sequence)
          list.nodes.each do |item|
            play = item.as?(YAML::Nodes::Mapping) || next
            check_vars_section(violations, file, play)
            check_roles_section(violations, file, play)
          end
        end
        TaskWalker.each_task(file) do |task|
          # Upstream matchtask: only include_role/import_role tasks get
          # a prefix (from the included role's name); all other tasks
          # reset it, so their vars/set_fact/register only get the
          # pattern/reserved checks.
          prefix, from_fqcn = if task.bare_module == "include_role" ||
                                 task.bare_module == "import_role"
                                parse_prefix(role_name(task))
                              else
                                {nil, false}
                              end
          check_vars_section(violations, file, task.node, prefix, from_fqcn)
          if task.bare_module == "set_fact"
            action = task.action_node.as?(YAML::Nodes::Mapping)
            action.try do |action_mapping|
              NodeUtil.each_entry(action_mapping) do |k, _|
                next unless key = k.as?(YAML::Nodes::Scalar).try(&.value)
                next if key.starts_with?("__") || key == "cacheable"
                check_ident(violations, file, key, line: NodeUtil.line(k), column: NodeUtil.column(k),
                  source: "set_fact", task_line: task.line,
                  prefix: prefix, from_fqcn: from_fqcn)
              end
            end
          end
          if (reg = task.task_value("register")) && reg.matches?(/^[a-zA-Z_]/)
            check_ident(violations, file, reg, line: task.line, column: 0,
              source: "register", task_line: task.line,
              prefix: prefix, from_fqcn: from_fqcn)
          end
        end
      end

      private def check_vars_section(violations : Array(Violation), file : PositionedFile, node : YAML::Nodes::Mapping,
                                     prefix : String? = nil, from_fqcn : Bool = false) : Nil
        if (entry = NodeUtil.entry(node, "vars")) &&
           (vars = entry[1].as?(YAML::Nodes::Mapping))
          NodeUtil.each_entry(vars) do |k, _|
            next unless key = k.as?(YAML::Nodes::Scalar).try(&.value)
            check_ident(violations, file, key, line: NodeUtil.line(k), column: NodeUtil.column(k),
              source: "vars", prefix: prefix, from_fqcn: from_fqcn)
          end
        end
      end

      # Playbook `roles:` section: keys of each role entry that are not
      # role keywords, plus the entry's `vars:` mapping, are checked with
      # the role's name as prefix. String-form roles are skipped, and
      # FQCN role names skip the pattern and prefix checks entirely.
      private def check_roles_section(violations : Array(Violation), file : PositionedFile, play : YAML::Nodes::Mapping) : Nil
        return unless (roles_entry = NodeUtil.entry(play, "roles")) &&
                      (roles = roles_entry[1].as?(YAML::Nodes::Sequence))
        roles.nodes.each do |item|
          role = item.as?(YAML::Nodes::Mapping) || next
          role_fqcn = if (r = NodeUtil.entry(role, "role")) ||
                         (r = NodeUtil.entry(role, "name"))
                        NodeUtil.scalar_value(r[1])
                      end
          prefix, from_fqcn = parse_prefix(role_fqcn)
          NodeUtil.each_entry(role) do |k, _|
            next unless key = k.as?(YAML::Nodes::Scalar).try(&.value)
            next if ROLE_KEYWORDS.includes?(key)
            check_ident(violations, file, key, line: NodeUtil.line(k),
              column: NodeUtil.column(k), source: "vars",
              prefix: prefix, from_fqcn: from_fqcn)
          end
          if (vars_entry = NodeUtil.entry(role, "vars")) &&
             (vars = vars_entry[1].as?(YAML::Nodes::Mapping))
            NodeUtil.each_entry(vars) do |k, _|
              next unless key = k.as?(YAML::Nodes::Scalar).try(&.value)
              check_ident(violations, file, key, line: NodeUtil.line(k),
                column: NodeUtil.column(k), source: "vars",
                prefix: prefix, from_fqcn: from_fqcn)
            end
          end
        end
      end

      private def role_name(task : LintTask) : String?
        action = task.action_node.as?(YAML::Nodes::Mapping) || return nil
        if (entry = NodeUtil.entry(action, "name"))
          NodeUtil.scalar_value(entry[1])
        end
      end

      # ansiblelint.rules.var_naming.VariableNamingRule._parse_prefix:
      # FQCNs (containing a dot) disable the prefix checks; plain names
      # use their last path component.
      private def parse_prefix(fqcn : String?) : {String?, Bool}
        return {nil, false} if fqcn.nil? || fqcn.empty?
        if fqcn.includes?(".")
          {nil, true}
        else
          {fqcn.split("/").last, false}
        end
      end

      # The role's directory name for a file under roles/<name>/...;
      # nil outside any roles/ directory.
      private def role_prefix(path : String) : {String?, Bool}
        parts = path.split('/')
        idx = parts.rindex("roles") || return {nil, false}
        role = parts[idx + 1]? || return {nil, false}
        {role, false}
      end

      private def check_ident(violations : Array(Violation), file : PositionedFile, ident : String, line : Int32,
                              column : Int32, source : String, task_line : Int32? = nil,
                              prefix : String? = nil, from_fqcn : Bool = false) : Nil
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
        unless from_fqcn || ident.matches?(PATTERN)
          violations << Violation.new(file.path, line, column,
            "var-naming[pattern]", severity,
            "Variables names should match ^[a-z_][a-z0-9_]*$ regex. (#{ident}) (#{source}: #{ident})",
            task_line)
          return
        end
        if prefix && !prefix.empty? && !prefix.includes?("{{") &&
           prefix.matches?(FQCN_OR_NAME) &&
           !ident.lstrip('_').starts_with?("#{prefix}_")
          violations << Violation.new(file.path, line, column,
            "var-naming[no-role-prefix]", severity,
            "Variables names from within roles should use #{prefix}_ as a prefix. (#{source}: #{ident})",
            task_line)
        end
      end
    end
  end
end
