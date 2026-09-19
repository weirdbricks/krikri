module Krikri
  module Lint
    # Inline suppression comments (`# noqa`, `# noqa: rule[,rule]`).
    # Mirrors upstream: a comment on the violation's line or anywhere in
    # the enclosing task (between the task's start line and the
    # violation line) suppresses it.
    module Noqa
      NOQA_RE = /#\s*noqa(?::\s*(?<ids>.*))?/

      record Entry, all : Bool, ids : Array(String)

      def self.build_map(source : String) : Hash(Int32, Entry)
        map = {} of Int32 => Entry
        source.each_line.with_index do |line, idx|
          if (m = line.match(NOQA_RE))
            ids_text = m["ids"]?
            if ids_text.nil? || ids_text.strip.empty?
              map[idx + 1] = Entry.new(true, [] of String)
            else
              ids = ids_text.split(/[\s,]+/).reject(&.empty?)
              map[idx + 1] = Entry.new(false, ids)
            end
          end
        end
        map
      end

      # task_line is the enclosing task's first line, when known.
      def self.suppresses?(map : Hash(Int32, Entry), line : Int32, task_line : Int32?, rule_id : String) : Bool
        lines = [line]
        if tl = task_line
          (tl..line).each { |number| lines << number }
        end
        lines.each do |line_number|
          if (entry = map[line_number]?)
            return true if entry.all
            return true if entry.ids.includes?(rule_id)
          end
        end
        false
      end
    end
  end
end
