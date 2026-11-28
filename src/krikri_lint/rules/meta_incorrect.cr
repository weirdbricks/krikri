module Krikri
  module Lint
    # Upstream parity: ansible-lint's meta-incorrect (severity HIGH, tags
    # metadata, shared profile). Upstream skips any lintable whose kind is
    # not `meta` and any falsey galaxy_info, then reports each field still
    # holding the value `ansible-galaxy init` scaffolds.
    class MetaIncorrectRule < Rule
      # Upstream's field_defaults, in its own order. `license` appears
      # twice because both spellings the scaffolder has shipped are
      # recognized; a value can only equal one of them.
      FIELD_DEFAULTS = [
        {"author", "your name"},
        {"description", "your description"},
        {"company", "your company (optional)"},
        {"license", "license (GPLv2, CC-BY, etc)"},
        {"license", "license (GPL-2.0-or-later, MIT, etc)"},
      ]

      def id : String
        "meta-incorrect"
      end

      def severity : Severity
        Severity::HIGH
      end

      def tags : Array(String)
        ["metadata"]
      end

      def applies_to : Array(FileType)
        [FileType::META]
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        root = meta_root(file)
        return unless root
        entry = NodeUtil.entry(root, "galaxy_info") || return
        info = entry[1].as?(YAML::Nodes::Mapping) || return
        return if info.nodes.empty?
        FIELD_DEFAULTS.each do |(field, default)|
          field_entry = NodeUtil.entry(info, field) || next
          value = NodeUtil.scalar_value(field_entry[1])
          # Upstream's `if value and value == default`: an empty, null or
          # non-scalar value is either falsey or simply unequal.
          next unless value && value == default
          # Upstream hands the whole meta document (not the field) to
          # create_matcherror, so the match sits at the root mapping's
          # line and column.
          violations << Violation.new(file.path, NodeUtil.line(root),
            NodeUtil.column(root), id, severity,
            "Should change default metadata: #{field}")
        end
      end

      # Upstream only matches when `file.kind == "meta"`, i.e. a
      # `meta/main.yml` path, and reads galaxy_info only when it is a
      # truthy mapping (an empty one is falsy in Python).
      private def meta_root(file : PositionedFile) : YAML::Nodes::Mapping?
        return unless meta_main?(file.path)
        return if file.parse_error
        file.root.as?(YAML::Nodes::Mapping)
      end

      # Upstream's kind detection only classifies `meta/main.yml` (or
      # .yaml) as a meta file; role dirs may hold other YAML files that
      # FileType reports as META but upstream lints as plain YAML.
      private def meta_main?(path : String) : Bool
        parts = path.split('/')
        return false unless parts.size >= 2
        name = parts.last
        (name == "main.yml" || name == "main.yaml") && parts[-2] == "meta"
      end
    end
  end
end
