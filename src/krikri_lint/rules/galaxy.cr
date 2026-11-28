module Krikri
  module Lint
    # Upstream parity: ansible-lint's galaxy family (severity MEDIUM,
    # tags metadata, shared profile), eight checks over a collection's
    # galaxy.yml. Upstream reaches them from matchplay and passes only
    # the filename to create_matcherror, so every match sits at file
    # scope (line 1, no column) except galaxy[version-missing], whose
    # match carries the loaded mapping's own position: ansible-core tags
    # a mapping with the first key's line and column 1, so a galaxy.yml
    # starting with a comment or `---` reports at 2:1 rather than 1:1.
    #
    # The checks run in upstream's order - dependencies, changelog,
    # tags, tags-format, tags-length, tags-count, then version-missing,
    # which returns before the no-runtime check. A galaxy.yml with no
    # version therefore never also reports a missing meta/runtime.yml.
    class GalaxyRule < Rule
      # The list Automation Hub Team and Partner Engineering require a
      # collection to carry at least one of, in upstream's order.
      REQUIRED_TAGS = %w[
        application cloud database eda infrastructure linux monitoring
        networking security storage tools windows
      ]

      # Upstream's TAG_NAME_REGEXP: lowercase ASCII letters, digits and
      # single underscores, never starting with a digit or an underscore.
      TAG_NAME_PATTERN = /^(?!.*__)[a-z][0-9a-z_]*$/

      MAX_LENGTH_TAG = 64
      MAX_TAGS_COUNT = 20

      # The collection-level changelog files upstream accepts, relative
      # to galaxy.yml's own directory.
      CHANGELOGS = %w[
        changelogs/changelog.yaml
        changelogs/changelog.yml
        CHANGELOG.rst
        CHANGELOG.md
      ]

      # Upstream skips a dependency entry keyed with a loaded YAML
      # mapping's own bookkeeping fields.
      LINE_NUMBER_KEY = "__line__"
      FILENAME_KEY    = "__file__"

      # PyYAML's implicit resolvers for plain scalars, as far as they
      # decide whether a value is a Python str: a tag or dependency key
      # spelled as a null/bool/int/float is not, and upstream's regex on
      # it raises.
      NULL_WORDS    = ["", "~", "null", "Null", "NULL"]
      TRUE_WORDS    = %w[true True TRUE yes Yes YES on On ON]
      FALSE_WORDS   = %w[false False FALSE no No NO off Off OFF]
      INT_PATTERN   = /\A[-+]?\d+\z/
      FLOAT_PATTERN = /\A[-+]?(\d+\.\d*|\.\d+)([eE][-+]?\d+)?\z/

      def id : String
        "galaxy"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["metadata"]
      end

      def applies_to : Array(FileType)
        [FileType::GALAXY]
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        root = file.root
        return if root.nil? || file.parse_error
        mapping = root.as?(YAML::Nodes::Mapping)
        return unless mapping
        # Both lists are read before upstream appends anything, and a
        # value its iteration cannot handle raises out of the whole
        # rule: a null `tags` silences even the changelog check.
        tags = tag_list(mapping) || return
        dependencies = dependency_list(mapping) || return
        base = File.dirname(File.expand_path(file.path))
        check_dependencies(dependencies, file, violations)
        check_changelog(base, file, violations)
        check_tags(tags, file, violations)
        unless NodeUtil.entry(mapping, "version")
          violations << Violation.new(file.path, NodeUtil.line(mapping), 1,
            "galaxy[version-missing]", severity, "galaxy.yaml should have version tag.")
          return
        end
        check_runtime(base, file, violations)
      end

      # Upstream walks every `dependencies` entry whose version prints as
      # an empty string. `str(ver).strip()` spells a null as "None", so
      # only an empty or whitespace-only string counts.
      private def check_dependencies(dependencies : Array({String, YAML::Nodes::Node}),
                                     file : PositionedFile,
                                     violations : Array(Violation)) : Nil
        dependencies.each do |name, version|
          next if name == LINE_NUMBER_KEY || name == FILENAME_KEY
          next unless blank_version?(version)
          violations << report(file, "galaxy[invalid-dependency-version]",
            "Invalid collection metadata. Dependency version spec range is invalid for '#{name}'.")
        end
      end

      private def check_changelog(base : String, file : PositionedFile,
                                  violations : Array(Violation)) : Nil
        return if CHANGELOGS.any? { |path| File.file?(File.join(base, path)) }
        violations << report(file, "galaxy[no-changelog]",
          "No changelog found. Please add a changelog file. Refer to the galaxy.md file for more info.")
      end

      private def check_tags(tags : Array(String), file : PositionedFile,
                             violations : Array(Violation)) : Nil
        unless tags.any? { |tag| REQUIRED_TAGS.includes?(tag) }
          violations << report(file, "galaxy[tags]",
            "galaxy.yaml must have one of the required tags: #{python_list(REQUIRED_TAGS)}")
        end
        invalid_format = tags.reject { |tag| tag.matches?(TAG_NAME_PATTERN) }
        unless invalid_format.empty?
          violations << report(file, "galaxy[tags-format]",
            "galaxy.yaml must have properly formatted tags. Invalid tags: #{invalid_format.join(",")}")
        end
        invalid_length = tags.select { |tag| tag.chars.size > MAX_LENGTH_TAG }
        unless invalid_length.empty?
          violations << report(file, "galaxy[tags-length]",
            "galaxy.yaml tags must not exceed #{MAX_LENGTH_TAG} characters. " \
            "Invalid tags: #{invalid_length.join(",")}")
        end
        return unless tags.size > MAX_TAGS_COUNT
        violations << report(file, "galaxy[tags-count]",
          "galaxy.yaml exceeds #{MAX_TAGS_COUNT} tags. Current count: #{tags.size}")
      end

      # Upstream checks for meta/runtime.yml only, not the .yaml spelling
      # its meta-runtime kind accepts.
      private def check_runtime(base : String, file : PositionedFile,
                                violations : Array(Violation)) : Nil
        return if File.file?(File.join(base, "meta", "runtime.yml"))
        violations << report(file, "galaxy[no-runtime]", "meta/runtime.yml file not found.")
      end

      private def report(file : PositionedFile, id : String, message : String) : Violation
        Violation.new(file.path, 1, 0, id, severity, message)
      end

      # Python's list repr, which upstream interpolates into the
      # required-tags message.
      private def python_list(values : Array(String)) : String
        "[#{values.map { |value| "'#{value}'" }.join(", ")}]"
      end

      # Upstream iterates whatever `tags` holds: a list gives its items,
      # a scalar string its characters (a `tags: not_a_list` therefore
      # reports the two underscores), a mapping its keys. A tag that is
      # not a Python str makes the format regex raise, dropping every
      # match for the file - nil stands for that.
      private def tag_list(mapping : YAML::Nodes::Mapping) : Array(String)?
        entry = NodeUtil.entry(mapping, "tags")
        return [] of String unless entry
        node = entry[1]
        if sequence = node.as?(YAML::Nodes::Sequence)
          sequence_tags(sequence)
        elsif keys = node.as?(YAML::Nodes::Mapping)
          mapping_tags(keys)
        elsif scalar = node.as?(YAML::Nodes::Scalar)
          scalar_tags(scalar)
        end
      end

      private def sequence_tags(sequence : YAML::Nodes::Sequence) : Array(String)?
        tags = [] of String
        sequence.nodes.each do |item|
          scalar = item.as?(YAML::Nodes::Scalar) || return nil
          return nil unless string_scalar?(scalar)
          tags << (scalar.value || "")
        end
        tags
      end

      private def mapping_tags(keys : YAML::Nodes::Mapping) : Array(String)?
        tags = [] of String
        NodeUtil.each_entry(keys) do |key, _value|
          scalar = key.as?(YAML::Nodes::Scalar) || return nil
          return nil unless string_scalar?(scalar)
          tags << (scalar.value || "")
        end
        tags
      end

      private def scalar_tags(scalar : YAML::Nodes::Scalar) : Array(String)?
        return nil unless string_scalar?(scalar)
        (scalar.value || "").chars.map(&.to_s)
      end

      # Upstream enters the dependency check only for a truthy
      # `dependencies` and then calls `.items()` on it, so a non-empty
      # list, scalar or bool raises the same way and drops the family.
      private def dependency_list(mapping : YAML::Nodes::Mapping) : Array({String, YAML::Nodes::Node})?
        entry = NodeUtil.entry(mapping, "dependencies")
        return [] of {String, YAML::Nodes::Node} unless entry
        return [] of {String, YAML::Nodes::Node} if falsy?(entry[1])
        deps = entry[1].as?(YAML::Nodes::Mapping) || return nil
        list = [] of {String, YAML::Nodes::Node}
        NodeUtil.each_entry(deps) do |key, version|
          scalar = key.as?(YAML::Nodes::Scalar) || return nil
          return nil unless string_scalar?(scalar)
          list << {scalar.value || "", version}
        end
        list
      end

      private def blank_version?(node : YAML::Nodes::Node) : Bool
        scalar = node.as?(YAML::Nodes::Scalar) || return false
        string_scalar?(scalar) && (scalar.value || "").strip.empty?
      end

      private def string_scalar?(scalar : YAML::Nodes::Scalar) : Bool
        return true unless scalar.style == YAML::ScalarStyle::PLAIN
        value = scalar.value || ""
        return false if NULL_WORDS.includes?(value)
        return false if TRUE_WORDS.includes?(value) || FALSE_WORDS.includes?(value)
        return false if value.matches?(INT_PATTERN) || value.matches?(FLOAT_PATTERN)
        true
      end

      # Python truthiness of the loaded value: a null, zero, empty string,
      # empty list or empty mapping is falsy.
      private def falsy?(node : YAML::Nodes::Node) : Bool
        case node
        when YAML::Nodes::Scalar
          value = node.value || ""
          if node.style == YAML::ScalarStyle::PLAIN
            return true if NULL_WORDS.includes?(value) || FALSE_WORDS.includes?(value)
            return false if TRUE_WORDS.includes?(value)
            return value.to_i64 == 0 if value.matches?(INT_PATTERN)
            return value.to_f64 == 0.0 if value.matches?(FLOAT_PATTERN)
          end
          value.empty?
        when YAML::Nodes::Sequence, YAML::Nodes::Mapping
          node.nodes.empty?
        else
          true
        end
      end
    end
  end
end
