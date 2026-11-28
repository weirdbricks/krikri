module Krikri
  module Lint
    # Upstream parity: ansible-lint's opt-in galaxy-version-incorrect
    # (severity MEDIUM, tags opt-in,metadata). A collection published from
    # a galaxy.yml whose version is below 1.0.0 is reported; upstream
    # only ever runs this for the galaxy kind, so FileType::GALAXY exists
    # for the galaxy rules alone.
    #
    # The comparison is Python's plain list ordering of the dot-split
    # components (`Version` in the rule), not semver: "0.10.0" is below
    # "1.0.0" because "0" < "1" at the first component, and "1.0" is
    # below "1.0.0" because a shorter prefix sorts first.
    class GalaxyVersionIncorrectRule < Rule
      MESSAGE = "collection version should be greater than or equal to 1.0.0"

      BASELINE = "1.0.0"

      def id : String
        "galaxy-version-incorrect"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["opt-in", "metadata"]
      end

      def applies_to : Array(FileType)
        [FileType::GALAXY]
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        return if file.parse_error
        root = file.root || return
        # Upstream's matchyaml unwraps a mapping into a one-item list and
        # walks a top-level sequence's items, so each document gets its
        # own version check.
        documents(root).each do |document|
          check_document(document, file, violations)
        end
      end

      private def documents(root : YAML::Nodes::Node) : Array(YAML::Nodes::Mapping)
        case root
        when YAML::Nodes::Mapping
          [root]
        when YAML::Nodes::Sequence
          root.nodes.compact_map(&.as?(YAML::Nodes::Mapping))
        else
          [] of YAML::Nodes::Mapping
        end
      end

      private def check_document(document : YAML::Nodes::Mapping,
                                 file : PositionedFile,
                                 violations : Array(Violation)) : Nil
        entry = NodeUtil.entry(document, "version")
        # A missing version is the rule's other match, reported at the
        # file start with no column: upstream passes no data to position.
        return report(file, 1, 0, violations) unless entry
        node = entry[1]
        case node
        when YAML::Nodes::Mapping
          # Upstream's loader injects a __line__ key into every mapping,
          # so even `version: {}` reads as truthy there and the version
          # comparison raises on a dict.
        when YAML::Nodes::Sequence
          # An empty list is falsy in Python, which matches before the
          # comparison runs; a non-empty one makes it raise.
          report(file, NodeUtil.line(node), NodeUtil.column(node), violations) if node.nodes.empty?
        when YAML::Nodes::Scalar
          check_scalar(node, file, violations)
        end
      end

      private def check_scalar(node : YAML::Nodes::Scalar, file : PositionedFile,
                               violations : Array(Violation)) : Nil
        arg = Arg.new(node)
        case arg.kind
        when :none
          # `version:` and `version: null` load as None, which upstream
          # reports at the file start like a missing key.
          report(file, 1, 0, violations)
        when :bool
          # A Python bool is a singleton carrying no Origin tag, so the
          # position lookup raises for false and the comparison raises for
          # true: neither reports anything.
        when :int, :float
          # Zero is falsy in Python and matches before the comparison
          # runs; any other number makes the comparison raise.
          report(file, NodeUtil.line(node), NodeUtil.column(node), violations) if arg.number == 0
        when :str
          version = arg.text
          if version.empty? || below_baseline?(version)
            report(file, NodeUtil.line(node), NodeUtil.column(node), violations)
          end
        end
      end

      # Upstream's Version compares the component lists element by element
      # as strings, and a shorter prefix counts as smaller.
      private def below_baseline?(version : String) : Bool
        (version.split('.') <=> BASELINE.split('.')) < 0
      end

      private def report(file : PositionedFile, line : Int32, column : Int32,
                         violations : Array(Violation)) : Nil
        violations << Violation.new(file.path, line, column, id, severity, MESSAGE)
      end
    end
  end
end
