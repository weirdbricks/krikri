module Krikri
  module Lint
    # Upstream parity: ansible-lint's meta-no-tags (severity HIGH, tags
    # metadata, shared profile). Upstream calls create_matcherror with
    # only the filename, so every branch reports at file scope (line 1,
    # no column): the whole meta file is matched, not the offending tag.
    class MetaNoTagsRule < Rule
      # Upstream's TAG_REGEXP = re.compile(r"^[a-z0-9]+$")
      TAG_PATTERN = /\A[a-z0-9]+\z/

      SHORT_DESC = "Tags must contain lowercase letters and digits only."

      # PyYAML's implicit resolvers for the plain scalars a tag could be
      # spelled as. Anything else plain stays a string.
      NULL_WORDS    = ["", "~", "null", "Null", "NULL"]
      TRUE_WORDS    = %w[true True TRUE yes Yes YES on On ON]
      FALSE_WORDS   = %w[false False FALSE no No NO off Off OFF]
      INT_PATTERN   = /\A[-+]?\d+\z/
      FLOAT_PATTERN = /\A[-+]?(\d+\.\d*|\.\d+)([eE][-+]?\d+)?\z/

      def id : String
        "meta-no-tags"
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
        info = galaxy_info(file)
        return unless info
        tags = [] of YAML::Nodes::Node
        collect_tags(info, file, violations, tags)
        tags.each { |tag| validate_tag(tag, file, violations) }
      end

      # Upstream only matches when `file.kind == "meta"`, i.e. a
      # `meta/main.yml` path, and reads galaxy_info only when it is a
      # truthy mapping (an empty one is falsy in Python).
      private def galaxy_info(file : PositionedFile) : YAML::Nodes::Mapping?
        return unless meta_main?(file.path)
        root = file.root
        return if root.nil? || file.parse_error
        mapping = root.as?(YAML::Nodes::Mapping)
        return unless mapping
        entry = NodeUtil.entry(mapping, "galaxy_info")
        return unless entry
        info = entry[1].as?(YAML::Nodes::Mapping)
        return unless info
        info.nodes.empty? ? nil : info
      end

      private def collect_tags(info : YAML::Nodes::Mapping, file : PositionedFile,
                               violations : Array(Violation),
                               tags : Array(YAML::Nodes::Node)) : Nil
        if tag_entry = NodeUtil.entry(info, "galaxy_tags")
          collect_list(tag_entry[1], "galaxy_tags", file, violations, tags)
        end

        # Upstream still validates tags spelled with the deprecated key,
        # after warning about the key itself.
        return unless cat_entry = NodeUtil.entry(info, "categories")
        report(violations, file, "Use 'galaxy_tags' rather than 'categories'")
        collect_list(cat_entry[1], "categories", file, violations, tags)
      end

      private def collect_list(value : YAML::Nodes::Node, key : String,
                               file : PositionedFile, violations : Array(Violation),
                               tags : Array(YAML::Nodes::Node)) : Nil
        if seq = value.as?(YAML::Nodes::Sequence)
          tags.concat(seq.nodes)
        else
          report(violations, file, "Expected '#{key}' to be a list")
        end
      end

      private def validate_tag(tag : YAML::Nodes::Node, file : PositionedFile,
                               violations : Array(Violation)) : Nil
        is_string, text = python_repr(tag)
        if !is_string
          report(violations, file, "Tags must be strings: '#{text}'")
        elsif !text.matches?(TAG_PATTERN)
          report(violations, file, "#{SHORT_DESC}, invalid: '#{text}'")
        end
      end

      private def report(violations : Array(Violation), file : PositionedFile,
                         message : String) : Nil
        violations << Violation.new(file.path, 1, 0, id, severity, message)
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

      # The tag as Python would see it after YAML loading, and whether
      # that value is a str. A plain scalar picks up YAML's implicit
      # type (an int/bool/null tag is not a string); a non-string tag's
      # message interpolates the value with Python's str()/repr().
      private def python_repr(node : YAML::Nodes::Node) : {Bool, String}
        case node
        when YAML::Nodes::Scalar
          scalar_repr(node)
        when YAML::Nodes::Sequence
          {false, "[#{node.nodes.map { |child| item_repr(child) }.join(", ")}]"}
        when YAML::Nodes::Mapping
          {false, mapping_repr(node)}
        else
          # YAML aliases resolve to the anchored value upstream.
          {false, "None"}
        end
      end

      private def scalar_repr(node : YAML::Nodes::Scalar) : {Bool, String}
        value = node.value || ""
        return {true, value} unless node.style == YAML::ScalarStyle::PLAIN
        typed_scalar(value)
      end

      private def typed_scalar(value : String) : {Bool, String}
        return {false, "None"} if NULL_WORDS.includes?(value)
        return {false, "True"} if TRUE_WORDS.includes?(value)
        return {false, "False"} if FALSE_WORDS.includes?(value)
        return {false, value.to_i64.to_s} if value.matches?(INT_PATTERN)
        return {false, value} if value.matches?(FLOAT_PATTERN)
        {true, value}
      end

      private def mapping_repr(node : YAML::Nodes::Mapping) : String
        items = [] of String
        NodeUtil.each_entry(node) do |key, child|
          items << "#{item_repr(key)}: #{item_repr(child)}"
        end
        "{#{items.join(", ")}}"
      end

      private def item_repr(node : YAML::Nodes::Node) : String
        is_string, text = python_repr(node)
        is_string ? "'#{text}'" : text
      end
    end
  end
end
