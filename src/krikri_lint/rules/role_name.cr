module Krikri
  module Lint
    # Upstream parity: ansible-lint's role-name rule for role directory
    # targets (severity HIGH, tags deprecations,metadata). Upstream only
    # checks a directory as kind "role" when the directory itself is a
    # target; walking its parent does not lint nested role directories,
    # so only an explicit role target reaches here.
    class RoleNameRule < Rule
      # Upstream's ROLE_NAME_REGEX.
      PATTERN = /^[a-z][a-z0-9_]*$/

      # Galaxy's conventional role-repository prefix, stripped before the
      # pattern check.
      PREFIX = "ansible-role-"

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

      def applies_to : Array(FileType)
        [FileType::ROLE]
      end

      # Upstream reaches this rule through matchdir for a role directory.
      def role_lintable? : Bool
        true
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        name = role_name(file.path)
        # Upstream tests `if role_name` first, so an empty inferred name
        # is accepted rather than reported.
        return if name.empty? || name.matches?(PATTERN)
        violations << Violation.new(file.path, 1, 0, id, severity,
          "Role name #{name} does not match ``^[a-z][a-z0-9_]*$`` pattern.")
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
