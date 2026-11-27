module Krikri
  module Lint
    # Inline suppression comments (`# noqa`, `# noqa: rule[,rule]`).
    # Mirrors upstream: a comment on the violation's line or anywhere in
    # the enclosing task (between the task's start line and the
    # violation line) suppresses it.
    module Noqa
      NOQA_RE = /#\s*noqa(?::\s*(?<ids>.*))?/

      # ansible-lint's RENAMED_TAGS (constants.py): a `# noqa:` naming a
      # legacy id is rewritten to the current rule name before the skip
      # list is consulted (skip_utils.get_rule_skips_from_line), so
      # `# noqa: 301` suppresses no-changed-when. Upstream normalizes twice
      # (once per tag read, once for the whole list), so a value that is
      # itself an old id keeps being rewritten: 302 -> deprecated-command-
      # syntax -> no-free-form, which is the rule that actually gets skipped.
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

      record Entry, all : Bool, ids : Array(String)

      def self.build_map(source : String) : Hash(Int32, Entry)
        map = {} of Int32 => Entry
        source.each_line.with_index do |line, idx|
          if (m = line.match(NOQA_RE))
            ids_text = m["ids"]?
            if ids_text.nil? || ids_text.strip.empty?
              map[idx + 1] = Entry.new(true, [] of String)
            else
              ids = ids_text.split(/[\s,]+/).reject(&.empty?).map { |id| current_tag(id) }
              map[idx + 1] = Entry.new(false, ids)
            end
          end
        end
        map
      end

      # The id a skip entry refers to today. Upstream normalizes a comment's
      # tags twice, so a source that is itself a target of another rename
      # (`deprecated-command-syntax`) resolves to its final name, while the
      # table itself stays cycle-free.
      def self.current_tag(id : String) : String
        while (renamed = RENAMED_TAGS[id]?)
          id = renamed
        end
        id
      end

      # The enclosing task's line span, when known: a `# noqa:` anywhere
      # between the task's first and last line suppresses its
      # violations, matching upstream, which walks every comment in the
      # task's YAML subtree.
      def self.suppresses?(map : Hash(Int32, Entry), line : Int32,
                           task_line : Int32?, rule_id : String,
                           task_end_line : Int32? = nil) : Bool
        lines = [line]
        if tl = task_line
          last = task_end_line || line
          (tl..last).each { |number| lines << number }
        end
        family = rule_id.split("[").first
        lines.each do |line_number|
          if (entry = map[line_number]?)
            return true if entry.all
            return true if entry.ids.includes?(rule_id)
            # A comment naming the rule family ("# noqa: run-once")
            # suppresses every sub-tag it emits ("run-once[task]"),
            # the same way upstream skips the whole rule up front.
            return true if entry.ids.includes?(family)
          end
        end
        false
      end
    end
  end
end
