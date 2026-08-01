module CrystalPlay
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

      # state: absent - drop every line matching regexp (or, failing that,
      # an exact match against `line`). Returns {new_lines, changed}.
      def self.remove_matching(lines : Array(String), line : String?, regexp : String?) : {Array(String), Bool}
        changed = false
        kept = lines.reject do |existing|
          should_remove = if regexp
                            matches_regexp?(existing, regexp)
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
      def self.ensure_present(
        lines : Array(String),
        line : String,
        regexp : String?,
        backrefs : Bool,
        insertafter : String?,
        insertbefore : String?,
      ) : {Array(String), Bool}
        new_lines = lines.dup

        if regexp
          pattern = regexp
          found_index = new_lines.index { |existing| matches_regexp?(existing, pattern) }
        end

        if found_index && pattern
          if backrefs
            substituted = new_lines[found_index].gsub(Regex.new(pattern), line)
            changed = substituted != new_lines[found_index]
            new_lines[found_index] = substituted
            return {new_lines, changed}
          else
            changed = new_lines[found_index] != line
            new_lines[found_index] = line
            return {new_lines, changed}
          end
        end

        return {new_lines, false} if !regexp && new_lines.any? { |existing| lines_equal?(existing, line) }

        insert_index = insertion_index(new_lines, insertafter, insertbefore)
        new_lines.insert(insert_index, line)
        {new_lines, true}
      end

      private def self.insertion_index(lines : Array(String), insertafter : String?, insertbefore : String?) : Int32
        if insertafter
          return lines.size if insertafter == "EOF" || insertafter == "END"
          index = lines.index { |existing| matches_regexp?(existing, insertafter) }
          index ? index + 1 : lines.size
        elsif insertbefore
          return 0 if insertbefore == "BOF" || insertbefore == "BEGIN"
          lines.index { |existing| matches_regexp?(existing, insertbefore) } || lines.size
        else
          lines.size
        end
      end
    end
  end
end
