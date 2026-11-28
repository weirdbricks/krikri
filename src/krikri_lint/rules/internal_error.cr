module Krikri
  module Lint
    # Upstream's catch-all for a load-time failure its syntax check cannot
    # classify. ansible-lint runs `ansible-playbook --syntax-check` and
    # matches the failure against OUTPUT_PATTERNS; in ansible-core
    # 2.21.6's error format every entry except missing-file,
    # empty-playbook and malformed needs an "Origin: <file>:<line>:<col>"
    # line, so a failure without one leaves the exit code unexplained and
    # RuntimeErrorRule reports internal-error instead. The match is the
    # lintable's first line with no column, it marks the file failed (so
    # no other rule runs on it), and it prints as a warning while still
    # counting as a failure - MatchError.level reads "warning" for a rule
    # outside a collection, because such a rule carries no options.
    #
    # No check of its own: the verdict is the run-wide one SyntaxCheck
    # holds (which playbook failed the load, and how), like the
    # syntax-check[unknown-module] matches the runner's gate emits.
    class InternalErrorRule < Rule
      def id : String
        "internal-error"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["core"]
      end

      def applies_to : Array(FileType)
        [FileType::PLAYBOOK]
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
      end

      # The match for a file whose syntax check failed on something no
      # OUTPUT_PATTERNS entry matches. `cause` is the OSError the loader's
      # read raised, rendered the way Python's str() does ("[Errno 21] Is
      # a directory: '<path>'"), which is what upstream's message carries
      # after the "[ERROR]: " prefix it strips.
      def self.read_failure(file : PositionedFile, path : String,
                            cause : String) : Violation
        Violation.new(file.path, 1, 0, "internal-error", Severity::VERY_HIGH,
          "An error occurred while trying to read the file '#{path}': #{cause}",
          nil, false, "", "warning")
      end
    end
  end
end
