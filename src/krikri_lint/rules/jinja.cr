require "krikri-jinja/krikri_jinja"

module Krikri
  module Lint
    # Upstream parity: ansible-lint's jinja rule family (severity LOW,
    # tags formatting). We implement two sub-rules:
    #  - jinja[invalid]: Jinja templates that fail to parse (via krikri-jinja)
    #  - jinja[spacing]: missing inner padding, `{{ x }}` not `{{x}}`
    # Upstream additionally reformats expressions with black; that full
    # reformat is a deliberate non-goal (black-based, not a parity gap
    # this ruleset attempts to close).
    class JinjaRule < Rule
      def id : String
        "jinja"
      end

      def severity : Severity
        Severity::LOW
      end

      def tags : Array(String)
        ["formatting"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      # Task-oriented: violations belong to an enclosing task, so a
      # `# noqa:` anywhere in that task's body suppresses them.
      def task_scoped? : Bool
        true
      end

      # Upstream's jinja transform only fixes jinja[spacing] (and only
      # when it can locate the templated value); jinja[invalid] gets the
      # "not applied" ERROR.
      def transformable? : Bool
        true
      end

      def marks_fixed?(violation : Violation) : Bool
        violation.rule_id == "jinja[spacing]"
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          found = [] of {String, Int32, Int32}
          collect_templates(task.node, found)
          found.each do |(value, line, column)|
            unless valid_jinja?(value)
              violations << Violation.new(file.path, line, column,
                "jinja[invalid]", severity,
                "Syntax error in jinja2 template: #{value}", task.line)
              next
            end
            if (reformatted = spacing_fix(value)) && reformatted != value
              violations << Violation.new(file.path, line, column,
                "jinja[spacing]", severity,
                "Jinja2 spacing could be improved: #{value} -> #{reformatted}",
                task.line, false,
                "Jinja2 template rewrite recommendation: `#{reformatted}`.")
            end
          end
        end
      end

      # Walks every string value in the task (skipping the name key and
      # block/rescue/always sublists, like upstream's nested_items_path).
      private def collect_templates(node : YAML::Nodes::Node, found : Array({String, Int32, Int32})) : Nil
        case node
        when YAML::Nodes::Mapping
          NodeUtil.each_entry(node) do |k, v|
            key = k.as?(YAML::Nodes::Scalar).try(&.value)
            next if key == "name" || key == "block" || key == "rescue" ||
                    key == "always"
            collect_templates(v, found)
          end
        when YAML::Nodes::Sequence
          node.nodes.each do |child|
            collect_templates(child, found)
          end
        when YAML::Nodes::Scalar
          if (value = node.value) && value.includes?("{{")
            found << {value, NodeUtil.line(node), NodeUtil.column(node)}
          end
        end
      end

      private def valid_jinja?(value : String) : Bool
        KrikriJinja::Parser.parse(value)
        true
      rescue KrikriJinja::TemplateError
        false
      end

      # Narrow spacing normalization: `{{x}}` -> `{{ x }}`. Upstream
      # reformats the expression body with black; that full reformat is a
      # deliberate non-goal (see the class comment). This approximates the
      # part that is purely about the braces: upstream keeps whatever
      # padding the expression already had on its inner left side (adding
      # a single space when there is none), strips whatever is on the
      # inner right side, and puts exactly one space back.
      #
      # Only the padding next to the braces is touched - never the body
      # itself, which is why a dict literal closing with `}}` inside a
      # block is not mistaken for the block's own delimiter.
      #
      # A block whose body spans lines disables the check for the whole
      # string: upstream's reformat raises NotImplementedError as soon as
      # one expression contains a newline and then returns the original
      # text unchanged, so nothing is reported - not even for the
      # single-line blocks sitting next to it.
      # ansible-lint's jinja scanner treats {% raw %}...{% endraw %} text
      # as literal, not templated: a `{{x}}` inside it is what the target
      # command actually receives, so respacing it would change behavior
      # (e.g. docker's `--format '{{.Names}}'`). We therefore fix spacing
      # only in the non-raw segments and pass raw text through verbatim.
      private def spacing_fix(value : String) : String?
        return nil unless value.includes?("{{")
        if (raws = raw_spans(value)).empty?
          return nil if multiline_block?(value)
          fixed = pad_blocks(value)
          fixed == value ? nil : fixed
        else
          fix_around_raw(value, raws)
        end
      end

      private def fix_segment(segment : String) : String?
        return nil if segment.empty?
        return nil unless segment.includes?("{{")
        return nil if multiline_block?(segment)
        fixed = pad_blocks(segment)
        fixed == segment ? nil : fixed
      end

      # Fix each non-raw segment independently and splice the raw text
      # back unchanged. The multiline bail-out is per segment too: raw
      # text is not an expression, so a newline inside it must not
      # suppress the check for real blocks elsewhere in the value.
      private def fix_around_raw(value : String, raws : Array({Int32, Int32})) : String?
        result = String::Builder.new
        changed = false
        cursor = 0
        raws.each do |(raw_start, raw_end)|
          segment = value[cursor...raw_start]
          if (fixed = fix_segment(segment))
            changed = true
            result << fixed
          else
            result << segment
          end
          result << value[raw_start...raw_end]
          cursor = raw_end
        end
        tail = value[cursor..]
        if (fixed = fix_segment(tail))
          changed = true
          result << fixed
        else
          result << tail
        end
        changed ? result.to_s : nil
      end

      # Byte-index spans of the literal text of every {% raw %} section.
      # An unterminated {% raw %} makes the whole remainder literal (that
      # is how the Jinja lexer consumes it, up to the syntax error it
      # then raises - which jinja[invalid] reports separately).
      private def raw_spans(value : String) : Array({Int32, Int32})
        spans = [] of {Int32, Int32}
        pos = 0
        while (open_at = value.index(RAW_OPEN, pos))
          body_start = value.index!("%}", open_at) + 2
          end_at = value.index(RAW_CLOSE, body_start)
          if end_at
            raw_end = value.index!("%}", end_at) + 2
          else
            raw_end = value.size
          end
          spans << {open_at, raw_end}
          pos = raw_end
          break if end_at.nil?
        end
        spans
      end

      # Rewrite the inner padding of every {{ }} block in turn, skipping
      # whitespace-control forms ({{- / -}}) whose marker sits where the
      # padding would go.
      private def pad_blocks(value : String) : String
        fixed = value.dup
        pos = 0
        while (open_at = fixed.index("{{", pos))
          open_end = open_at + 2
          close_at = find_block_end(fixed, open_end)
          break unless close_at
          # "{{- x -}}": the marker sits where the padding would go on
          # either side, so leave this block untouched.
          if fixed[open_end]? == '-' || fixed[close_at - 1]? == '-'
            pos = close_at + 2
          else
            normalized = normalized_body(fixed[open_end...close_at])
            fixed = fixed[0...open_end] + normalized + fixed[close_at..]
            pos = open_end + normalized.size
          end
        end
        fixed
      end

      # Index of the `}}` that closes a {{ }} block opened before
      # `from`. Brace depth is tracked so that a dict literal inside the
      # expression (`{{ {'a': 1}} | f }}`) is not mistaken for the
      # block's own delimiter; quotes hide their contents.
      private def find_block_end(value : String, from : Int32) : Int32?
        depth = 0
        i = from
        while i < value.size
          case value[i]
          when '\''
            i = skip_quoted(value, i, '\'')
            next
          when '"'
            i = skip_quoted(value, i, '"')
            next
          when '{'
            depth += 1
          when '}'
            if depth == 0
              return i if value[i + 1]? == '}'
            else
              depth -= 1
            end
          end
          i += 1
        end
        nil
      end

      # Index just past the closing quote of the quoted scalar starting
      # at `start`. A quote of the same kind is escaped by doubling it.
      private def skip_quoted(value : String, start : Int32, quote : Char) : Int32
        i = start + 1
        while i < value.size
          if value[i] == quote
            if value[i + 1]? == quote
              i += 2
              next
            end
            return i + 1
          end
          i += 1
        end
        i
      end

      # Leading padding is kept verbatim (a single space when there is
      # none), the body is stripped of surrounding whitespace, and a
      # single space is appended on the right.
      private def normalized_body(body : String) : String
        leading = body[0, body.size - body.lstrip.size]
        leading = " " if leading.empty?
        stripped = body.strip
        return " " if stripped.empty?
        leading + stripped + " "
      end

      # The raw/endraw tags may carry whitespace-control modifiers
      # ({%- raw -%}); either spelling still opens/closes the literal span.
      private RAW_OPEN  = /\{%[-+]?\s*raw\s*[-+]?%\}/
      private RAW_CLOSE = /\{%[-+]?\s*endraw\s*[-+]?%\}/

      # True when any {{ }} block in the value has a line break between
      # its delimiters.
      private def multiline_block?(value : String) : Bool
        pos = 0
        while (open_at = value.index("{{", pos))
          close_at = find_block_end(value, open_at + 2)
          return false unless close_at
          return true if value[open_at...close_at].includes?('\n')
          pos = close_at + 2
        end
        false
      end
    end
  end
end
