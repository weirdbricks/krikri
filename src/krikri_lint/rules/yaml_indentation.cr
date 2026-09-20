module Krikri
  module Lint
    # Upstream parity: yaml[indentation] (from yamllint defaults:
    # spaces consistent, indent-sequences true, check-multi-line-strings
    # false; error level, MEDIUM here). Covers the structural cases that
    # occur in Ansible content:
    # - the document root must start at column 0;
    # - a mapping entry whose value starts on a later line must have
    #   that value at <mapping indent> + <unit>;
    # - a sequence used as a mapping value at the key's own column is
    #   an unindented sequence (flagged; "expected at least N+1" when
    #   the unit is not known yet, mirroring yamllint);
    # The indentation unit is learned from the first indented next-line
    # value (yamllint's spaces: consistent behavior). Reported at the
    # offending line with no column:
    # "Wrong indentation: expected N but found M".
    # Multi-line flow collections and bare-hyphen entries with their
    # item on the next line are not checked (documented limitation).
    class YamlIndentationRule < Rule
      @unit : Int32? = nil

      def id : String
        "yaml[indentation]"
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
        @unit = nil
        found = root.start_column - 1
        if found > 0
          violations << Violation.new(file.path, root.start_line, 0, id,
            severity, "Wrong indentation: expected 0 but found #{found}")
        end
        walk(root, violations, file)
      end

      private def violation(violations : Array(Violation), file : PositionedFile, line : Int32, expected : Int32, found : Int32) : Nil
        violations << Violation.new(file.path, line, 0, id, severity,
          "Wrong indentation: expected #{expected} but found #{found}")
      end

      private def walk(node : YAML::Nodes::Node, violations : Array(Violation), file : PositionedFile) : Nil
        case node
        when YAML::Nodes::Mapping
          check_mapping(node, violations, file)
          node.nodes.each { |child| walk(child, violations, file) }
        when YAML::Nodes::Sequence
          node.nodes.each { |child| walk(child, violations, file) }
        end
      end

      private def check_mapping(mapping : YAML::Nodes::Mapping, violations : Array(Violation), file : PositionedFile) : Nil
        return if mapping.nodes.empty?
        map_indent = mapping.nodes[0].start_column - 1
        i = 0
        while i + 1 < mapping.nodes.size
          key, value = mapping.nodes[i], mapping.nodes[i + 1]
          i += 2
          next if value.start_line == key.start_line
          next if block_scalar?(value)
          check_value(violations, file, value, map_indent)
        end
      end

      private def block_scalar?(value : YAML::Nodes::Node) : Bool
        value.is_a?(YAML::Nodes::Scalar) &&
          (value.style == YAML::ScalarStyle::LITERAL ||
            value.style == YAML::ScalarStyle::FOLDED)
      end

      private def check_value(violations : Array(Violation), file : PositionedFile,
                              value : YAML::Nodes::Node, map_indent : Int32) : Nil
        found = value.start_column - 1
        if value.is_a?(YAML::Nodes::Sequence) && found == map_indent
          check_unindented_sequence(violations, file, value, map_indent, found)
        elsif unit = @unit
          expected = map_indent + unit
          violation(violations, file, value.start_line, expected, found) if found != expected
        else
          @unit = found - map_indent
        end
      end

      # Unindented sequence under a mapping key: with the unit known the
      # value should have been at map_indent + unit; without it yamllint
      # cannot say what the indent should be and reports "at least N+1"
      # (and does not learn the unit from it).
      private def check_unindented_sequence(violations : Array(Violation), file : PositionedFile,
                                            value : YAML::Nodes::Node, map_indent : Int32, found : Int32) : Nil
        if unit = @unit
          expected = map_indent + unit
          violation(violations, file, value.start_line, expected, found) if expected != found
        else
          violations << Violation.new(file.path, value.start_line, 0, id,
            severity, "Wrong indentation: expected at least #{found + 1}")
        end
      end
    end
  end
end
