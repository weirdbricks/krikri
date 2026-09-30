require "../vault"

module Krikri
  # Byte-for-byte port of ansible-core 2.19's task-failure error-block
  # rendering: `Display._error` -> `_display_utils.format_message` ->
  # `_event_formatting.format_event`/`format_event_verbose_message`, over
  # an `Event` tree whose source context comes from
  # `_error_utils.SourceContext.from_origin`. This is what real
  # ansible-playbook prints as
  #
  #   [ERROR]: Task failed: <message>
  #   ...
  #   Origin: <file>:<line>:<col>
  #   ...
  #   <<< caused by >>>
  #   ...
  #
  # before the `fatal:` line whenever a task failure carries an
  # `exception` event (controller/action exceptions, module failures
  # wrapped by the module API, conditional-evaluation failures).
  #
  # The event tree is small (a message, its optional source context, and
  # a linear cause chain); every shape real 2.19 produces for task
  # failures is one of:
  #
  # - collapsed: the whole cause chain collapses into one segment
  #   ("Task failed: Module failed: non-zero return code" + the task
  #   origin), when every chained event shares the direct-cause reason
  #   and carries no distinct source context.
  # - handling: the chain breaks at an event whose own chain reason
  #   differs ("raise X(...) from Y" vs a bare `raise X(...)` inside
  #   `except Y`), producing the two-segment form with the
  #   `<<< caused by >>>` separator (template action failures,
  #   conditional-evaluation failures).
  module ErrorBlock
    # One node of an error event tree. `source_context` is the fully
    # rendered `Origin: ...` block (see origin_context); `chain_reason`/
    # `chain_follow`/`chain` mirror `EventChain`; `help_text` mirrors
    # `Event.help_text`.
    class Node
      property msg : String
      property source_context : String?
      property help_text : String?
      property chain_reason : String?
      property chain_follow : Bool
      property chain : Node?
      property events : Array(Node)?

      def initialize(@msg, @source_context = nil, @help_text = nil, @chain_reason = nil, @chain_follow = true, @chain : Node? = nil, @events : Array(Node)? = nil)
      end

      def with_chain(reason : String, follow : Bool, event : Node) : Node
        @chain_reason = reason
        @chain_follow = follow
        @chain = event
        self
      end
    end

    DIRECT_CAUSE = "<<< caused by >>>"
    HANDLING     = "<<< while handling >>>"

    @@seen = Set(String).new

    # Renders the event tree into real Ansible's `[ERROR]: ...` block and
    # prints it, unless the exact text was already displayed (real's
    # `Display._deduplicate` - one global set, so a loop's per-item
    # failures with identical text, or the same failure on several hosts,
    # display the block once). Returns true when printed.
    def self.emit(node : Node) : Bool
      text = "[ERROR]: " + format_event(node)
      return false unless @@seen.add?(text)
      print text
      true
    end

    # Same rendering and dedup as emit, but on STDERR. Real Ansible
    # routes an error block to stderr when the error is raised OUTSIDE
    # task result processing - a dynamic include_role:'s role resolution
    # failure ("the role 'x' was not found in ...") - while ordinary
    # task-failure blocks go to stdout (live-verified vs 2.19.11).
    def self.emit_stderr(node : Node) : Bool
      text = "[ERROR]: " + format_event(node)
      return false unless @@seen.add?(text)
      STDERR.print text
      true
    end

    # Test hook: forget all displayed blocks.
    def self.reset_seen : Nil
      @@seen.clear
    end

    def self.seen?(text : String) : Bool
      @@seen.includes?(text)
    end

    # Port of `_event_formatting.format_event` (no traceback).
    def self.format_event(event : Node) : String
      msg = format_event_verbose_message(event)
      msg = msg.strip
      msg += msg.includes?('\n') ? "\n\n" : "\n"
      msg
    end

    # Port of `_event_formatting.format_event_verbose_message`.
    #
    # A Node owns its outgoing chain link (`chain`/`chain_reason`/
    # `chain_follow` mirror `EventChain.event`/`msg_reason`/`follow`),
    # so the traversal walks node-as-link-owner pairs exactly the way
    # the Python walks EventChain objects.
    def self.format_event_verbose_message(original : Node) : String
      segments = [] of String
      event = original

      while event
        messages = [event.msg]
        link = event

        while (child = link.chain) && link.chain_follow
          break if child.events

          if child.source_context || child.help_text
            break if child.source_context != event.source_context || child.help_text != event.help_text
          end

          break if child.chain && link.chain_reason != child.chain_reason

          messages << child.msg
          link = child
        end

        msg = deduplicate_message_parts(messages)
        segment = message_lines(msg, event.help_text, event.source_context).join('\n') + '\n'
        segments << segment

        if (child = link.chain) && link.chain_follow
          segments << "\n#{link.chain_reason}\n\n"
          event = child
        else
          event = nil
        end
      end

      segments.insert(0, brief_message(original) + "\n\n") if segments.size > 1
      segments.join
    end

    # Port of `_event_utils.deduplicate_message_parts`.
    def self.deduplicate_message_parts(parts : Array(String)) : String
      message_parts = parts.reverse
      message = message_parts.shift

      message_parts.each do |part|
        if part.ends_with?(message)
          message = part
        else
          message = concat_message(part, message)
        end
      end

      message
    end

    # Port of `_event_utils.format_event_brief_message`.
    def self.brief_message(event : Node) : String
      parts = [] of String
      loop do
        parts << event.msg
        break unless event.chain && event.chain_follow
        event = event.chain.not_nil!
      end
      deduplicate_message_parts(parts)
    end

    # Port of `_text_utils.concat_message`.
    def self.concat_message(left : String, right : String) : String
      "#{left.rstrip(". ")}: #{right}"
    end

    # Port of `_event_formatting._get_message_lines`.
    def self.message_lines(message : String, help_text : String?, source_context : String?) : Array(String)
      if help_text && !source_context && !message.includes?('\n') && !help_text.includes?('\n')
        return ["#{message} #{help_text}"]
      end

      lines = [message]
      lines << source_context if source_context
      if help_text
        lines << ""
        lines << help_text
      end
      lines
    end

    # Port of `_error_utils.SourceContext.from_origin` + `#to_s`:
    # `Origin: path:line:col`, a blank line, then up to 2 lines of
    # context before the target line (right-aligned line numbers, tabs
    # collapsed to single spaces, 120-column truncation with a `...`
    # marker) and the caret line under the target column. Returns the
    # block WITHOUT a trailing newline.
    def self.origin_context(path : String, line_num : Int, col_num : Int?, show_content : Bool = true) : String
      origin_label = String.build do |io|
        io << path
        io << ':' << line_num if line_num > 0
        io << ':' << col_num if (col = col_num) && col > 0
      end
      msg_lines = ["Origin: #{origin_label}"]

      return msg_lines.join('\n') unless show_content
      return msg_lines.join('\n') if line_num < 1

      annotated = annotated_source_lines(path, line_num, col_num)
      if annotated
        msg_lines << ""
        msg_lines.concat(annotated)
      else
        msg_lines << ""
        msg_lines << "(source not shown: #{@@source_error})"
      end
      msg_lines.join('\n')
    end

    @@source_error = "file truncated"

    # Returns the annotated source lines, or nil when the context can't
    # be shown (unreadable file, encrypted content, truncated file) -
    # in which case @@source_error holds real's reason text.
    private def self.annotated_source_lines(path : String, line_num : Int, col_num : Int?) : Array(String)?
      context_line_count = 2
      max_annotated_line_width = 120
      truncation_marker = "..."

      start_line_idx = Math.max(0, (line_num - 1) - context_line_count)

      lines = read_source_lines(path, start_line_idx, line_num)
      unless lines
        @@source_error = "FileNotFoundError"
        return nil
      end

      if vault_encrypted?(path)
        @@source_error = "content encrypted"
        return nil
      end

      if lines.size != line_num - start_line_idx
        @@source_error = "file truncated"
        return nil
      end

      annotated = [] of String
      line_label_width = line_num.to_s.size
      max_src_line_len = max_annotated_line_width - line_label_width - 1
      usable_line_len = max_src_line_len

      lines.each_with_index do |raw, offset|
        line_num_here = start_line_idx + offset + 1
        line = raw.chomp('\n').chomp('\r').gsub('\t', ' ')

        if line.size > max_src_line_len
          line = line[0...max_src_line_len - truncation_marker.size] + truncation_marker
          usable_line_len = max_src_line_len - truncation_marker.size
        end

        annotated << "#{line_num_here.to_s.rjust(line_label_width)}#{line.empty? ? "" : " "}#{line}"
      end

      if (col = col_num) && col >= 1 && usable_line_len >= col
        column_marker = "column #{col}"
        target_col_idx = col - 1

        if target_col_idx + 2 + column_marker.size > max_src_line_len
          column_marker = "#{" " * (target_col_idx - column_marker.size - 1)}#{column_marker} ^"
        else
          column_marker = "#{" " * target_col_idx}^ #{column_marker}"
        end

        annotated << "#{" " * line_label_width} #{column_marker}"
      end

      annotated
    end

    # Reads the source window (0-based `start_line_idx` up to and
    # including 1-based `line_num`).
    private def self.read_source_lines(path : String, start_line_idx : Int, line_num : Int) : Array(String)?
      all_lines = File.read_lines(path)
      all_lines[start_line_idx...Math.min(line_num, all_lines.size)]
    rescue
      nil
    end

    private def self.vault_encrypted?(path : String) : Bool
      first = File.open(path) { |file| file.read_line }
      first.starts_with?(Vault::HEADER_PREFIX)
    rescue
      false
    end
  end
end
