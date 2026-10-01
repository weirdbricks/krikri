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
      # Returns {new_lines, changed}. append_newline/prepend_newline mirror
      # real Ansible's blank-line padding around the block (present state
      # only): prepend puts a blank line between the preceding content and
      # the block (skipped at BOF or when the preceding line is already
      # blank), append puts one between the block and what follows it
      # (skipped at EOF or when that line is already blank) - both no-ops
      # on reruns, since the blank line they add satisfies them the next
      # time.
      #
      # Real blockinfile.py builds its marker-delimited `blocklines` only
      # when the task is present AND the block is non-empty (`if present
      # and block:`), so a missing/empty block means "remove", but the
      # two padding flags are gated on `present` ALONE - a state: present
      # task with no block: at all still inserts the blank line they ask
      # for and reports changed (verified against ansible-core 2.19.11).
      def self.apply(
        lines : Array(String),
        marker_begin_line : String,
        marker_end_line : String,
        block_lines : Array(String),
        state : String,
        insertafter : String?,
        insertbefore : String?,
        append_newline : Bool = false,
        prepend_newline : Bool = false,
      ) : {Array(String), Bool}
        begin_index, end_index = find_block(lines, marker_begin_line, marker_end_line)

        # state: absent returns here, so everything below IS real's
        # `present` path - including its padding, which real gates on
        # `present` alone and not on there being a block to insert.
        if state == "absent"
          return {lines, false} unless begin_index && end_index
          new_lines = lines.dup
          new_lines.delete_at(begin_index, end_index - begin_index + 1)
          return {new_lines, true}
        end

        desired = block_lines.empty? ? [] of String : [marker_begin_line] + block_lines + [marker_end_line]

        new_lines =
          if begin_index && end_index
            replaced = lines.dup
            replaced.delete_at(begin_index, end_index - begin_index + 1)
            insert_with_newlines(replaced, begin_index, desired, append_newline, prepend_newline)
          else
            insert_index = LineEditor.insertion_index(lines, insertafter, insertbefore)
            insert_with_newlines(lines, insert_index, desired, append_newline, prepend_newline)
          end

        # Real Ansible byte-compares original vs result; in the stripped-
        # lines domain the array comparison is the same question.
        {new_lines, new_lines != lines}
      end

      # Inserts the marker-delimited block at insert_index, honoring the
      # append_newline/prepend_newline blank-line padding params with real
      # Ansible's exact skip conditions (BOF/EOF and already-blank
      # neighbors - verified against ansible-core 2.19.4's module source).
      # The padding is NOT gated on there being a block to insert: real
      # runs it between the "remove any existing block" and "insert the
      # new block" steps, so an empty desired list still gets the blank
      # line a state: present task asked for.
      private def self.insert_with_newlines(
        lines : Array(String),
        insert_index : Int32,
        desired : Array(String),
        append_newline : Bool,
        prepend_newline : Bool,
      ) : Array(String)
        out_lines = lines.dup

        if prepend_newline && insert_index != 0 && out_lines[insert_index - 1] != ""
          out_lines.insert(insert_index, "")
          insert_index += 1
        end

        out_lines.insert_all(insert_index, desired)

        if append_newline
          after = insert_index + desired.size
          if after < out_lines.size && out_lines[after] != ""
            out_lines.insert(after, "")
          end
        end

        out_lines
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
