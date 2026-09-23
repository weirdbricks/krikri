module Krikri
  module PluginHelpers
    # LineEditor - pure line-matching/insertion logic for the lineinfile
    # plugin, factored out so it can be unit tested without touching the
    # filesystem or going through the plugin's stdin/stdout protocol.
    module LineEditor
      def self.matches_regexp?(line : String, pattern : String?) : Bool
        return false unless pattern
        regex = Regex.new(pattern)
        !!(line =~ regex)
      rescue
        false
      end

      def self.lines_equal?(a : String, b : String) : Bool
        a.strip == b.strip
      end

      # state: absent - drop every line matching regexp, containing
      # search_string (literal substring - real Ansible's own matcher for
      # state=absent), or - failing both - an exact match against `line`.
      # firstmatch does NOT apply here: real Ansible removes ALL matching
      # lines regardless (live-verified against ansible-core 2.19.4).
      # Returns {new_lines, changed}.
      def self.remove_matching(lines : Array(String), line : String?, regexp : String?, search_string : String? = nil) : {Array(String), Bool}
        changed = false
        kept = lines.reject do |existing|
          should_remove = if regexp
                            matches_regexp?(existing, regexp)
                          elsif search_string
                            existing.includes?(search_string)
                          elsif line
                            lines_equal?(existing, line)
                          else
                            false
                          end

          changed ||= should_remove
          should_remove
        end

        {kept, changed}
      end

      # state: present - ensure `line` (or a regexp-matched line, optionally
      # rewritten via backrefs) exists, inserting at insertafter/insertbefore
      # if it's missing. Returns {new_lines, changed}.
      #
      # `search_string` is the literal-substring alternative to `regexp`
      # (real Ansible's own argument_spec marks them mutually exclusive,
      # so this only ever sees one of the two). `firstmatch` switches the
      # replacement/insertion target from real Ansible's default LAST
      # match to the FIRST (live-verified against ansible-core 2.19.4:
      # both the regexp/search_string replacement target and the
      # insertafter/insertbefore anchor honor it, state=absent does not -
      # there it removes every matching line regardless).
      def self.ensure_present(
        lines : Array(String),
        line : String,
        regexp : String?,
        backrefs : Bool,
        insertafter : String?,
        insertbefore : String?,
        firstmatch : Bool = false,
        search_string : String? = nil,
      ) : {Array(String), Bool}
        new_lines = lines.dup

        if regexp
          pattern = regexp
          # Real Ansible's lineinfile (state=present) replaces only the LAST
          # line matching the regexp, not the first. Found live benchmarking
          # geerlingguy.phpmyadmin: its `Add default username and password`
          # lineinfile tasks (regexp `^.+\[['"]host['"]\].+$`) target lines
          # that appear BOTH in the package's populated server block
          # (`...['host'] = $dbserver;`) and as a commented template near
          # EOF (`// ...['host'] = 'localhost';`). Real ansible rewrites the
          # final (commented) occurrence, leaving the active one alone;
          # crystal previously replaced the FIRST, leaving the template
          # commented and diverging config.inc.php byte-for-byte.
          # firstmatch: true flips this to the FIRST matching line
          # (live-verified against ansible-core 2.19.4).
          found_index = match_index(new_lines, pattern, firstmatch)
        elsif search_string
          # search_string: literal substring containment, not a regex -
          # same last-match-by-default / first-with-firstmatch semantics
          # as regexp (live-verified against ansible-core 2.19.4).
          found_index = match_index(new_lines, search_string, firstmatch, literal: true)
        end

        if found_index
          if backrefs && pattern
            # Real Ansible's lineinfile backrefs mode treats `line:` as
            # a REPLACEMENT TEMPLATE for the WHOLE line (Python's
            # `match.expand(line)`, then the entire existing line is
            # overwritten by that expanded text) - not a per-match
            # substring substitution. `String#gsub(Regex, String)`
            # does the latter: it only replaces the SPAN the regexp
            # actually matched and leaves whatever wasn't matched
            # (e.g. the rest of the line after a regexp that only
            # matches a line's leading portion) appended verbatim.
            # Real bug found benchmarking riemers.gitlab-runner's own
            # "Set concurrent option": `regexp: ^(\s*)concurrent =`,
            # `line: \1concurrent = 5`, backrefs: true against the
            # existing "concurrent = 1" - the regexp only matches the
            # "concurrent =" prefix, so gsub replaced just that span
            # and left the un-matched " 1" tail in place, producing
            # the corrupt "concurrent = 5 1" (invalid TOML - gitlab-
            # runner itself then failed to parse its own config on
            # every later run: "expected a top-level item to end with
            # a newline, comment, or EOF, but got '1' instead").
            match = Regex.new(pattern).match(new_lines[found_index])
            expanded = match ? expand_backref_template(line, match) : line
            changed = expanded != new_lines[found_index]
            new_lines[found_index] = expanded
            return {new_lines, changed}
          else
            changed = new_lines[found_index] != line
            new_lines[found_index] = line
            return {new_lines, changed}
          end
        end

        # backrefs: line contains backreferences that only make sense
        # against an actual regexp match - real Ansible's own documented
        # behavior for backrefs is "if the regexp does not match anywhere
        # in the file, the file will be left unchanged" (dev-sec
        # os_hardening's own `(?!.*no_pass_expiry)` negative-lookahead
        # regexp is written specifically to stop matching once already
        # applied, relying on this - without it, a second run inserted a
        # new line with the literal, unsubstituted text "\1 ..." instead
        # of leaving the file alone).
        return {new_lines, false} if backrefs

        # Real bug found benchmarking geerlingguy.jenkins: its own
        # "Modify variables in init file." task gives a regexp: that
        # never actually matches the line it (redundantly) also passes
        # as line: - a real, if unusual, shape a real playbook can
        # write, and real Ansible's own lineinfile module still
        # recognizes the target line as already present when it finds
        # it verbatim elsewhere in the file, regardless of whether a
        # regexp: was given at all. Gating this check behind `!regexp`
        # meant ANY regexp: that failed to match (whether or not the
        # target line already existed) skipped straight to insertion -
        # a fresh duplicate `Environment="JENKINS_OPTS="` line got
        # appended on literally every single run, never converging.
        return {new_lines, false} if new_lines.any? { |existing| lines_equal?(existing, line) }

        insert_index = insertion_index(new_lines, insertafter, insertbefore, firstmatch)
        new_lines.insert(insert_index, line)
        {new_lines, true}
      end

      # Expands a backrefs replacement template the way Python's
      # re.Match.expand does - the exact function real Ansible's own
      # lineinfile hands `line:` to (its `match.expand(line)`), so the
      # semantics have to match it, not just the numeric group refs:
      # Python templates also interpret standard backslash escapes, so
      # `line: 'MaxAuthTriesProbe \1\nMaxAuthTriesProbeBench \1'` (real
      # sshd-hardening-style playbooks do this to write two lines in one
      # task) expands to TWO physical lines - a literal backslash-n
      # written into the file diverges from real Ansible byte-for-byte.
      # Covered: \1-\99 positional refs (up to two digits; a group that
      # didn't participate expands to the empty string, like Python),
      # \g<n>/\g<name> refs, and Python's ESCAPES table
      # (\a \b \f \n \r \t \v); any other backslash escape is kept
      # literally (real Python raises "bad escape" there - krikri stays
      # lenient rather than failing the task on escape spellings Python
      # accepts nowhere but errors on).
      def self.expand_backref_template(template : String, match : Regex::MatchData) : String
        String.build do |io|
          i = 0
          while i < template.size
            ch = template[i]
            if ch != '\\' || i + 1 >= template.size
              io << ch
              i += 1
            else
              i = expand_template_escape(io, template, i, match)
            end
          end
        end
      end

      # Python's ESCAPES table for replacement templates: \a \b \f \n
      # \r \t \v expand to their control characters (\1-\99 and \g<...>
      # are group references, handled separately).
      private CONTROL_ESCAPES = {
        'a' => '\a', 'b' => '\b', 'f' => '\f',
        'n' => '\n', 'r' => '\r', 't' => '\t', 'v' => '\v',
      }

      # Consumes one escape (or a literal backslash) starting at index
      # *i* of *template* into *io*; returns the next scan index.
      private def self.expand_template_escape(io : IO, template : String, i : Int32, match : Regex::MatchData) : Int32
        nxt = template[i + 1]
        if control = CONTROL_ESCAPES[nxt]?
          io << control
          return i + 2
        end

        case nxt
        when '\\'     then io << '\\'
        when 'g'      then return expand_group_template_ref(io, template, i, match)
        when '0'..'9' then return expand_numeric_template_ref(io, template, i, match)
        else
          # Unknown escape: kept literally (real Python raises "bad
          # escape" there - krikri stays lenient rather than failing the
          # task on escape spellings Python accepts nowhere but errors on).
          io << '\\'
          io << nxt
        end
        i + 2
      end

      # \g<name> / \g<number> - Python's unambiguous group syntax.
      private def self.expand_group_template_ref(io : IO, template : String, i : Int32, match : Regex::MatchData) : Int32
        close = template.index('>', i + 2)
        expanded = close && close > i + 3 ? group_expansion(match, template[(i + 3)...close]) : nil
        if expanded
          io << expanded
          close ? close + 1 : i + 2
        else
          io << '\\'
          io << 'g'
          i + 1
        end
      end

      # Positional \1-\99 refs: Python parses up to two digits as the
      # group number (it errors when that group doesn't exist; krikri
      # falls back to the single-digit group, what such templates almost
      # always mean when the group count is smaller).
      private def self.expand_numeric_template_ref(io : IO, template : String, i : Int32, match : Regex::MatchData) : Int32
        j = i + 1
        j += 1 if j + 1 < template.size && template[j + 1].ascii_number?
        expanded = nil
        loop do
          expanded = group_expansion(match, template[(i + 1)..j])
          break if expanded || j <= i + 1
          j -= 1
        end
        if expanded
          io << expanded
          j + 1
        else
          io << '\\'
          i + 1
        end
      end

      # Group ref by number or name: nil when the numeric group doesn't
      # exist (Python errors; the caller keeps the escape literal), ""
      # when the group exists but didn't participate in the match (Python
      # expands unmatched groups to the empty string; for named groups an
      # unknown name is also treated as empty, leniently).
      private def self.group_expansion(match : Regex::MatchData, name : String) : String?
        if name.matches?(/^\d+$/)
          index = name.to_i
          return nil if index >= match.size
          match[index]? || ""
        else
          match[name]? || ""
        end
      end

      # Position of the line matching `pattern`: the LAST match by default
      # (real Ansible's lineinfile/blockinfile both scan the whole file
      # without breaking), or the FIRST when `firstmatch` is set. With
      # `literal: true` the pattern is a plain substring to CONTAIN
      # (real Ansible's search_string), not a regex.
      def self.match_index(lines : Array(String), pattern : String, firstmatch : Bool, literal : Bool = false) : Int32?
        matcher = if literal
                    ->(existing : String) { existing.includes?(pattern) }
                  else
                    ->(existing : String) { matches_regexp?(existing, pattern) }
                  end
        firstmatch ? lines.index(&matcher) : lines.rindex(&matcher)
      end

      # Shared with BlockEditor, so this is public rather than private.
      #
      # Real Ansible anchors the insertion at the LAST line matching the
      # insertafter/insertbefore pattern (its own loop keeps scanning and
      # only stops early under firstmatch), not the first - live-verified
      # against ansible-core 2.19.4 for both lineinfile and blockinfile
      # (blockinfile's marker-placement loop also has no break). The
      # previous first-match-always behavior diverged on any file where
      # the anchor pattern occurs more than once.
      def self.insertion_index(lines : Array(String), insertafter : String?, insertbefore : String?, firstmatch : Bool = false) : Int32
        if insertafter
          return lines.size if insertafter == "EOF" || insertafter == "END"
          # Real Ansible honors insertafter=BOF as top-of-file too (its
          # `elif insertbefore == 'BOF' or insertafter == 'BOF'` branch).
          return 0 if insertafter == "BOF"
          index = match_index(lines, insertafter, firstmatch)
          index ? index + 1 : lines.size
        elsif insertbefore
          return 0 if insertbefore == "BOF" || insertbefore == "BEGIN"
          match_index(lines, insertbefore, firstmatch) || lines.size
        else
          lines.size
        end
      end
    end
  end
end
