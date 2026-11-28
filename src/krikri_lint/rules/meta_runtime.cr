module Krikri
  module Lint
    # Upstream parity: ansible-lint's meta-runtime family (severity
    # VERY_HIGH, tags metadata, shared profile). ansible-lint carries
    # ansible-core's release matrix as its supported_ansible prefixes and
    # reports a requires_ansible that names none of them, from
    # create_matcherror with only the filename - so the match sits at
    # line 1 with no column, on the file rather than the key.
    #
    # Upstream's sibling meta-runtime[invalid-version] (a PEP 440
    # SpecifierSet check) is a separate sub-rule and not implemented
    # here.
    class MetaRuntimeRule < Rule
      # The prefixes ansible-lint 25.2.1 defaults supported_ansible to,
      # in order (upstream builds the message as ">=" + prefix + "0").
      SUPPORTED_ANSIBLE = %w[2.15. 2.16. 2.17. 2.18.]

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
        [FileType::META]
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        return unless runtime_file?(file.path)
        return if file.parse_error
        mapping = file.root.as?(YAML::Nodes::Mapping)
        return unless mapping
        entry = NodeUtil.entry(mapping, "requires_ansible")
        return unless entry
        requires = entry[1].as?(YAML::Nodes::Scalar).try(&.value)
        # Upstream skips a falsy value, and its `version in requires_ansible`
        # test is a plain substring search, so any supported prefix
        # anywhere in the specifier (even an upper bound) passes.
        return if requires.nil? || requires.empty?
        return if SUPPORTED_ANSIBLE.any? { |prefix| requires.includes?(prefix) }
        supported = SUPPORTED_ANSIBLE.map { |prefix| ">=#{prefix}0" }.join(", ")
        violations << Violation.new(file.path, 1, 0,
          "meta-runtime[unsupported-version]", severity,
          "'requires_ansible' key must refer to a currently supported version such as: #{supported}")
      end

      # Upstream's kind_from_path names `**/meta/runtime.{yml,yaml}`
      # meta-runtime, a sibling of the `**/meta/main.{yml,yaml}` meta
      # pattern. FileType folds both kinds into META, so the file name is
      # what decides whether this rule runs on a given meta file.
      private def runtime_file?(path : String) : Bool
        parts = path.split('/')
        return false unless parts.size >= 2
        name = parts.last
        (name == "runtime.yml" || name == "runtime.yaml") && parts[-2] == "meta"
      end
    end
  end
end
