module Krikri
  module Lint
    # Byte-for-byte reproduction of upstream's match formatters
    # (ansiblelint/formatters/__init__.py) for the formats krikri-lint
    # exposes. Upstream builds these by pushing BBCode markup through a
    # console renderer; the escape sequences it ends up emitting are
    # spelled out here directly, including the stray trailing resets its
    # markup leaves unbalanced.
    module Formatter
      RULE_DOC_URL = "https://ansible.readthedocs.io/projects/lint/rules/"

      def self.rule_url(violation : Violation) : String
        RULE_DOC_URL + violation.family + "/"
      end

      # Upstream's default "brief" formatter: two lines per match, with
      # the rule id hyperlinked, the path in magenta and the optional
      # task description dimmed, followed by a blank line.
      def self.brief(v : Violation, colored : Bool) : String
        level = v.level == "warning" ? Console::YELLOW : Console::RED
        String.build do |io|
          unless colored
            io << v.rule_id << ": " << v.message
            io << " (warning)" if v.level == "warning"
            io << '\n' << v.path << ':' << v.position
            if v.details != ""
              io << ' ' << v.details
              io << "[/]" if bracketed?(v.details)
            end
            io << '\n'
            next
          end
          io << level << Console.link(rule_url(v), v.rule_id)
          io << Console::DIM << ':' << Console::RESET
          io << ' ' << level << v.message << Console::RESET
          io << ' ' << Console::DIM << level << "(warning)" << Console::RESET if v.level == "warning"
          io << '\n'
          io << Console::MAGENTA << v.path << Console::RESET << ':' << v.position
          if v.details != ""
            io << ' ' << Console::DIM << v.details
            # Upstream renders the text as markup, so a `[word]` inside it
            # (schema[meta]'s blurb quotes `schema[playbook]`) opens a tag
            # it does not know: the closing `[/]` is then emitted
            # literally and the dim reset moves to the end of the block.
            io << (bracketed?(v.details) ? "[/]" : Console::RESET)
          end
          io << '\n'
          # Upstream's markup leaves one level tag unclosed for an error
          # and two for a warning; the renderer closes them at the end,
          # after the final newline.
          resets = v.level == "warning" ? 2 : 1
          resets += 1 if v.details != "" && bracketed?(v.details)
          io << (Console::RESET * resets)
        end
      end

      BRACKETED = /\[[\w.]+\]/

      private def self.bracketed?(text : String) : Bool
        text.matches?(BRACKETED)
      end

      # Upstream's ParseableFormatter (aka `-p`).
      def self.parseable(v : Violation, colored : Bool) : String
        return "#{v.path}:#{v.position}: #{rule_id(v)}: #{v.message}" unless colored
        level = v.level == "warning" ? Console::YELLOW : Console::RED
        String.build do |io|
          io << Console::MAGENTA << v.path << Console::RESET
          io << Console::DIM << ':' << v.position << ':' << Console::RESET
          io << ' ' << level << Console::BOLD
          # A sub-tagged rule id ("name[missing]") is markup to upstream's
          # renderer, which swallows the `[/]` that would have closed the
          # bold tag and prints it literally just before the `]`.
          io << (sub_tagged?(v.rule_id) ? literal_sub_tag(v.rule_id) : v.rule_id)
          io << Console::RESET unless sub_tagged?(v.rule_id)
          io << ": #{v.message}" << Console::RESET
          io << Console::RESET if sub_tagged?(v.rule_id)
        end
      end

      # Whether a rule id carries a sub-tag upstream's markup parser
      # recognizes, e.g. "name[missing]". A group holding anything but
      # word characters and dots (`yaml[new-line-at-end-of-file]`) is not
      # a tag to it and is printed verbatim.
      private def self.sub_tagged?(rule_id : String) : Bool
        rule_id.matches?(BRACKETED)
      end

      # Upstream renders the rule id through its markup parser, so the
      # `[/]` that would have closed the surrounding style tag is printed
      # literally, immediately before the sub-tag's closing bracket.
      private def self.rule_id(v : Violation) : String
        id = v.rule_id
        return id unless sub_tagged?(id)
        literal_sub_tag(id)
      end

      private def self.literal_sub_tag(id : String) : String
        "#{id}[/]"
      end

      # Upstream's QuietFormatter (`-f quiet`): rule id, space, position.
      def self.quiet(v : Violation, colored : Bool) : String
        return "#{v.family} #{v.path}:#{v.position}" unless colored
        level = v.level == "warning" ? Console::YELLOW : Console::RED
        String.build do |io|
          io << level << v.family << Console::RESET
          io << ' ' << Console::MAGENTA << v.path << Console::RESET
          io << ':' << v.position
        end
      end
    end

    # Reproduction of upstream's report_outcome/report_summary output
    # (ansiblelint/app.py): the "Rule Violation Summary" table and the
    # trailing Passed/Failed line, both on stderr.
    class Report
      IGNORE_DOC_URL = "https://ansible.readthedocs.io/projects/lint/configuring/#ignoring-rules-for-entire-files"

      record TagStat, tag : String, count : Int32, order : Int32, tags : Array(String)

      getter failures : Int32
      getter warnings : Int32
      getter files_count : Int32
      getter tag_stats : Array(TagStat)
      getter passed_profile : String
      # Upstream prints this (the first profile that failed, or the last
      # one walked) in every row's `profile:` field rather than the row's
      # own rule profile. Reproduced verbatim so the table matches.
      getter walked_profile : String
      getter rating : Int32

      def initialize(violations : Array(Violation), registry : RuleRegistry,
                     @files_count : Int32, required_profile : String? = nil)
        @required_profile = required_profile
        @failures = 0
        @warnings = 0
        # Upstream reads the categories off the rule *class* that
        # produced the match, so every yaml[*] sub-tag reports the yaml
        # rule's own categories. krikri additionally tags its fixable
        # rules "autofix" so `--fix autofix` can select them; upstream
        # keeps that marker out of the rule's declared categories and
        # never prints it, so it is dropped here too.
        @rule_tags = {} of String => Array(String)
        registry.rules.each do |rule|
          @rule_tags[rule.id.split("[").first] ||= rule.tags.reject { |tag| tag == "autofix" }
        end
        counts = {} of String => TagStat
        violations.each do |v|
          stats = counts[v.rule_id]?
          counts[v.rule_id] = if stats
                                TagStat.new(v.rule_id, stats.count + 1, stats.order, stats.tags)
                              else
                                TagStat.new(v.rule_id, 1, Profile.order(v.rule_id),
                                  @rule_tags[v.family]? || [] of String)
                              end
          if v.warning?
            @warnings += 1
          else
            @failures += 1
          end
        end
        # Upstream sorts by (profile order index, tag).
        @tag_stats = counts.values.sort_by! { |stat| {stat.order, stat.tag} }

        failed = Set(String).new
        @tag_stats.each do |stat|
          profile = Profile.of(stat.tag)
          failed << profile if profile
        end
        @passed_profile = ""
        passed_count = 0
        walked = Profile::SUMMARY_PROFILES.last
        Profile::SUMMARY_PROFILES.each do |name|
          if failed.includes?(name)
            walked = name
            break
          end
          walked = name
          if name != @passed_profile
            @passed_profile = name
            passed_count += 1
          end
        end
        @walked_profile = walked
        @rating = 5 - (Profile::SUMMARY_PROFILES.size - passed_count)
      end

      # The whole stderr block, each entry one line.
      def lines(colored : Bool) : Array(String)
        result = [""]
        unless @tag_stats.empty?
          result << "# Rule Violation Summary"
          result << ""
          @tag_stats.each do |stats|
            link = Console.link(Formatter::RULE_DOC_URL, stats.tag.split("[").first, colored)
            tail = "profile:#{@walked_profile} tags:#{stats.tags.join(",")}"
            result << "#{stats.count.to_s.rjust(3)} #{link}#{colored ? " " + Console::DIM + tail + Console::RESET : " " + tail}"
          end
          result << ""
        end
        result << outcome(colored)
        result
      end

      private def outcome(colored : Bool) : String
        String.build do |io|
          if @failures > 0
            if colored
              io << Console::RED << Console::BOLD << "Failed" << Console::RESET * 2
            else
              io << "Failed"
            end
          elsif colored
            io << Console::GREEN << "Passed" << Console::RESET
          else
            io << "Passed"
          end
          io << ": #{@failures} failure(s), #{@warnings} warning(s)"
          io << " on #{@files_count} files."
          if required = @required_profile
            io << " Profile '#{required}' was required"
            if @passed_profile.empty?
              io << "."
            elsif @passed_profile == required
              io << ", and it passed."
            else
              io << ", but '#{@passed_profile}' profile passed."
            end
          elsif !@passed_profile.empty?
            io << " Last profile that met the validation criteria was '#{@passed_profile}'."
          end
          io << " Rating: #{@rating}/5 star" if stars?
          io
        end
      end

      # Upstream only computes a star rating when there is at least one
      # tag stat, and drops the rating when it lands outside 1..5.
      private def stars? : Bool
        !@tag_stats.empty? && @rating > 0 && @rating < 6
      end
    end

    # Presentation helpers the CLI driver applies to the whole match list.
    module Outcome
      extend self

      # Matches sorted the way upstream lists them: by position, then by
      # the rule that produced the match (upstream's rule execution order
      # is the rule ids' alphabetical order). The two load-failure matches
      # of a missing target keep upstream's own order, not the ids'.
      def sort(violations : Array(Violation)) : Array(Violation)
        violations.sort_by! do |v|
          {v.path, v.line, v.column, load_failure_seq(v.rule_id), v.rule_id}
        end
      end

      private def load_failure_seq(rule_id : String) : Int32
        case rule_id
        when "load-failure[not-found]"         then 0
        when "load-failure[filenotfounderror]" then 1
        when "load-failure[runtimeerror]"      then 2
        else                                        3
        end
      end

      # Upstream only prints the ignore-docs hint when at least one
      # skippable rule matched; unskippable matches (load-failure) alone
      # suppress it.
      def skippable?(violations : Array(Violation), registry : RuleRegistry) : Bool
        violations.any? do |v|
          next false unless rule = registry.rules.find { |cand| cand.id == v.rule_id || cand.id == v.family }
          !rule.tags.includes?("unskippable")
        end
      end
    end
  end
end
