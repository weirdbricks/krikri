module Krikri
  module Lint
    # Upstream parity: ansible-lint's internal `warning` rule
    # (`WarningRule` in ansiblelint/_internal/rules.py, tags
    # core+experimental, severity LOW, unloadable). Its only match so far
    # is warning[outdated-tag], which the inline-skip parser raises when a
    # `# noqa` names a tag ansible-lint has since renamed: the tag is
    # mapped to its current name (so the suppression still works) and the
    # rename is warned about once per legacy tag per run.
    #
    # The match is raised outside the per-rule pipeline upstream, after
    # the skip list and the per-line skips are applied, so no `-x` entry
    # or `# noqa` can drop it; the default warn_list's "experimental"
    # entry is what makes it a warning rather than a failure.
    class OutdatedTagRule < Rule
      # ansible-lint 25.2.1's RENAMED_TAGS (ansiblelint/constants.py),
      # baked in: krikri never consults an installed ansible-lint.
      RENAMED_TAGS = {
        "102"                       => "no-jinja-when",
        "104"                       => "deprecated-bare-vars",
        "105"                       => "deprecated-module",
        "106"                       => "role-name",
        "202"                       => "risky-octal",
        "203"                       => "no-tabs",
        "205"                       => "playbook-extension",
        "206"                       => "jinja[spacing]",
        "207"                       => "jinja[invalid]",
        "208"                       => "risky-file-permissions",
        "301"                       => "no-changed-when",
        "302"                       => "deprecated-command-syntax",
        "303"                       => "command-instead-of-module",
        "304"                       => "inline-env-var",
        "305"                       => "command-instead-of-shell",
        "306"                       => "risky-shell-pipe",
        "401"                       => "latest[git]",
        "402"                       => "latest[hg]",
        "403"                       => "package-latest",
        "404"                       => "no-relative-paths",
        "501"                       => "partial-become",
        "502"                       => "name[missing]",
        "503"                       => "no-handler",
        "504"                       => "deprecated-local-action",
        "505"                       => "missing-import",
        "601"                       => "literal-compare",
        "602"                       => "empty-string-compare",
        "702"                       => "meta-no-tags",
        "703"                       => "meta-incorrect",
        "704"                       => "meta-video-links",
        "911"                       => "syntax-check",
        "deprecated-command-syntax" => "no-free-form",
        "fqcn-builtins"             => "fqcn[action-core]",
        "git-latest"                => "latest[git]",
        "hg-latest"                 => "latest[hg]",
        "no-jinja-nesting"          => "jinja[invalid]",
        "no-loop-var-prefix"        => "loop-var-prefix",
        "unnamed-task"              => "name[missing]",
        "var-spacing"               => "jinja[spacing]",
      }

      # Tags already reported in this run. Upstream holds the same set
      # module-globally (`_found_deprecated_tags`), so later sightings of
      # a legacy tag are silent whichever file they are in - and a run
      # that rewrites files (--fix) reports each tag only once.
      @found = Set(String).new

      def id : String
        "warning"
      end

      def severity : Severity
        Severity::LOW
      end

      def tags : Array(String)
        ["core", "experimental"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      # Upstream's internal warning rule is never unloaded: not by a
      # profile filter and not by a tag filter, and neither the skip list
      # nor a `# noqa` reaches its matches (they are raised after all three
      # were applied).
      def unloadable? : Bool
        true
      end

      def suppressible? : Bool
        false
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        return unless File.exists?(file.path)
        continuation = YamlText.scalar_continuation_lines(file)
        # A `# noqa` comment above the document's first node never
        # reaches upstream's parser at all: ruamel keeps it out of the
        # comment maps both of its scans walk, so a leading tag is
        # neither warned about nor honoured as a skip.
        first_content_line = NodeUtil.line(file.root)
        # Upstream raises the match from three different passes and the
        # first one to see a tag fixes its reported line: the per-task
        # comment scan (a comment's own line), the comment-map dump (the
        # default line 1) and each rule's matchlines walk (line 1 again,
        # for a `# noqa` that is scalar text rather than a comment, like
        # one inside a block scalar). Visiting the passes in that order
        # reproduces which of the sightings is the reported one.
        inline = [] of Occurrence
        comment_lines = [] of Occurrence
        scalar_text = [] of Occurrence
        YamlText.physical_lines(file.path).each_with_index do |text, idx|
          line_number = idx + 1
          # Inside a multi-line scalar a `#` is scalar text, so only the
          # matchlines pass can see it.
          comment_at = continuation.includes?(line_number) ? text.size : YamlText.comment_start(text)
          if tags = noqa_tags(text, comment_at)
            if text[0...comment_at].blank?
              next if line_number < first_content_line
              tags.each { |tag| comment_lines << Occurrence.new(1, tag) }
            else
              # A child lintable is only opened by the first rule's
              # matchlines walk, which has the default line; an explicit
              # one is parsed before any rule runs, so its comment scan
              # still knows the comment's line.
              tags.each { |tag| inline << Occurrence.new(file.explicit? ? line_number : 1, tag) }
            end
          elsif (offset = text.index("# noqa")) && (tags = noqa_tags(text, offset))
            tags.each { |tag| scalar_text << Occurrence.new(1, tag) }
          end
        end
        {inline, comment_lines, scalar_text}.each do |occurrences|
          occurrences.each { |occurrence| report(file, occurrence, violations) }
        end
      end

      private def report(file : PositionedFile, occurrence : Occurrence,
                         violations : Array(Violation)) : Nil
        legacy = occurrence.tag
        current = RENAMED_TAGS[legacy]?
        return if current.nil? || @found.includes?(legacy)
        @found << legacy
        # Upstream's unloadable warning rule has no rule config, so its
        # matches always render at the warning level; the warn_list
        # decides only whether they count as failures (see Report).
        violations << Violation.new(file.path, occurrence.line,
          0, "warning[outdated-tag]", severity,
          "Replaced outdated tag '#{legacy}' with '#{current}', " \
          "replace it to avoid future errors", nil, false, "", "warning")
      end

      private record Occurrence, line : Int32, tag : String

      # The tags a `# noqa` marker at `index` names, split the way
      # upstream's `line.partition("# noqa")` + `.lstrip(" :").split()`
      # does, so a comma-separated list ("# noqa: 301,302") is a single
      # unmapped token, exactly as upstream reads it. Nil when no marker
      # sits at `index` or it is not a standalone word.
      private def noqa_tags(text : String, index : Int32) : Array(String)?
        marker = "# noqa"
        return nil if index >= text.size
        return nil unless text[index..].starts_with?(marker)
        after = text[(index + marker.size)..]
        return nil unless after.empty? || after[0].whitespace? || after[0] == ':'
        after.lstrip(" :").split
      end
    end
  end
end
