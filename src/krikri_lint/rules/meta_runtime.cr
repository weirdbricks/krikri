module Krikri
  module Lint
    # Upstream parity: ansible-lint's meta-runtime family (severity
    # VERY_HIGH, tags metadata, shared profile). Both sub-rules read a
    # `<dir>/meta/runtime.{yml,yaml}` file's `requires_ansible`:
    #
    #   * unsupported-version: the value names none of ansible-lint's
    #     supported_ansible prefixes (a plain substring search upstream),
    #   * invalid-version: the value is not a PEP 440 requirement
    #     specification, i.e. packaging's SpecifierSet raises for it.
    #
    # Both come from create_matcherror with only the filename, so each
    # match sits at line 1 with no column, on the file rather than the key.
    # Upstream tries the supported-prefix test before the specifier parse,
    # so a value that fails both reports unsupported-version first.
    class MetaRuntimeRule < Rule
      # The prefixes ansible-lint 25.2.1 defaults supported_ansible to,
      # in order (upstream builds the message as ">=" + prefix + "0").
      SUPPORTED_ANSIBLE = %w[2.15. 2.16. 2.17. 2.18.]

      INVALID_VERSION_MESSAGE = "'requires_ansible' is not a valid requirement specification"

      def id : String
        "meta-runtime"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["metadata"]
      end

      def applies_to : Array(FileType)
        [FileType::META_RUNTIME]
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        root = file.root
        return if root.nil? || file.parse_error
        mapping = root.as?(YAML::Nodes::Mapping)
        return unless mapping
        entry = NodeUtil.entry(mapping, "requires_ansible")
        return unless entry
        requires = string_value(entry[1])
        return if requires.nil? || requires.empty?
        check_supported(requires, file, violations)
        check_invalid(requires, file, violations)
      end

      # Upstream tests `version in requires_ansible`, a substring search,
      # so a supported version only bounding the range also passes.
      private def check_supported(requires : String, file : PositionedFile,
                                  violations : Array(Violation)) : Nil
        return if SUPPORTED_ANSIBLE.any? { |prefix| requires.includes?(prefix) }
        supported = SUPPORTED_ANSIBLE.map { |prefix| ">=#{prefix}0" }.join(", ")
        violations << Violation.new(file.path, 1, 0,
          "#{id}[unsupported-version]", severity,
          "'requires_ansible' key must refer to a currently supported version such as: #{supported}")
      end

      private def check_invalid(requires : String, file : PositionedFile,
                                violations : Array(Violation)) : Nil
        return if RequirementSpecifier.valid?(requires)
        violations << Violation.new(file.path, 1, 0,
          "#{id}[invalid-version]", severity, INVALID_VERSION_MESSAGE)
      end

      # Upstream reads the loaded YAML value, so a falsy one (missing,
      # empty or null) skips the check, and a non-string truthy one (a
      # bool, number, mapping) makes the checks raise - no match either way.
      private def string_value(node : YAML::Nodes::Node) : String?
        scalar = node.as?(YAML::Nodes::Scalar) || return nil
        value = scalar.value || ""
        return nil if scalar.style == YAML::ScalarStyle::PLAIN && !plain_string?(value)
        value
      end

      NULL_WORDS    = ["", "~", "null", "Null", "NULL"]
      TRUE_WORDS    = %w[true True TRUE yes Yes YES on On ON]
      FALSE_WORDS   = %w[false False FALSE no No NO off Off OFF]
      INT_PATTERN   = /\A[-+]?\d+\z/
      FLOAT_PATTERN = /\A[-+]?(\d+\.\d*|\.\d+)([eE][-+]?\d+)?\z/

      private def plain_string?(value : String) : Bool
        return false if NULL_WORDS.includes?(value)
        return false if TRUE_WORDS.includes?(value) || FALSE_WORDS.includes?(value)
        return false if value.matches?(INT_PATTERN) || value.matches?(FLOAT_PATTERN)
        true
      end
    end

    # The part of packaging.specifiers.SpecifierSet that the meta-runtime
    # check exercises: split on commas, drop the empty items (so a
    # trailing comma is tolerated), and require each remaining item to
    # match Specifier's operator + version regex.
    #
    # Operators are matched in packaging's alternation order. `==` wins
    # over `===` there, and its identity branch accepts any characters
    # except whitespace, `;` and `)`, so every `==`-prefixed item is
    # validated that way.
    module RequirementSpecifier
      extend self

      OPERATORS = ["==", "~=", "!=", "<=", ">=", "<", ">"]

      # No operator at all is what makes `~2.15.0` (a single tilde)
      # invalid while `>=2.15.0` parses.
      def valid?(text : String) : Bool
        specs = text.split(',').map(&.strip).reject(&.empty?)
        specs.all? { |spec| valid_specifier?(spec) }
      end

      private def valid_specifier?(spec : String) : Bool
        operator = OPERATORS.find { |op| spec.starts_with?(op) } || return false
        version = spec[operator.size..]
        case operator
        when "==" then ARBITRARY.matches?(version)
        when "~=" then COMPATIBLE_VERSION.matches?(version)
        when "!=" then EQUAL_VERSION.matches?(version)
        else           PLAIN_VERSION.matches?(version)
        end
      end

      EPOCH   = "(?:[0-9]+!)?"
      RELEASE = "[0-9]+(?:\\.[0-9]+)*"
      PRE     = "(?:[-_.]?(?:alpha|beta|preview|pre|a|b|c|rc)[-_.]?[0-9]*)?"
      POST    = "(?:(?:-[0-9]+)|(?:[-_.]?(?:post|rev|r)[-_.]?[0-9]*))?"
      DEV     = "(?:[-_.]?dev[-_.]?[0-9]*)?"
      LOCAL   = "(?:\\+[a-z0-9]+(?:[-_.][a-z0-9]+)*)?"

      ARBITRARY = /\A\s*[^\s;)]*\s*\z/

      # (Non)equality items may name a local version or use a `.*`
      # wildcard.
      EQUAL_VERSION = Regex.new(
        "\\A\\s*v?#{EPOCH}#{RELEASE}(?:\\.\\*|#{PRE}#{POST}#{DEV}#{LOCAL})?\\s*\\z",
        Regex::Options::IGNORE_CASE)
      # The compatible operator needs at least two release segments and
      # allows neither a wildcard nor a local version.
      COMPATIBLE_VERSION = Regex.new(
        "\\A\\s*v?#{EPOCH}[0-9]+(?:\\.[0-9]+)+#{PRE}#{POST}#{DEV}\\s*\\z",
        Regex::Options::IGNORE_CASE)
      # The remaining operators allow only a plain PEP 440 release.
      PLAIN_VERSION = Regex.new(
        "\\A\\s*v?#{EPOCH}#{RELEASE}#{PRE}#{POST}#{DEV}\\s*\\z",
        Regex::Options::IGNORE_CASE)
    end
  end
end
