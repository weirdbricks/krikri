module Krikri
  # Best-effort `ast.literal_eval` for Python-literal text that JSON cannot
  # parse: rewrites Python's single-quoted strings and True/False/None into
  # their JSON spellings and hands the result to the JSON parser. Returns
  # nil when that fails, which lands the caller on check_type_dict's own
  # failure - the same shapes literal_eval itself rejects (bare names,
  # tuples, sets, trailing junk) fail the rewrite or the JSON parse, so a
  # caller only ever accepts what real Ansible's check_type_dict would
  # accept as a dict. Mirrors the approach InventoryParser already uses for
  # inventory-sourced literals.
  module PythonLiteral
    # Python keyword -> JSON spelling.
    private KEYWORDS = {"True" => "true", "False" => "false", "None" => "null"}

    def self.dict_json(value : String) : JSON::Any?
      JSON.parse(rewrite(value))
    rescue
      nil
    end

    private def self.rewrite(value : String) : String
      String.build do |str|
        index = 0
        while index < value.size
          case value[index]
          when '\''
            # A single-quoted Python string becomes a JSON string; inner
            # double quotes have to be escaped on the way.
            index = append_quoted(str, value, index, '\'', "\\\"")
          when '"'
            index = append_quoted(str, value, index, '"', "\\")
          else
            index = append_keyword_or_char(str, value, index)
          end
        end
      end
    end

    # Copies one quoted string to the builder as a JSON string; `escapes`
    # lists the characters that need a JSON backslash on the way (Python
    # single-quoted strings must escape inner double quotes, double-quoted
    # ones only their backslashes). Returns the index past the closing
    # quote; an unterminated string just runs to the end (the JSON parse
    # then fails, like literal_eval would).
    private def self.append_quoted(str : String::Builder, value : String, index : Int32, quote : Char, escapes : String) : Int32
      str << '"'
      index += 1
      while index < value.size && value[index] != quote
        str << "\\" if escapes.includes?(value[index])
        str << value[index]
        index += 1
      end
      str << '"'
      index + 1
    end

    # Rewrites a bare Python keyword at index, or copies the character
    # through. Returns the next index.
    private def self.append_keyword_or_char(str : String::Builder, value : String, index : Int32) : Int32
      KEYWORDS.each do |word, json|
        if value[index, word.size]? == word
          str << json
          return index + word.size
        end
      end
      str << value[index]
      index + 1
    end
  end
end
