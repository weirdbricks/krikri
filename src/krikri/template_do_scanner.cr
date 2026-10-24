# Jinja2's statement is behind the jinja2.ext.do extension, and ansible-core
# never loads that extension on its template environment - live-verified
# against ansible-core 2.19 / Jinja2 3.1.6 (issue #322,
# pgvillage.chainsmith's chainsmith_cert_files default, which builds a list
# with `{% for %}{% do files.append(...) %}{% endfor %}`): ANY `{% do ... %}`
# tag is a hard TemplateSyntaxError at template-COMPILE time - in task args,
# in vars/defaults, and in .j2 template files alike. krikri's own engine
# (krikri-jinja) DOES support `do`, so without this pre-parse check krikri
# silently renders what ansible rejects and keeps playing. The refusal must
# live in this krikri ansible-parity layer: krikri-jinja's own feature set is
# pinned by its engine tests (e.g. the list.reverse canary renders via
# `{% do %}`) and may not drop the statement.
#
# The scan understands exactly the token shapes real Jinja lexes (each
# clause live-verified against Jinja2 3.1.6):
# - string literals inside a tag or a `{{ }}` span swallow their `{%`, `%}`,
#   `{{` and `}}` characters: `{% set a = '{% do %}' %}` and
#   `{{ '{% do x %}' }}` are legal and must never raise;
# - `{# #}` comment bodies are literal;
# - a `{% raw %}` body is literal until its own `{% endraw %}` tag;
# - `{% dofoo %}` is NOT a `do` tag (the word is matched exactly), and
#   `{%do a%}` is one (leading whitespace is not).
#
# The message matches ansible's, including the parser suffix when the `do`
# sits inside an open block (live-verified message matrix vs Jinja2 3.1.6):
# - top level: "Encountered unknown tag 'do'."
# - inside a for body: "... Jinja was looking for the following tags:
#   'endfor' or 'else'. The innermost block that needs to be closed is
#   'for'." (a for's own `{% else %}` narrows that to just 'endfor')
# - inside an if body: "...'elif' or 'else' or 'endif'. ... is 'if'."
#   (an if's `{% else %}` narrows that to just 'endif')
# - other body blocks name their single end tag ('endset', 'endmacro',
#   'endcall', 'endfilter', 'endblock', 'endwith', 'endautoescape'); a
#   one-liner `{% set x = 1 %}` opens no body at all (verified: plain
#   wording). Anything uncertain falls back to the plain one-sentence
#   wording rather than risk a wrong suffix.
module Krikri
  module TemplateDoTagScanner
    # End tokens an open block's body waits on - the parser's "Jinja was
    # looking for" list. Branch blocks (`if`/`for`) hand their body that
    # exact list, and their own `{% else %}` clause closes the branch list
    # down to the single end tag.
    private BRANCH_END_TOKENS = {
      "if" => {"elif", "else", "endif"}, "for" => {"endfor", "else"},
      "macro" => {"endmacro"}, "call" => {"endcall"},
      "filter" => {"endfilter"}, "block" => {"endblock"},
      "with" => {"endwith"}, "autoescape" => {"endautoescape"},
      "set" => {"endset"}, "generator" => {"endgenerator"},
    }

    private DEFAULT_DO_GATE = /\{%[-\s+]*do\b/

    # One enclosing body-holding block.
    private struct Frame
      property tag : String
      property? else_phase : Bool

      def initialize(@tag : String, @else_phase = false)
      end

      def end_tokens : Array(String)
        if else_phase?
          ["end#{tag}"]
        else
          (BRANCH_END_TOKENS[tag]? || ["end#{tag}"]).to_a
        end
      end
    end

    # nil when no `{% do %}` tag parses in *text*, else ansible's bare error
    # wording ("Syntax error in template: " is added by the raising call
    # sites, exactly like stray_end_tag_message returns bare words).
    # Delimiters are parameterizable for the template action's custom
    # overrides; the defaults are Jinja's own.
    def self.do_tag_error(text : String, block_start = "{%", block_end = "%}",
                          var_start = "{{", var_end = "}}",
                          comment_start = "{#", comment_end = "#}") : String?
      # Cheap pre-gate: the scan is linear and runs on every strict tag
      # render, template file and variable read, but it only ever has to run
      # when a do-tag token can exist at all. False positives are harmless
      # (the scan decides: `{% domain %}` matches the gate and not the
      # scan), and the gate covers `{%do`/`{%- do`/`{%+ do` alike so no
      # real `do` tag is skipped.
      gate = block_start == "{%" ? DEFAULT_DO_GATE : Regex.new("#{Regex.escape(block_start)}[-\\s+]*do\\b")
      return nil unless text.includes?("do") && text.matches?(gate)

      frames = [] of Frame
      i = 0
      while i < text.size
        pos, kind = next_token(text, i, var_start, block_start, comment_start) || break
        case kind
        when :var
          # A `{{ }}` span's body is never re-scanned: its string literals
          # can hold `{%`/`%}` characters that are not tags (verified:
          # `{{ '{% do x %}' }}` renders the literal text in real Jinja
          # without erroring).
          i = (span_close(text, pos + var_start.size, var_end) || return nil)[1]
        when :comment
          i = (text.index(comment_end, pos + comment_start.size) || return nil) + comment_end.size
        else
          step = block_step(text, pos, frames, block_start, block_end) || return nil
          i, error = step
          return error if error
        end
      end
      nil
    end

    # Position and kind of the earliest `{{`, `{%` or `{#` opener at/after *from*.
    private def self.next_token(text : String, from : Int32, var_start : String,
                                block_start : String, comment_start : String) : {Int32, Symbol}?
      found = [{text.index(var_start, from), :var}, {text.index(comment_start, from), :comment},
               {text.index(block_start, from), :block}]
        .compact_map { |pos, kind| pos ? {pos, kind} : nil }
      found.min_by? { |pos, _| pos }
    end

    # Handles one `{% %}` tag at *open*: {index after it, bare error or nil},
    # nil when the tag never closes (the engine's own failure to report).
    private def self.block_step(text : String, open : Int32, frames : Array(Frame),
                                block_start : String, block_end : String) : {Int32, String?}?
      tag_open = open + block_start.size
      close_at, close_end = span_close(text, tag_open, block_end) || return nil
      content = text[tag_open...close_at]
      word = first_tag_word(content)
      return {close_end, nil} unless word
      return {close_end, frames.empty? ? "Encountered unknown tag 'do'." : do_message(frames.last)} if word == "do"
      if word == "raw"
        # Raw bodies are literal text until their endraw tag - a `do`
        # inside one is content, not a statement (verified).
        raw_end = scan_raw_body(text, close_end, block_start, block_end) || return nil
        return {raw_end, nil}
      end
      track_frames(word, content, frames)
      {close_end, nil}
    end

    private def self.track_frames(word : String, content : String, frames : Array(Frame)) : Nil
      top = frames.last?
      if word == "else"
        top.else_phase = true if top && !top.else_phase? && top.end_tokens.includes?("else")
      elsif word.starts_with?("end")
        frames.pop if top && top.tag == word[3..]
      elsif BRANCH_END_TOKENS.has_key?(word) && block_form_tag?(word, content)
        frames << Frame.new(word)
      end
    end

    # The parser's suffix for a `do` inside an open block (live-verified):
    # "Jinja was looking for the following tags: 'endfor' or 'else'. The
    # innermost block that needs to be closed is 'for'."
    private def self.do_message(frame : Frame) : String
      looking = frame.end_tokens.map { |token| "'#{token}'" }.join(" or ")
      "Encountered unknown tag 'do'. Jinja was looking for the following tags: " \
      "#{looking}. The innermost block that needs to be closed is '#{frame.tag}'."
    end

    # `set` is a body block only in its block form (`{% set x %}`), which
    # Jinja picks when the tag holds no `=` token; a one-liner
    # (`{% set x = 1 %}`, even one carrying `=` inside a string literal)
    # is an expression statement and opens nothing (verified: plain
    # wording). Every other opener is a body block unconditionally.
    private def self.block_form_tag?(tag : String, content : String) : Bool
      return true unless tag == "set"
      !remove_quoted_text(content).includes?("=")
    end

    # The tag's statement keyword: everything up to the first
    # non-identifier character. Whitespace-control markers (`-`/`+`) ride
    # inside the delimiters and are trimmed off first.
    private def self.first_tag_word(content : String) : String?
      rest = content.strip
      while rest.starts_with?('-') || rest.starts_with?('+')
        rest = rest[1..].strip
      end
      match = rest.match(/\A[a-zA-Z_][A-Za-z0-9_]*/)
      match.try(&.[0])
    end

    # Pair {start, end} of the next unquoted *closer* at/after *from*:
    # double/single quotes with backslash escapes are both honored (real
    # Jinja lexes `{% set a = "x%}y" %}` fine - the `%}` inside the literal
    # is never a tag end; `{{ "}}" }}` stays one span too). nil when never
    # closed - an unclosed span is the engine's own parser failure to
    # report, never this scan's.
    private def self.span_close(text : String, from : Int32, closer : String) : {Int32, Int32}?
      i = from
      quote : Char? = nil
      while i < text.size
        char = text[i]
        if inner = quote
          if char == '\\'
            i += 2
            next
          end
          quote = nil if char == inner
        elsif char == '\'' || char == '"'
          quote = char
        elsif text[i, closer.size] == closer
          return {i, i + closer.size}
        end
        i += 1
      end
      nil
    end

    # Raw-body scan: literal until the first block tag whose word is
    # `endraw` (trim-dash variants included, verified). Quote awareness is
    # deliberately NOT applied inside a raw body - it is all literal text,
    # and its `{% "..." %}` sequences are candidates like any other.
    private def self.scan_raw_body(text : String, from : Int32, block_start : String, block_end : String) : Int32?
      i = from
      while i < text.size
        open = text.index(block_start, i) || return nil
        _, close_end = span_close(text, open + block_start.size, block_end) || return nil
        content = text[open + block_start.size...close_end - block_end.size]
        i = close_end
        word = first_tag_word(content)
        return i if word == "endraw"
      end
      nil
    end

    # Removes `"..."`/`'...'` literal spans (escape-aware) so a structural
    # check like block_form_tag?'s `=` probe never trips on text a string
    # literal carries (`{% set x = "a=b" %}` is an expression statement).
    private def self.remove_quoted_text(content : String) : String
      result = String::Builder.new
      i = 0
      quote : Char? = nil
      while i < content.size
        char = content[i]
        if inner = quote
          if char == '\\'
            i += 2
            next
          end
          quote = nil if char == inner
        elsif char == '\'' || char == '"'
          quote = char
        else
          result << char
        end
        i += 1
      end
      result.to_s
    end
  end
end
