require "../vault"
require "./output_routing"

module Krikri
  # Matches ansible-core 2.19's task-failure error-block
  # rendering: `Display._error` -> `_display_utils.format_message` ->
  # `_event_formatting.format_event`/`format_event_verbose_message`, over
  # an `Event` tree whose source context comes from
  # `_error_utils.SourceContext.from_origin`. This is what
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
  # a linear cause chain); every shape Ansible 2.19 produces for task
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
      property? chain_follow : Bool
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

    # Ansible composes its "Valid booleans include: ..." enumeration from
    # a Python SET (`BOOLEANS` in module_utils/parsing/convert_bool.py),
    # whose iteration order is randomized per PROCESS. A MODULE runs in a
    # fresh process per invocation on the target, so one module-level bool
    # failure never renders the same text twice and `Display._deduplicate`
    # cannot collapse two of them: a loop's identical failed items - and
    # the same failure on several hosts - each print their own block
    # (live-verified vs ansible-core 2.21.6, issue #952: five expect: items
    # gave five blocks with five orderings, two hosts gave two). krikri
    # keeps this enumeration's order fixed (see
    # PluginHelpers::StrictBoolValidation), so its rendering of the same
    # failures WOULD dedupe - hence the exemption in record_displayed.
    #
    # The identical wording raised controller-side (set_fact's cacheable:,
    # gather_facts' parallel:) comes from the one long-lived controller
    # process, whose set order never changes, so real DOES collapse those
    # repeats into a single block (live-verified vs 2.21.6). Only the
    # module-rendered chain carries the "Module failed: " segment, which is
    # what separates the two.
    SET_ORDERED_BOOL_ENUM = "is not a valid boolean. Valid booleans include: "

    MODULE_FAILED_SEGMENT = "Module failed: "

    # Renders the event tree into Ansible's `[ERROR]: ...` block and
    # prints it, unless the exact text was already displayed (Ansible's
    # `Display._deduplicate` - one global set, so a loop's per-item
    # failures with identical text, or the same failure on several hosts,
    # display the block once). Returns true when printed.
    def self.emit(node : Node) : Bool
      emit_to(STDOUT, node)
    end

    # emit variant capturing to an IO instead of printing: TaskExecutor's
    # unreachable report buffers its block (run_task_batch books
    # unreachable hosts before it knows the task banner is coming, and
    # ansible prints the report under that banner).
    def self.emit_to(io : IO, node : Node) : Bool
      text = "[ERROR]: " + format_event(node)
      return false unless record_displayed(text)
      io.print OutputRouting.normalize_for_display(text)
      true
    end

    # Same rendering and dedup as emit, but on STDERR. Ansible
    # routes an error block to stderr when the error is raised OUTSIDE
    # task result processing - a dynamic include_role:'s role resolution
    # failure ("the role 'x' was not found in ...") - while ordinary
    # task-failure blocks go to stdout (live-verified vs 2.19.11).
    def self.emit_stderr(node : Node) : Bool
      text = "[ERROR]: " + format_event(node)
      return false unless record_displayed(text)
      STDERR.print OutputRouting.normalize_for_display(text)
      true
    end

    # Same dedup and STDERR routing as emit_stderr, for a block already
    # rendered at its raise site (a RemovedModuleError's render carries
    # the Origin context the raise site built from the source map).
    def self.emit_rendered_stderr(text : String) : Bool
      return false unless record_displayed(text)
      STDERR.print OutputRouting.normalize_for_display(text)
      true
    end

    # Books `text` as displayed the way `Display._deduplicate` does (a
    # global set keyed on the rendered message) and returns true when the
    # caller should print it. A module-composed bool enumeration never
    # repeats verbatim in real (see SET_ORDERED_BOOL_ENUM), so it is never
    # booked and always prints.
    private def self.record_displayed(text : String) : Bool
      return true if text.includes?(SET_ORDERED_BOOL_ENUM) && text.includes?(MODULE_FAILED_SEGMENT)
      @@seen.add?(text)
    end

    # Test hook: forget all displayed blocks.
    def self.reset_seen : Nil
      @@seen.clear
    end

    def self.seen?(text : String) : Bool
      @@seen.includes?(text)
    end

    # Matches `_event_formatting.format_event` (no traceback).
    def self.format_event(event : Node) : String
      msg = format_event_verbose_message(event)
      msg = msg.strip
      msg += msg.includes?('\n') ? "\n\n" : "\n"
      msg
    end

    # Matches `_event_formatting.format_event_verbose_message`.
    #
    # A Node owns its outgoing chain link (`chain`/`chain_reason`/
    # `chain_follow` mirror `EventChain.event`/`msg_reason`/`follow`),
    # so the traversal walks node-as-link-owner pairs exactly the way
    # the Python walks EventChain objects.
    def self.format_event_verbose_message(original : Node) : String
      segments = [] of String
      event = original

      while event
        messages, link = collapse_messages(event)

        msg = deduplicate_message_parts(messages)
        segment = message_lines(msg, event.help_text, event.source_context).join('\n') + '\n'
        # An event that captured CHILD events prints them under a boxed
        # "Sub-Event N of M" listing after its own message (real's
        # gather_facts failure: the action's caused-by event carries each
        # failed fact module's own error this way).
        if children = event.events
          segment += format_event_children("Sub-Event", children.map { |child| format_event_verbose_message(child) })
        end
        segments << segment

        if (child = link.chain) && link.chain_follow?
          segments << "\n#{link.chain_reason}\n\n"
          event = child
        else
          event = nil
        end
      end

      segments.insert(0, brief_message(original) + "\n\n") if segments.size > 1
      segments.join
    end

    # Matches `_event_formatting._format_event_children`: each child's
    # formatted message indented behind a "| " gutter, one numbered box
    # per child, closed by an "End" line.
    private def self.format_event_children(label : String, children : Array(String)) : String
      String.build do |io|
        io << '\n'
        children.each_with_index do |child, index|
          io << "+--[ #{label} #{index + 1} of #{children.size} ]---\n"
          io << indent_event_text("\n#{child}\n")
        end
        io << "+--[ End #{label} ]---\n"
      end
    end

    # `textwrap.indent(text, "| ", predicate_always_true)`: EVERY line of
    # the text - blank ones included - gets the gutter prefix.
    private def self.indent_event_text(text : String) : String
      String.build do |io|
        start = 0
        text.each_char_with_index do |char, index|
          next unless char == '\n'
          io << "| "
          io << text[start...index]
          io << '\n'
          start = index + 1
        end
        if start < text.size
          io << "| "
          io << text[start..]
        end
      end
    end

    # The collapsed half of the walk above: from a segment's first node,
    # follow the chain for as long as the links fold into ONE rendered
    # segment. Returns every message folded into that segment and the
    # last link reached (the owner of the next chain hop, or the final
    # node when the chain ends here).
    private def self.collapse_messages(event : Node) : {Array(String), Node}
      messages = [event.msg]
      link = event

      while (child = link.chain) && link.chain_follow?
        break if child.events

        if child.source_context || child.help_text
          # Ansible's SourceContext carries no value equality, so two
          # events never share one: a child with its OWN source
          # context always ends the collapsed segment, even when it
          # renders byte-identical text to its parent's (its parent's
          # is then simply repeated). Live-verified against 2.19.11 on
          # include_role:'s bool-keyword conversion failure, whose
          # last two links both point at the same value and still
          # print as two segments.
          break if !child.source_context.nil? || child.help_text != event.help_text
        end

        break if child.chain && link.chain_reason != child.chain_reason

        messages << child.msg
        link = child
      end

      {messages, link}
    end

    # Matches `_event_utils.deduplicate_message_parts`.
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

    # Matches `_event_utils.format_event_brief_message`.
    def self.brief_message(event : Node) : String
      parts = [] of String
      loop do
        parts << event.msg
        chain = event.chain
        break unless event.chain_follow? && chain
        event = chain
      end
      deduplicate_message_parts(parts)
    end

    # Matches `_text_utils.concat_message`.
    def self.concat_message(left : String, right : String) : String
      "#{left.rstrip(". ")}: #{right}"
    end

    # Matches `_event_formatting._get_message_lines`.
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

    # Matches `_error_utils.SourceContext.from_origin` + `#to_s`:
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
    # in which case @@source_error holds Ansible's reason text.
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
