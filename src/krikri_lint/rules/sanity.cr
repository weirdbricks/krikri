module Krikri
  module Lint
    # Upstream parity: ansible-lint's sanity rule (severity MEDIUM, tags
    # idiom). A collection's tests/sanity/ignore-*.txt entries must use one
    # of the ignores Partner Engineering allows; an entry under plugins/ or
    # roles/ naming anything else is reported at the entry's own line, and
    # one not shaped like "<path> <ignore>" is reported as badly formatted.
    # Entries outside those two directories are never inspected.
    class SanityRule < Rule
      ALLOWED_IGNORES = %w[
        validate-modules:missing-gplv3-license
        action-plugin-docs
        import-2.6 import-2.6!skip
        import-2.7 import-2.7!skip
        import-3.5 import-3.5!skip
        compile-2.6 compile-2.6!skip
        compile-2.7 compile-2.7!skip
        compile-3.5 compile-3.5!skip
        shebang shellcheck pylint:used-before-assignment
      ]

      # These four ignore-file generations are not checked upstream, and
      # the match is a plain substring of the path, not the file name.
      NO_CHECK_IGNORE_FILES = %w[ignore-2.9 ignore-2.10 ignore-2.11 ignore-2.12]

      CHECK_DIRS = %w[plugins roles]

      def id : String
        "sanity"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["idiom"]
      end

      def applies_to : Array(FileType)
        [FileType::SANITY_IGNORE]
      end

      def non_yaml_lintable? : Bool
        true
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        absolute = File.expand_path(file.path)
        return if NO_CHECK_IGNORE_FILES.any? { |name| absolute.includes?(name) }
        YamlText.physical_lines(file.path).each_with_index do |entry, idx|
          line = idx + 1
          next if entry.empty?
          # Upstream keys on the first path component (up to the first
          # slash) before stripping any trailing comment.
          base = entry.split('/').first
          next unless CHECK_DIRS.includes?(base)
          # Upstream unpacks entry.split("#") and entry.split() and turns
          # either ValueError into the badly-formatted match.
          fields = entry.split('#')
          if fields.size > 2
            violations << bad_ignore(file, line)
            next
          end
          words = fields[0].split
          if words.size != 2
            violations << bad_ignore(file, line)
          elsif !ALLOWED_IGNORES.includes?(words[1])
            violations << Violation.new(file.path, line, 0, "sanity[cannot-ignore]", severity,
              "Ignore file contains #{words[1]} at line #{line}, which is not a permitted ignore.")
          end
        end
      end

      private def bad_ignore(file : PositionedFile, line : Int32) : Violation
        Violation.new(file.path, line, 0, "sanity[bad-ignore]", severity,
          "Ignore file entry at #{line} is formatted incorrectly. Please review.")
      end
    end
  end
end
