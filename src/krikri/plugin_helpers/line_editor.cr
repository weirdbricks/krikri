module Krikri
  module PluginHelpers
    # LineEditor - pure line-matching/insertion logic for the lineinfile
    # plugin, factored out so it can be unit tested without touching the
    # filesystem or going through the plugin's stdin/stdout protocol.
    #
    # The lineinfile entry points (ensure_present/remove_matching/split_lines)
    # work on lines WITH their terminator still attached - the same shape
    # Ansible's own lineinfile uses, because it reads the file in binary
    # mode (open(b_dest, 'rb') + f.readlines()), so a "\r\n"-terminated
    # file yields lines like "en\r\n" and the trailing "\r" is part of the
    # line the regexp and the replacement comparison see. SoftEther's own
    # lang.config (written BOM + CRLF by the vpnserver/vpncmd binaries on
    # every startup - found via softasap.sa-vpn-softether round 2600001,
    # where Ansible reported changed on both cold and warm runs while
    # crystal reported ok) is the live case: regexp "^(en|ja|cn)$" cannot
    # match "en\r\n" ($ has nothing to anchor to before the "\r"), and
    # Ansible then replaces the whole "en\r\n" line with "en\n" - changed
    # - while a stripped-lines comparison calls it already correct. The
    # terminator-less view used here previously made lines_equal? strip()
    # the "\r" away and report ok forever.
    module LineEditor
      def self.matches_regexp?(line : String, pattern : String?) : Bool
        return false unless pattern
        regex = Regex.new(pattern)
        !!(line =~ regex)
      rescue
        false
      end

      # --- lineinfile entry points: lines carry their terminator ----------

      # Binary-mode readlines: split on "\n" only, keeping the "\n" on
      # every line it terminates. A trailing "\r" (CRLF files) stays in
      # the line body; a final line without a newline stays unterminated;
      # empty content is zero lines (Python's b"".readlines()).
      def self.split_lines(content : String) : Array(String)
        return [] of String if content.empty?
        ends_nl = content.ends_with?("\n")
        parts = content.split("\n")
        parts.pop if ends_nl
        if ends_nl
          parts.map { |part| part + "\n" }
        else
          parts.map_with_index { |part, i| i == parts.size - 1 ? part : part + "\n" }
        end
      end

      private def self.compile_pattern(pattern : String?) : Regex?
        return nil unless pattern
        Regex.new(pattern)
      rescue
        nil
      end

      # state: absent - drop every line matching regexp, containing
      # search_string (literal substring - Ansible's own matcher for
      # state=absent), or - failing both - an exact match against `line`
      # (Ansible compares `line` to the file line with only its trailing
      # \r\n stripped - no whitespace normalization). firstmatch does NOT
      # apply here: Ansible removes ALL matching lines regardless
      # (live-verified against ansible-core 2.19.4). Kept lines keep their
      # original terminators. Returns {new_lines, changed, found_count}.
      def self.remove_matching(lines : Array(String), line : String?, regexp : String?, search_string : String? = nil) : {Array(String), Bool, Int32}
        regex = compile_pattern(regexp)
        found = 0
        kept = lines.select do |existing|
          matched = if regex
                      !!(existing =~ regex)
                    elsif search_string
                      existing.includes?(search_string)
                    else
                      !line.nil? && existing.rstrip("\r\n") == line
                    end
          found += 1 if matched
          !matched
        end

        {kept, found > 0, found}
      end

      # state: present - a 1:1 port of Ansible's lineinfile present()
      # (ansible-core 2.19 modules/lineinfile.py) over terminator-attached
      # lines. Returns {new_lines, changed, msg} with Ansible's own msg
      # strings ('line added' / 'line replaced' / '').
      #
      # Search order mirrors Ansible: regexp match wins (LAST match by
      # default, first with firstmatch - live-verified benchmarking
      # geerlingguy.phpmyadmin, whose regexp matches both the populated
      # config line and a commented template near EOF, and Ansible rewrites
      # only the final occurrence); then search_string the same way; only
      # when neither matched does the exact-line scan run (`line` compared
      # to each file line stripped of trailing \r\n) and, failing that,
      # the insertafter/insertbefore anchor scan.
      def self.ensure_present(
        lines : Array(String),
        line : String,
        regexp : String?,
        search_string : String?,
        insertafter : String?,
        insertbefore : String?,
        backrefs : Bool,
        firstmatch : Bool,
      ) : {Array(String), Bool, String}
        new_lines = lines.dup
        index0, index1, match, exact_line_match = scan_present(new_lines, line, regexp, search_string, insertafter, insertbefore, firstmatch)
        changed, msg = apply_present(new_lines, line, regexp, search_string, insertafter, insertbefore, backrefs, index0, index1, match, exact_line_match)
        {new_lines, changed, msg}
      end

      # Ansible's three-step scan: regexp match wins (LAST match by
      # default, first with firstmatch), then search_string the same way,
      # and only when neither matched does the exact-line scan run
      # (`line` compared to each file line stripped of trailing \r\n)
      # together with the insertafter/insertbefore anchor scan.
      private def self.scan_present(lines : Array(String), line : String, regexp : String?, search_string : String?, insertafter : String?, insertbefore : String?, firstmatch : Bool) : {Int32, Int32, Regex::MatchData?, Bool} # ameba:disable Metrics/CyclomaticComplexity
        regex = compile_pattern(regexp)

        # Ansible compiles the insertion anchor ONLY when it is a real
        # pattern (EOF/BOF/nil spellings are literals, not regexps).
        anchor_from_insertafter = !insertafter.nil? && insertafter != "BOF" && insertafter != "EOF"
        anchor_pattern = if anchor_from_insertafter
                           insertafter
                         elsif insertbefore && insertbefore != "BOF"
                           insertbefore
                         end
        anchor_regex = compile_pattern(anchor_pattern)

        index0 = -1
        index1 = -1
        match : Regex::MatchData? = nil
        exact_line_match = false

        if regex
          lines.each_with_index do |existing, lineno|
            if m = regex.match(existing)
              index0 = lineno
              match = m
              break if firstmatch
            end
          end
        end

        if search_string && match.nil?
          lines.each_with_index do |existing, lineno|
            if existing.includes?(search_string)
              index0 = lineno
              break if firstmatch
            end
          end
        end

        if match.nil?
          lines.each_with_index do |existing, lineno|
            if line == existing.rstrip("\r\n")
              index0 = lineno
              exact_line_match = true
            elsif anchor_regex && !anchor_regex.match(existing).nil?
              index1 = anchor_from_insertafter ? lineno + 1 : lineno
              break if firstmatch
            end
          end
        end

        {index0, index1, match, exact_line_match}
      end

      # The mutation half of Ansible's present(): replacement when a line
      # was found, otherwise backrefs' deliberate no-op, then the
      # insertion branches (BOF / EOF-append / after an anchor / at an
      # anchor). Returns {changed, msg}.
      private def self.apply_present(lines : Array(String), line : String, regexp : String?, search_string : String?, insertafter : String?, insertbefore : String?, backrefs : Bool, index0 : Int32, index1 : Int32, match : Regex::MatchData?, exact_line_match : Bool) : {Bool, String} # ameba:disable Metrics/CyclomaticComplexity
        linesep = "\n"

        if index0 != -1
          # backrefs expands `line` against the match; otherwise the raw
          # line value is the replacement. The endswith(linesep)
          # normalization applies ONLY to this replacement comparison -
          # the insertion branches below append linesep to the raw line
          # unconditionally (so line "x\n" appended lands as "x\n\n",
          # live-verified against ansible-core 2.19.11).
          new_line = if backrefs && (m = match)
                       expand_backref_template(line, m)
                     else
                       line
                     end
          new_line += linesep unless new_line.ends_with?(linesep)

          if regexp.nil? && search_string.nil? && match.nil? && !exact_line_match
            # Dead in Ansible too (index0 can only be set here by an exact
            # match, which this branch excludes) - ported for fidelity.
            insert_beside_anchor(lines, line, insertafter, insertbefore, index1)
          elsif lines[index0] != new_line
            lines[index0] = new_line
            {true, "line replaced"}
          else
            {false, ""}
          end
        elsif backrefs
          # Do nothing: unsafe to generate the line without a regexp match
          # to populate the backrefs from (dev-sec os_hardening's
          # negative-lookahead regexps rely on this to stay idempotent).
          {false, ""}
        elsif insertbefore == "BOF" || insertafter == "BOF"
          lines.insert(0, line + linesep)
          {true, "line added"}
        elsif insertafter == "EOF" || index1 == -1
          append_at_eof(lines, line, linesep)
        elsif insertafter && index1 != -1
          insert_after_anchor(lines, line, insertafter, index1)
        else
          lines.insert(index1, line + linesep)
          {true, "line added"}
        end
      end

      # Ansible's insertafter/insertbefore insertion branches, compared
      # against the anchor-adjacent line with only trailing \r\n stripped.
      private def self.insert_beside_anchor(lines : Array(String), line : String, insertafter : String?, insertbefore : String?, index1 : Int32) : {Bool, String} # ameba:disable Metrics/CyclomaticComplexity
        linesep = "\n"
        if insertafter && insertafter != "EOF"
          if !lines.empty? && !"\n\r".includes?(lines.last[-1])
            lines[-1] += linesep
          end
          if lines.size == index1
            if lines[index1 - 1].rstrip("\r\n") != line
              lines << (line + linesep)
              return {true, "line added"}
            end
          elsif lines[index1].rstrip("\r\n") != line
            lines.insert(index1, line + linesep)
            return {true, "line added"}
          end
        elsif insertbefore && insertbefore != "BOF"
          if index1 <= 0
            if lines[index1].rstrip("\r\n") != line
              lines.insert(index1, line + linesep)
              return {true, "line added"}
            end
          elsif lines[index1 - 1].rstrip("\r\n") != line
            lines.insert(index1, line + linesep)
            return {true, "line added"}
          end
        end
        {false, ""}
      end

      # Append at EOF (the default insertion). Ensure the previous last
      # line is newline-terminated first, but note the appended value is
      # the RAW line plus one linesep - a line value that already ends
      # with "\n" lands with a doubled terminator, byte-identical to
      # Ansible (live-verified: line "x\n" into a fresh file gives
      # "x\n\n").
      private def self.append_at_eof(lines : Array(String), line : String, linesep : String) : {Bool, String}
        if !lines.empty? && !"\n\r".includes?(lines.last[-1])
          lines << linesep
        end
        lines << (line + linesep)
        {true, "line added"}
      end

      private def self.insert_after_anchor(lines : Array(String), line : String, insertafter : String, index1 : Int32) : {Bool, String}
        linesep = "\n"
        if lines.size == index1
          if lines[index1 - 1].rstrip("\r\n") != line
            lines << (line + linesep)
            return {true, "line added"}
          end
        elsif line != lines[index1].rstrip("\n\r")
          lines.insert(index1, line + linesep)
          return {true, "line added"}
        end
        {false, ""}
      end

      # Expands a backrefs replacement template the way Python's
      # re.Match.expand does - the exact function Ansible's own
      # lineinfile hands `line:` to (its `match.expand(line)`), so the
      # semantics have to match it, not just the numeric group refs:
      # Python templates also interpret standard backslash escapes, so
      # `line: 'MaxAuthTriesProbe \1\nMaxAuthTriesProbeBench \1'` (real
      # sshd-hardening-style playbooks do this to write two lines in one
      # task) expands to TWO physical lines - a literal backslash-n
      # written into the file diverges from Ansible byte-for-byte.
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

      # --- shared with BlockEditor (separator-less lines) -----------------

      # Position of the line matching `pattern`: the LAST match by default
      # (Ansible's lineinfile/blockinfile both scan the whole file
      # without breaking), or the FIRST when `firstmatch` is set. With
      # literal: true the pattern is a plain substring to CONTAIN
      # (Ansible's search_string), not a regex.
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
      # Ansible anchors the insertion at the LAST line matching the
      # insertafter/insertbefore pattern (its own loop keeps scanning and
      # only stops early under firstmatch), not the first - live-verified
      # against ansible-core 2.19.4 for both lineinfile and blockinfile
      # (blockinfile's marker-placement loop also has no break). The
      # previous first-match-always behavior diverged on any file where
      # the anchor pattern occurs more than once.
      def self.insertion_index(lines : Array(String), insertafter : String?, insertbefore : String?, firstmatch : Bool = false) : Int32
        if insertafter
          return lines.size if insertafter == "EOF" || insertafter == "END"
          # Ansible honors insertafter=BOF as top-of-file too (its
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
