module Krikri
  # Python's `difflib.SequenceMatcher` and `difflib.unified_diff`, ported so
  # that krikri's `--diff` bodies are byte-identical with ansible-playbook's.
  #
  # Ansible does NOT shell out to `diff`: its callback builds each diff body
  # with `difflib.unified_diff(before.splitlines(True),
  # after.splitlines(True), ..., n=3)` and prints every yielded line
  # (`ansible/plugins/callback/__init__.py`, `_get_diff`). The two
  # algorithms can pick different maximal matching blocks, so the same
  # before/after pair renders the same lines in a different `-`/`+`/
  # context arrangement: martin-micimo.haproxy's /etc/haproxy/haproxy.cfg
  # (34 lines -> 35) gave a GNU-diff body of 2400 B against ansible's
  # 2394 B, and that was the last difference in the role's cold phase
  # (issues #566, #736). The port below keeps difflib's own names and
  # structure so it can be checked against the Python source line by line.
  module Difflib
    # difflib.SequenceMatcher's autojunk heuristic only kicks in for
    # sequences at least this long, and then drops elements that appear
    # more than len(b)//100 + 1 times (ansible passes no isjunk, and the
    # default autojunk=True).
    AUTOJUNK_THRESHOLD = 200

    record Match, a : Int32, b : Int32, size : Int32

    record Opcode, tag : String, i1 : Int32, i2 : Int32, j1 : Int32, j2 : Int32

    # Python's `str.splitlines(True)`: the line terminators it recognises,
    # kept on each line.
    LINE_BREAKS = {'\n', '\r', '\v', '\f', '\u001c', '\u001d', '\u001e', '\u0085', '\u2028', '\u2029'}

    def self.splitlines(text : String) : Array(String)
      lines = [] of String
      chars = text.chars
      return lines if chars.empty?

      builder = String::Builder.new
      index = 0
      while index < chars.size
        char = chars[index]
        builder << char
        index += 1
        next unless LINE_BREAKS.includes?(char)

        if char == '\r' && index < chars.size && chars[index] == '\n'
          builder << '\n'
          index += 1
        end
        lines << builder.to_s
        builder = String::Builder.new
      end
      trailing = builder.to_s
      lines << trailing unless trailing.empty?
      lines
    end

    # The line lists ansible's callback diffs: `splitlines(True)` plus that
    # module's "no newline at end of file" note folded into the last line
    # (`_get_diff` in ansible/plugins/callback/__init__.py), so the note
    # renders as a normal -/+/context line rather than GNU diff's own
    # trailing marker.
    def self.match_lines(text : String) : Array(String)
      lines = splitlines(text)
      if (last = lines.last?) && !last.ends_with?('\n')
        lines[-1] = last + "\n\\ No newline at end of file\n"
      end
      lines
    end

    # difflib.unified_diff's full output, headers included, each line still
    # carrying its trailing newline exactly like Python's generator yields.
    # ansible's callback prints every yielded line verbatim after colouring
    # it by its first character.
    def self.unified_diff(before : Array(String), after : Array(String),
                          fromfile : String = "", tofile : String = "",
                          n : Int32 = 3) : Array(String)
      lines = [] of String
      started = false
      SequenceMatcher.new(before, after).grouped_opcodes(n).each do |group|
        unless started
          started = true
          lines << "--- #{fromfile}\n"
          lines << "+++ #{tofile}\n"
        end
        lines << "@@ -#{format_range_unified(group.first.i1, group.last.i2)} " \
                 "+#{format_range_unified(group.first.j1, group.last.j2)} @@\n"
        group.each do |opcode|
          if opcode.tag == "equal"
            before[opcode.i1...opcode.i2].each { |line| lines << " " + line }
            next
          end
          if opcode.tag == "replace" || opcode.tag == "delete"
            before[opcode.i1...opcode.i2].each { |line| lines << "-" + line }
          end
          if opcode.tag == "replace" || opcode.tag == "insert"
            after[opcode.j1...opcode.j2].each { |line| lines << "+" + line }
          end
        end
      end
      lines
    end

    # difflib._format_range_unified.
    private def self.format_range_unified(start : Int32, stop : Int32) : String
      beginning = start + 1
      length = stop - start
      return beginning.to_s if length == 1

      beginning -= 1 if length == 0
      "#{beginning},#{length}"
    end

    class SequenceMatcher
      getter a : Array(String)
      getter b : Array(String)
      @b2j : Hash(String, Array(Int32))
      @matching_blocks : Array(Match)?

      def initialize(@a : Array(String), @b : Array(String))
        @b2j = Hash(String, Array(Int32)).new
        @b.each_with_index do |element, index|
          indices = @b2j[element] ||= [] of Int32
          indices << index
        end
        purge_popular_elements
      end

      # difflib's autojunk purge: a line repeated more than len(b)//100 + 1
      # times is dropped from the index (it is too common to be a useful
      # anchor) once the sequence reaches AUTOJUNK_THRESHOLD.
      private def purge_popular_elements : Nil
        return if @b.size < AUTOJUNK_THRESHOLD

        limit = @b.size // 100 + 1
        @b2j.select { |_, indices| indices.size > limit }.keys.each { |element| @b2j.delete(element) }
      end

      # difflib.SequenceMatcher.find_longest_match. ansible passes no
      # isjunk, so the junk-specific extension steps difflib runs around
      # this one collapse into the plain match extension kept here.
      def find_longest_match(alo : Int32, ahi : Int32, blo : Int32, bhi : Int32) : Match
        best_i = alo
        best_j = blo
        best_size = 0
        lengths = Hash(Int32, Int32).new

        (alo...ahi).each do |i|
          new_lengths = Hash(Int32, Int32).new
          (@b2j[@a[i]]? || [] of Int32).each do |j|
            next if j < blo
            break if j >= bhi

            length = (lengths[j - 1]? || 0) + 1
            new_lengths[j] = length
            next unless length > best_size

            best_i = i - length + 1
            best_j = j - length + 1
            best_size = length
          end
          lengths = new_lengths
        end

        while best_i > alo && best_j > blo && @a[best_i - 1] == @b[best_j - 1]
          best_i -= 1
          best_j -= 1
          best_size += 1
        end
        while best_i + best_size < ahi && best_j + best_size < bhi &&
              @a[best_i + best_size] == @b[best_j + best_size]
          best_size += 1
        end

        Match.new(best_i, best_j, best_size)
      end

      # difflib.SequenceMatcher.get_matching_blocks, including its
      # coalescing of adjacent blocks and the trailing empty sentinel.
      def matching_blocks : Array(Match)
        if cached = @matching_blocks
          return cached
        end

        queue = [{0, @a.size, 0, @b.size}]
        blocks = [] of Match
        while entry = queue.pop?
          alo, ahi, blo, bhi = entry
          match = find_longest_match(alo, ahi, blo, bhi)
          next unless match.size > 0

          blocks << match
          queue << {alo, match.a, blo, match.b} if alo < match.a && blo < match.b
          if match.a + match.size < ahi && match.b + match.size < bhi
            queue << {match.a + match.size, ahi, match.b + match.size, bhi}
          end
        end

        blocks.sort_by! { |block| {block.a, block.b, block.size} }
        non_adjacent = [] of Match
        i1 = 0
        j1 = 0
        k1 = 0
        blocks.each do |block|
          if i1 + k1 == block.a && j1 + k1 == block.b
            k1 += block.size
          else
            non_adjacent << Match.new(i1, j1, k1) if k1 > 0
            i1 = block.a
            j1 = block.b
            k1 = block.size
          end
        end
        non_adjacent << Match.new(i1, j1, k1) if k1 > 0
        non_adjacent << Match.new(@a.size, @b.size, 0)

        @matching_blocks = non_adjacent
        non_adjacent
      end

      # difflib.SequenceMatcher.get_opcodes.
      def opcodes : Array(Opcode)
        i = 0
        j = 0
        answer = [] of Opcode
        matching_blocks.each do |match|
          if i < match.a && j < match.b
            answer << Opcode.new("replace", i, match.a, j, match.b)
          elsif i < match.a
            answer << Opcode.new("delete", i, match.a, j, match.b)
          elsif j < match.b
            answer << Opcode.new("insert", i, match.a, j, match.b)
          end
          i = match.a + match.size
          j = match.b + match.size
          answer << Opcode.new("equal", match.a, i, match.b, j) if match.size > 0
        end
        answer
      end

      # difflib.SequenceMatcher.get_grouped_opcodes: the opcodes cut into
      # hunks of *n* context lines, the leading/trailing equal runs trimmed
      # and any single-equal-run group dropped.
      def grouped_opcodes(n : Int32 = 3) : Array(Array(Opcode))
        codes = opcodes
        codes = [Opcode.new("equal", 0, 1, 0, 1)] if codes.empty?

        if (first = codes.first).tag == "equal"
          codes[0] = Opcode.new(first.tag, Math.max(first.i1, first.i2 - n), first.i2,
            Math.max(first.j1, first.j2 - n), first.j2)
        end
        if (last = codes.last).tag == "equal"
          codes[-1] = Opcode.new(last.tag, last.i1, Math.min(last.i2, last.i1 + n),
            last.j1, Math.min(last.j2, last.j1 + n))
        end

        limit = n + n
        groups = [] of Array(Opcode)
        group = [] of Opcode
        codes.each do |opcode|
          i1 = opcode.i1
          j1 = opcode.j1
          if opcode.tag == "equal" && opcode.i2 - i1 > limit
            group << Opcode.new(opcode.tag, i1, Math.min(opcode.i2, i1 + n), j1, Math.min(opcode.j2, j1 + n))
            groups << group
            group = [] of Opcode
            i1 = Math.max(i1, opcode.i2 - n)
            j1 = Math.max(j1, opcode.j2 - n)
          end
          group << Opcode.new(opcode.tag, i1, opcode.i2, j1, opcode.j2)
        end
        groups << group unless group.empty? || (group.size == 1 && group.first.tag == "equal")
        groups
      end
    end
  end
end
