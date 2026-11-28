module Krikri
  module Lint
    # Upstream parity: ansible-lint's meta-video-links (severity LOW, tags
    # metadata, shared profile). Upstream's matchyaml only runs on a
    # `<role>/meta/main.yml` lintable. It walks `galaxy_info.video_links`
    # and, for each entry that is not a dictionary or carries keys other
    # than `url`/`title`, reports and `continue`s past its own URL-format
    # check; create_matcherror anchors such a match at the offending entry
    # itself: the scalar's position, or the first key of the entry's
    # mapping. An unrecognized URL is instead anchored at the url scalar's
    # own line and column, with a positional match rather than a full one
    # (Python's re.match). A missing `url` is not flagged: an entry with
    # only `title` is silent upstream too.
    class MetaVideoLinksRule < Rule
      SHORT_DESC = "Expected it be a shared link from Vimeo, YouTube, or Google Drive."

      NOT_A_DICTIONARY = "Expected item in 'video_links' to be a dictionary"
      UNEXPECTED_KEYS  = "Expected item in 'video_links' to contain only keys 'url' and 'title'"

      ALLOWED_KEYS = ["url", "title"]

      # Upstream's VIDEO_REGEXP, order included: drive.google.com allows any
      # path between the host and `file/d/<id>/`, vimeo accepts a bare digit
      # run, youtu.be a short id, and nothing else (a canonical
      # www.youtube.com/watch?v= URL is rejected).
      LINK_PATTERNS = [
        /\Ahttps:\/\/drive\.google\.com.*file\/d\/[0-9A-Za-z_-]+\/.*/,
        /\Ahttps:\/\/vimeo\.com\/[0-9]+/,
        /\Ahttps:\/\/youtu\.be\/[0-9A-Za-z_-]+/,
      ]

      def id : String
        "meta-video-links"
      end

      def severity : Severity
        Severity::LOW
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
        entry = NodeUtil.entry(info, "video_links") || return
        links = entry[1].as?(YAML::Nodes::Sequence) || return
        links.nodes.each { |link| check_entry(link, file, violations) }
      end

      # Upstream's three checks are exclusive per entry: a shape match
      # reports and moves on, so an entry it already rejected is never
      # also tested for its URL.
      private def check_entry(link : YAML::Nodes::Node, file : PositionedFile,
                              violations : Array(Violation)) : Nil
        item = link.as?(YAML::Nodes::Mapping)
        unless item
          report_entry(violations, file, link, NOT_A_DICTIONARY)
          return
        end
        unless only_allowed_keys?(item)
          report_entry(violations, file, link, UNEXPECTED_KEYS)
          return
        end
        check_link(item, file, violations)
      end

      private def only_allowed_keys?(mapping : YAML::Nodes::Mapping) : Bool
        NodeUtil.each_entry(mapping) do |key, _value|
          name = key.as?(YAML::Nodes::Scalar).try(&.value)
          return false unless name && ALLOWED_KEYS.includes?(name)
        end
        true
      end

      private def check_link(item : YAML::Nodes::Mapping, file : PositionedFile,
                             violations : Array(Violation)) : Nil
        url_entry = NodeUtil.entry(item, "url") || return
        url = NodeUtil.scalar_value(url_entry[1]) || return
        return if LINK_PATTERNS.any? { |pattern| url.matches?(pattern) }
        violations << Violation.new(file.path, NodeUtil.line(url_entry[1]),
          NodeUtil.column(url_entry[1]), id, severity,
          "URL format '#{url}' is not recognized. #{SHORT_DESC}")
      end

      private def report_entry(violations : Array(Violation), file : PositionedFile,
                               node : YAML::Nodes::Node, message : String) : Nil
        violations << Violation.new(file.path, NodeUtil.line(node),
          NodeUtil.column(node), id, severity, message)
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
