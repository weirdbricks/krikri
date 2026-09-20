module Krikri
  module Lint
    # Upstream parity: yaml[truthy] (from yamllint). Flags plain scalars
    # that YAML 1.1 resolves as booleans other than true/false (yes, no,
    # on, off, and their case variants); quoted strings are fine.
    class YamlTruthyRule < Rule
      TRUTHY = %w[yes no on off Yes No On Off YES NO ON OFF]

      def id : String
        "yaml[truthy]"
      end

      def severity : Severity
        Severity::LOW
      end

      def tags : Array(String)
        ["formatting", "yaml"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        root = file.root || return
        walk(root) do |scalar|
          next unless scalar.style == YAML::ScalarStyle::PLAIN
          value = scalar.value || ""
          next unless TRUTHY.includes?(value)
          violations << Violation.new(file.path, NodeUtil.line(scalar), 0,
            id, severity, "Truthy value should be one of [false, true]")
        end
      end

      private def walk(node : YAML::Nodes::Node, &block : YAML::Nodes::Scalar ->)
        case node
        when YAML::Nodes::Mapping
          node.nodes.each do |child|
            walk(child, &block)
          end
        when YAML::Nodes::Sequence
          node.nodes.each do |child|
            walk(child, &block)
          end
        when YAML::Nodes::Scalar
          block.call(node)
        end
      end
    end
  end
end
