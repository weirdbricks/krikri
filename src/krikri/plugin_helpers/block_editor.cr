require "./line_editor"

module Krikri
  module PluginHelpers
    # BlockEditor - pure marker-delimited-block matching/insertion logic for
    # the blockinfile plugin, factored out the same way LineEditor is for
    # lineinfile so it can be unit tested without touching the filesystem.
    #
    # Behavior verified empirically against real `ansible-playbook` (not
    # assumed from docs): the begin/end marker lines are matched by exact
    # equality (not regex), an existing block's insertion position never
    # moves once found (only its interior is rewritten), a fresh block is
    # inserted with no surrounding blank line via the exact same
    # insertafter/insertbefore rules lineinfile already uses (default EOF),
    # and an unchanged run's message is the empty string (not e.g. "Block
    # already present").
    module BlockEditor
      # Returns {new_lines, changed}.
      def self.apply(
        lines : Array(String),
        marker_begin_line : String,
        marker_end_line : String,
        block_lines : Array(String),
        state : String,
        insertafter : String?,
        insertbefore : String?,
      ) : {Array(String), Bool}
        begin_index, end_index = find_block(lines, marker_begin_line, marker_end_line)

        if state == "absent"
          return {lines, false} unless begin_index && end_index
          new_lines = lines.dup
          new_lines.delete_at(begin_index, end_index - begin_index + 1)
          return {new_lines, true}
        end

        desired = [marker_begin_line] + block_lines + [marker_end_line]

        if begin_index && end_index
          return {lines, false} if lines[begin_index..end_index] == desired

          new_lines = lines.dup
          new_lines.delete_at(begin_index, end_index - begin_index + 1)
          new_lines.insert_all(begin_index, desired)
          {new_lines, true}
        else
          new_lines = lines.dup
          insert_index = LineEditor.insertion_index(new_lines, insertafter, insertbefore)
          new_lines.insert_all(insert_index, desired)
          {new_lines, true}
        end
      end

      # Finds the first marker_begin_line, then the first marker_end_line
      # strictly after it. A begin with no matching end (block torn apart
      # by hand-edits) counts as "not found" - the same fresh-insert path a
      # missing begin takes.
      private def self.find_block(lines : Array(String), marker_begin_line : String, marker_end_line : String) : {Int32?, Int32?}
        begin_index = lines.index { |line| line == marker_begin_line }
        return {nil, nil} unless begin_index

        end_index = ((begin_index + 1)...lines.size).find { |i| lines[i] == marker_end_line }
        {begin_index, end_index}
      end
    end
  end
end
