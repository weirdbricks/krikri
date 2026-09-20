module Krikri
  module Lint
    # Upstream parity: yaml[octal-values] (from yamllint, with
    # forbid-implicit-octal/forbid-explicit-octal both forced on in
    # ansible-lint's bundled .yamllint; error level, MEDIUM here). Only
    # plain (unquoted) scalars are checked; quoted values are strings
    # and belong to risky-octal instead. Reported at the scalar's line
    # with no column:
    # "Forbidden implicit octal value \"0644\"" /
    # "Forbidden explicit octal value \"0o644\"".
    class YamlOctalValuesRule < Rule
      def id : String
        "yaml[octal-values]"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["formatting", "yaml"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        root = file.root || return
        walk(root, violations, file)
      end

      private def octal_digits?(s : String) : Bool
        !s.empty? && s.each_char.all? { |char| char >= '0' && char <= '7' }
      end

      private def decimal_digits?(s : String) : Bool
        !s.empty? && s.each_char.all? { |char| char >= '0' && char <= '9' }
      end

      private def walk(node : YAML::Nodes::Node, violations : Array(Violation), file : PositionedFile) : Nil
        case node
        when YAML::Nodes::Mapping
          node.nodes.each { |child| walk(child, violations, file) }
        when YAML::Nodes::Sequence
          node.nodes.each { |child| walk(child, violations, file) }
        when YAML::Nodes::Scalar
          check_scalar(node, violations, file)
        end
      end

      private def check_scalar(scalar : YAML::Nodes::Scalar, violations : Array(Violation), file : PositionedFile) : Nil
        return unless scalar.style == YAML::ScalarStyle::PLAIN
        value = scalar.value || ""
        if value.size > 1 && value[0] == '0' && decimal_digits?(value[1..]) &&
           octal_digits?(value[1..])
          violations << Violation.new(file.path, NodeUtil.line(scalar), 0, id,
            severity, "Forbidden implicit octal value \"#{value}\"")
        elsif value.size > 2 && value.starts_with?("0o") && octal_digits?(value[2..])
          violations << Violation.new(file.path, NodeUtil.line(scalar), 0, id,
            severity, "Forbidden explicit octal value \"#{value}\"")
        end
      end
    end
  end
end
