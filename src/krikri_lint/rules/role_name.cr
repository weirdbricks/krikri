module Krikri
  module Lint
    # Upstream parity: ansible-lint's role-name family (severity HIGH,
    # tags deprecations,metadata). Two checks share the family id:
    #  - a role directory target whose inferred name does not match
    #    ROLE_NAME_REGEX (upstream's matchdir surface). Upstream only
    #    checks a directory as kind "role" when the directory itself is a
    #    target; walking its parent does not lint nested role directories,
    #    so only an explicit role target reaches it.
    #  - a role imported by a path rather than a name, which depends on
    #    where the including file lives, so ansible-lint rejects an import
    #    whose role name contains a "/". Upstream reaches this from four
    #    surfaces, each reporting a different position:
    #     - a play's `roles:` string entry, at the play mapping;
    #     - a play's `roles:` mapping entry, at that mapping;
    #     - an include_role/import_role task, at the task with no column;
    #     - a role's meta/main.yml `dependencies` entry, at the role value.
    class RoleNameRule < Rule
      # Upstream's ROLE_NAME_REGEX.
      PATTERN = /^[a-z][a-z0-9_]*$/

      # Galaxy's conventional role-repository prefix, stripped before the
      # pattern check.
      PREFIX = "ansible-role-"

      PATH_MESSAGE = "Avoid using paths when importing roles."

      # Upstream's ROLE_IMPORT_ACTION_NAMES: the typed and the
      # ansible.builtin./ansible.legacy. spellings, but not roles
      # imported through another collection.
      ROLE_IMPORT_ACTIONS = %w[
        include_role import_role
        ansible.builtin.include_role ansible.builtin.import_role
        ansible.legacy.include_role ansible.legacy.import_role
      ]

      # Plain scalars PyYAML resolves to a non-string, as Python's str()
      # would spell them.
      NULL_WORDS  = ["", "~", "null", "Null", "NULL"]
      TRUE_WORDS  = %w[true True TRUE yes Yes YES on On ON]
      FALSE_WORDS = %w[false False FALSE no No NO off Off OFF]

      def id : String
        "role-name"
      end

      def severity : Severity
        Severity::HIGH
      end

      def tags : Array(String)
        ["deprecations", "metadata"]
      end

      # The directory check needs the ROLE kind; the import checks read
      # playbooks, task files and meta/main.yml.
      def applies_to : Array(FileType)
        FileType.values
      end

      # Upstream reaches the directory check through matchdir, which only
      # a directory target of kind "role" goes through.
      def role_lintable? : Bool
        true
      end

      # The include_role/import_role matches come from upstream's
      # matchtask, so they carry the task's description and belong to
      # that task for noqa purposes.
      def task_scoped? : Bool
        true
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        if file.file_type == FileType::ROLE
          check_role_dir(file, violations)
          return
        end
        check_plays(file, violations) if file.file_type.playbook?
        check_meta(file, violations) if file.file_type.meta?
        check_tasks(file, violations)
      end

      private def check_role_dir(file : PositionedFile,
                                 violations : Array(Violation)) : Nil
        name = role_name(file.path)
        # Upstream tests `if role_name` first, so an empty inferred name
        # is accepted rather than reported.
        return if name.empty? || name.matches?(PATTERN)
        violations << Violation.new(file.path, 1, 0, id, severity,
          "Role name #{name} does not match ``^[a-z][a-z0-9_]*$`` pattern.")
      end

      private def check_plays(file : PositionedFile, violations : Array(Violation)) : Nil
        return unless TaskWalker.playbook_root?(file)
        list = file.root.try(&.as?(YAML::Nodes::Sequence)) || return
        list.nodes.each do |item|
          play = item.as?(YAML::Nodes::Mapping) || next
          roles = NodeUtil.entry(play, "roles").try(&.[1])
          roles_list = roles.try(&.as?(YAML::Nodes::Sequence)) || next
          roles_list.nodes.each do |role_item|
            case role_item
            when YAML::Nodes::Scalar
              # A string entry reports at the play itself, the position
              # upstream obtained from the play before walking its roles.
              report_if_path(file, role_item.value, play, violations)
            when YAML::Nodes::Mapping
              role = NodeUtil.entry(role_item, "role").try(&.[1])
              role_name = role.try { |node| NodeUtil.scalar_value(node) }
              report_if_path(file, role_name, role_item, violations)
            end
          end
        end
      end

      # A dependency keeps its meta/main.yml position, at the role value
      # (upstream passes the name as the match's `data`).
      private def check_meta(file : PositionedFile, violations : Array(Violation)) : Nil
        root = file.root.try(&.as?(YAML::Nodes::Mapping)) || return
        deps = NodeUtil.entry(root, "dependencies").try(&.[1])
        deps_list = deps.try(&.as?(YAML::Nodes::Sequence)) || return
        deps_list.nodes.each do |item|
          case item
          when YAML::Nodes::Scalar
            report_if_path(file, item.value, item, violations)
          when YAML::Nodes::Mapping
            role = NodeUtil.entry(item, "role").try(&.[1])
            role_name = role.try { |node| NodeUtil.scalar_value(node) }
            report_if_path(file, role_name, role || item, violations)
          end
        end
      end

      private def check_tasks(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          next unless ROLE_IMPORT_ACTIONS.includes?(task.module_name)
          name = task.param("name") || next
          next unless name.includes?('/')
          # Upstream's matchtask passes no column, so only the line shows.
          violations << Violation.new(file.path, task.line, 0, "role-name[path]",
            severity, "#{PATH_MESSAGE} (#{name})", task.line)
        end
      end

      private def report_if_path(file : PositionedFile, role_name : String?,
                                 node : YAML::Nodes::Node,
                                 violations : Array(Violation)) : Nil
        return unless role_name
        return unless role_name.includes?('/')
        violations << Violation.new(file.path, NodeUtil.line(node),
          NodeUtil.column(node), "role-name[path]", severity,
          "#{PATH_MESSAGE} (#{role_name})")
      end

      # Upstream's RoleNames._infer_role_name: galaxy_info.role_name from
      # the role's meta/main.yml when it is there, else the directory
      # basename, with a leading galaxy repository prefix removed.
      private def role_name(dir : String) : String
        raw = meta_role_name(File.join(dir, "meta", "main.yml")) ||
              File.basename(dir)
        raw.starts_with?(PREFIX) ? raw[PREFIX.size..] : raw
      end

      # Only a scalar can name a role, so a non-scalar value falls back to
      # the directory basename (upstream stringifies it, but such
      # metadata is already invalid under schema[meta]).
      private def meta_role_name(path : String) : String?
        return nil unless File.file?(path)
        root = YAML::Nodes.parse(File.read(path)).nodes.first?
        meta = root.as?(YAML::Nodes::Mapping) || return nil
        return nil if meta.nodes.empty?
        info_entry = NodeUtil.entry(meta, "galaxy_info") || return nil
        info = info_entry[1].as?(YAML::Nodes::Mapping) || return nil
        name_entry = NodeUtil.entry(info, "role_name") || return nil
        node = name_entry[1].as?(YAML::Nodes::Scalar) || return nil
        python_str(node)
      rescue YAML::ParseException
        nil
      end

      # str() of the value PyYAML loads for the scalar: a plain null,
      # boolean or number is not a string, and Python spells it in its
      # own way.
      private def python_str(node : YAML::Nodes::Scalar) : String
        value = node.value || ""
        return value unless node.style == YAML::ScalarStyle::PLAIN
        return "None" if NULL_WORDS.includes?(value)
        return "True" if TRUE_WORDS.includes?(value)
        return "False" if FALSE_WORDS.includes?(value)
        value
      end
    end
  end
end
