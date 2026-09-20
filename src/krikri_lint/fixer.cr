require "yaml"

module Krikri
  module Lint
    # Line-edit buffer for autofixes. All fixes operate on the file's
    # original line numbers: edits are spans within existing lines,
    # whole-line deletions, or the final-newline flag. Nothing may
    # insert or remove lines before the end, so violation coordinates
    # stay valid for the whole fix pass.
    class FixBuffer
      getter lines : Array(String)
      getter? had_trailing_newline
      getter add_trailing_newline
      getter? changed
      property deleted : Array(Bool)

      def initialize(source : String)
        if source.empty?
          @lines = [] of String
          @had_trailing_newline = false
        elsif source.ends_with?('\n')
          @lines = source[0...-1].split('\n')
          @had_trailing_newline = true
        else
          @lines = source.split('\n')
          @had_trailing_newline = false
        end
        @deleted = Array.new(@lines.size, false)
        @add_trailing_newline = false
        @changed = false
      end

      def line_text(line : Int32) : String?
        idx = line - 1
        return nil if idx < 0 || idx >= @lines.size
        @lines[idx]
      end

      # Replaces length bytes starting at column (1-based) on line with
      # replacement. Returns false when the span is out of bounds.
      def replace_span(line : Int32, column : Int32, length : Int32, replacement : String) : Bool
        idx = line - 1
        return false if idx < 0 || idx >= @lines.size
        text = @lines[idx]
        col = column - 1
        return false if col < 0 || col + length > text.size
        @lines[idx] = text[0...col] + replacement + text[(col + length)..]
        @changed = true
        true
      end

      def delete_line(line : Int32) : Nil
        idx = line - 1
        return if idx < 0 || idx >= @deleted.size
        @deleted[idx] = true
        @changed = true
      end

      def add_final_newline : Nil
        @add_trailing_newline = true
        @changed = true
      end

      def result : String
        kept = [] of String
        @lines.each_with_index do |text, idx|
          kept << text unless @deleted[idx]
        end
        body = kept.join('\n')
        return "" if body.empty?
        (@had_trailing_newline || @add_trailing_newline) ? body + "\n" : body
      end
    end

    # Helpers to locate the exact written text span of a scalar node on
    # its source line, so fixes can rewrite values without re-dumping
    # the YAML (preserving comments, quoting, and everything else).
    module FixSpan
      extend self

      # {start_col0, end_col0_exclusive} of the scalar's written text on
      # its line (quote characters included), or nil for block scalars
      # and anything the span cannot be determined for.
      def scalar_span(line : String, column : Int32) : {Int32, Int32}?
        col0 = column - 1
        return nil if col0 < 0 || col0 >= line.size
        first = line[col0]
        case first
        when '\'', '"'
          quoted_span(line, col0, first)
        when '|', '>'
          nil
        else
          plain_span(line, col0)
        end
      end

      private def quoted_span(line : String, col0 : Int32, quote : Char) : {Int32, Int32}?
        idx = col0 + 1
        while idx < line.size
          char = line[idx]
          if char == '\\' && quote == '"'
            idx += 2
            next
          end
          return {col0, idx + 1} if char == quote
          idx += 1
        end
        nil
      end

      private def plain_span(line : String, col0 : Int32) : {Int32, Int32}
        end0 = line.size
        search = line.index(" #", col0)
        end0 = search if search && search < end0
        while end0 > col0 && (line[end0 - 1] == ' ' || line[end0 - 1] == '\t')
          end0 -= 1
        end
        {col0, end0}
      end

      # The quote character the scalar is written with, or nil when plain.
      def quote_char(line : String, column : Int32) : Char?
        col0 = column - 1
        char = (col0 >= 0 && col0 < line.size) ? line[col0] : nil
        char if char == '\'' || char == '"'
      end
    end

    # Applies rule fixes to the files violations were reported on, then
    # writes back the changed ones. Mirrors upstream's Transformer:
    # matches whose rule is fixable and whose rule id/tags intersect the
    # --fix write list get fixed; fixed matches are dropped from the
    # report and do not affect the exit code.
    class Fixer
      @registry : RuleRegistry
      @write_set : Set(String)

      def initialize(@registry, write_list : Array(String))
        @write_set = Fixer.effective_write_set(write_list)
      end

      # Mirrors upstream Transformer.effective_write_set: "none" resets,
      # "all" enables everything.
      def self.effective_write_set(write_list : Array(String)) : Set(String)
        if none_index = write_list.rindex("none")
          start = write_list.size > none_index + 1 ? none_index + 1 : none_index
          write_list = write_list[start..]
        end
        if write_list.includes?("all")
          Set{"all"}
        else
          Set.new(write_list)
        end
      end

      def enabled? : Bool
        @write_set != Set{"none"} && !@write_set.empty?
      end

      # Sub-rule ids (name[casing], ...) map to their family rule
      # (id "name"); yaml[*] rules register per exact id, so the
      # prefix fallback only ever reaches a genuinely fixable family.
      private def rule_for(rule_id : String) : Rule?
        @registry.rules.find do |rule|
          rule.id == rule_id ||
            (rule_id.starts_with?(rule.id + "[") && rule.fixable?)
        end
      end

      # Applies rule fixes to violations' files and writes back the
      # changed ones. Mirrors upstream's Transformer: matches whose
      # rule is fixable and whose rule id/tags intersect the --fix
      # write list get fixed. Returns the paths of files that changed,
      # so the caller can re-run the checks instead of trusting the
      # pre-fix report (upstream drops fixed matches; re-running is
      # strictly more honest and also drops violations resolved
      # incidentally by another rule's fix, e.g. an fqcn hit resolved
      # by the shell-key rename).
      def apply(violations : Array(Violation)) : Array(String)
        return [] of String unless enabled?
        by_path = Hash(String, Array(Int32)).new { |hash, path| hash[path] = [] of Int32 }
        violations.each_with_index do |v, idx|
          next unless fixable_under_write_set?(v.rule_id)
          by_path[v.path] << idx
        end

        changed = [] of String
        by_path.each do |path, indices|
          next unless File.exists?(path)
          source = File.read(path)
          buffer = FixBuffer.new(source)
          file = PositionedFile.new(path, FileType.from_path(path),
            YAML::Nodes.parse(source).nodes.first?, nil)
          indices.each do |idx|
            rule = rule_for(violations[idx].rule_id)
            next unless rule
            rule.fix(buffer, file, violations[idx])
          end
          next unless buffer.changed?
          File.write(path, buffer.result)
          changed << path
        end
        changed
      end

      private def fixable_under_write_set?(rule_id : String) : Bool
        rule = rule_for(rule_id)
        return false unless rule && rule.fixable?
        return true if @write_set.includes?("all")
        # The family name (fqcn for fqcn[action-core], name, yaml) is
        # also accepted in a --fix list, matching upstream's single-rule
        # ids for these families.
        rule_definition = Set.new(rule.tags + [rule.id, rule.id.split("[")[0]])
        !(rule_definition & @write_set).empty?
      end
    end
  end
end
