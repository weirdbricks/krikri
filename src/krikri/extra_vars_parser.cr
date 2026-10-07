require "json"
require "./unsafe_values"
require "./var_origin"
require "yaml"

module Krikri
  # `-e` / `--extra-vars`, Ansible's highest-precedence variable
  # scope. Every accepted form below was checked against a
  # ansible-core 2.19.4 before being implemented here:
  #
  #   -e key=value            one or more whitespace-separated k=v pairs;
  #                           the value is ALWAYS a string, so
  #                           `-e num=5` yields "5" (type_debug: str),
  #                           not the integer 5
  #   -e '{"k": 1}'          a JSON object - real types preserved, so
  #                           num stays an int here
  #   -e @vars.yml            load a YAML (or JSON) file
  #   repeated -e             later occurrences win on a key collision
  #
  # Precedence relative to everything else is handled by the executor,
  # which applies the parsed result last - see TaskExecutor's @extra_vars.
  module ExtraVarsParser
    class Error < Exception
    end

    # Parses CLI occurrences in order, merging later over earlier.
    def self.parse(occurrences : Array(String)) : Hash(String, JSON::Any)
      parse_with_origins(occurrences)[0]
    end

    # Same merge, plus the ORIGINS of the values that came from an
    # `-e @file` occurrence (see VarOrigin): real points a name-template
    # error inside such a value at the FILE's own value position
    # (live-verified vs 2.19.11: an `-e @extra.yml` entry
    # `evf: "{{ undef_evf }}"` reports `Origin: .../extra.yml:1:6` with
    # the usual excerpt+caret, NOT `Origin: <CLI option '-e'>`). k=v and
    # inline-JSON occurrences have no file origin; a key they (re)define
    # ERASES any file origin an earlier occurrence gave it, matching the
    # value that actually wins.
    def self.parse_with_origins(occurrences : Array(String)) : {Hash(String, JSON::Any), Hash(String, VarOrigin)}
      merged = {} of String => JSON::Any
      origins = {} of String => VarOrigin
      occurrences.each do |raw|
        values, file_origins = parse_one_with_origins(raw)
        values.each do |key, value|
          merged[key] = value
          origin = file_origins.try(&.[key]?)
          if origin
            origins[key] = origin
          else
            origins.delete(key)
          end
        end
      end
      {merged, origins}
    end

    private def self.parse_one_with_origins(raw : String) : {Hash(String, JSON::Any), Hash(String, VarOrigin)?}
      value = raw.strip
      raise Error.new("--extra-vars given an empty value") if value.empty?

      case value[0]
      when '@'      then from_file(value[1..])
      when '{', '[' then {from_structured(value), nil}
      else               {from_pairs(value), nil}
      end
    end

    private def self.from_file(path : String) : {Hash(String, JSON::Any), Hash(String, VarOrigin)?}
      raise Error.new("extra-vars file not found: #{path}") unless File.exists?(path)

      values = from_structured(File.read(path), source: path)
      # The file's top-level keys' own source positions - real reports
      # the failing value's own line/column (and excerpt) in the file,
      # exactly like a vars_files: entry.
      {values, VarOrigin.vars_file_origins(path, values.keys)}
    end

    # JSON and YAML both, because Ansible accepts either for an
    # inline value and for an @file - and JSON is a subset of YAML, so
    # one parser covers both. Parsed via YAML::Any then re-encoded to
    # JSON::Any, the representation the rest of the engine uses.
    private def self.from_structured(text : String, source : String? = nil) : Hash(String, JSON::Any)
      parsed = begin
        UnsafeValues.mark_yaml_text(text)
        YAML.parse(text)
      rescue ex
        raise Error.new("could not parse extra-vars#{source ? " from #{source}" : ""}: #{ex.message}")
      end

      hash = parsed.as_h?
      unless hash
        raise Error.new("extra-vars#{source ? " from #{source}" : ""} must be a mapping of names to values, not a #{parsed.raw.class}")
      end

      result = {} of String => JSON::Any
      hash.each do |key, value|
        result[key.to_s] = JSON.parse(value.to_json)
      end
      result
    end

    # `-e "k1=v1 k2=v2"` - whitespace-separated pairs, values always
    # strings. A value may itself contain '=' (`-e url=a=b`), so only the
    # FIRST '=' separates.
    #
    # The whitespace split is Ansible's split_args
    # (ansible/parsing/splitter.py), not a bare String#split: tokens
    # broken across a space INSIDE a jinja2 block (`-e 'ev={{ 2 }}'` -
    # live-verified vs 2.19.11: real renders this as 2) or inside
    # quotes are reassembled, so they reach the k=v split whole. A bare
    # split truncated the value at the first space (`ev={{ 2 }}` stored
    # just `{{`), which surfaced as a bogus "unexpected end of template"
    # (or an unrendered `{{ ev }}` in a task name) instead of real's
    # rendered value. Unbalanced quotes/blocks raise, like real's
    # "failed at splitting arguments, either an unbalanced jinja2 block
    # or quotes" AnsibleParserError.
    private def self.from_pairs(text : String) : Hash(String, JSON::Any)
      result = {} of String => JSON::Any
      split_args(text).each do |pair|
        separator = pair.index('=')
        # parse_kv drops a token without '=' (Ansible ignores it)
        next unless separator && separator > 0

        key = pair[0...separator].strip
        next if key.empty?

        # parse_kv: options[k.strip()] = unquote(v.strip()) - a matching
        # surrounding quote pair is the VALUE's own quoting, dropped
        # before the value is stored.
        result[key] = JSON::Any.new(unquote(pair[(separator + 1)..].strip))
      end
      result
    end

    # Port of ansible.parsing.splitter.split_args: split on whitespace,
    # reassembling tokens broken inside quotes or a jinja2 block
    # ({{ }}, {% %}, {# #}). Line continuations (a bare `\` token
    # outside quotes) are dropped, like real.
    private def self.split_args(args : String) : Array(String) # ameba:disable Metrics/CyclomaticComplexity
      params = [] of String

      quote_char = nil
      inside_quotes = false
      print_depth = 0
      block_depth = 0
      comment_depth = 0

      items = args.split('\n')
      items.each_with_index do |item, itemidx|
        tokens = item.split(' ')
        line_continuation = false
        tokens.each_with_index do |token, idx|
          if token.empty? && idx != 0
            # Empty entries are subsequent spaces - keep them so the
            # original spacing inside a reassembled token survives.
            if params.empty?
              params << ""
            else
              params[-1] += " "
            end
            next
          end

          if token == "\\" && !inside_quotes
            line_continuation = true
            next
          end

          was_inside_quotes = inside_quotes
          quote_char = get_quote_state(token, quote_char)
          inside_quotes = !quote_char.nil?

          appended = false

          if inside_quotes && !was_inside_quotes && print_depth == 0 && block_depth == 0 && comment_depth == 0
            params << token
            appended = true
          elsif print_depth != 0 || block_depth != 0 || comment_depth != 0 || inside_quotes || was_inside_quotes
            if idx == 0 && was_inside_quotes
              params[-1] += token
            else
              spacer = idx > 0 ? " " : ""
              params[-1] += spacer + token
            end
            appended = true
          end

          prev_print_depth = print_depth
          print_depth = count_jinja2_blocks(token, print_depth, "{{", "}}")
          if print_depth != prev_print_depth && !appended
            params << token
            appended = true
          end

          prev_block_depth = block_depth
          block_depth = count_jinja2_blocks(token, block_depth, "{%", "%}")
          if block_depth != prev_block_depth && !appended
            params << token
            appended = true
          end

          prev_comment_depth = comment_depth
          comment_depth = count_jinja2_blocks(token, comment_depth, "{#", "#}")
          if comment_depth != prev_comment_depth && !appended
            params << token
            appended = true
          end

          if print_depth == 0 && block_depth == 0 && comment_depth == 0 && !inside_quotes && !appended && token != ""
            params << token
          end
        end

        if items.size > 1 && itemidx != items.size - 1 && !line_continuation
          params << "" if params.empty?
          params[-1] += "\n"
        end
      end

      if print_depth != 0 || block_depth != 0 || comment_depth != 0 || inside_quotes
        raise Error.new("failed at splitting arguments, either an unbalanced jinja2 block or quotes: #{args}")
      end

      params
    end

    # splitter.py's _get_quote_state: is *token* still inside a quoted
    # run, and which quote character governs it? Unescaped quotes
    # toggle the state.
    private def self.get_quote_state(token : String, quote_char : Char?) : Char?
      prev : Char? = nil
      token.each_char_with_index do |char, idx|
        if idx > 0
          prev = token[idx - 1]
        end
        if (char == '"' || char == '\'') && prev != '\\'
          if quote_char
            quote_char = nil if char == quote_char
          else
            quote_char = char
          end
        end
      end
      quote_char
    end

    # splitter.py's _count_jinja2_blocks: adjust *cur_depth* by this
    # token's imbalance of open/close markers (clamped at 0).
    private def self.count_jinja2_blocks(token : String, cur_depth : Int32, open_token : String, close_token : String) : Int32
      num_open = token.scan(open_token).size
      num_close = token.scan(close_token).size
      if num_open != num_close
        cur_depth += num_open - num_close
        cur_depth = 0 if cur_depth < 0
      end
      cur_depth
    end

    # quoting.py's unquote: strip one matching surrounding quote pair.
    private def self.unquote(value : String) : String
      return value unless value.size >= 2

      first = value[0]
      last = value[-1]
      if (first == '"' && last == '"') || (first == '\'' && last == '\'')
        value[1..-2]
      else
        value
      end
    end
  end
end
