module Krikri
  module Lint
    # Upstream parity: yaml[key-duplicates] (from yamllint defaults;
    # error level, MEDIUM here). Reports each duplicated mapping key at
    # the duplicate key's line with no column:
    # "Duplication of key \"key\" in mapping". Merge keys ("<<") are
    # exempt.
    class YamlKeyDuplicatesRule < Rule
      def id : String
        "yaml[key-duplicates]"
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

      private def walk(node : YAML::Nodes::Node, violations : Array(Violation), file : PositionedFile) : Nil
        case node
        when YAML::Nodes::Mapping
          seen = Set(String).new
          i = 0
          while i + 1 < node.nodes.size
            key_node = node.nodes[i]
            i += 2
            next unless key = key_node.as?(YAML::Nodes::Scalar)
            value = key.value
            next if value.nil? || value.empty? || value == "<<"
            if seen.includes?(value)
              violations << Violation.new(file.path, NodeUtil.line(key), 0, id,
                severity, "Duplication of key \"#{value}\" in mapping")
            else
              seen << value
            end
          end
          node.nodes.each { |child| walk(child, violations, file) }
        when YAML::Nodes::Sequence
          node.nodes.each { |child| walk(child, violations, file) }
        end
      end
    end
  end
end
