require "yaml"

module Krikri
  # `throttle:` as the playbook wrote it, kept in that shape until the
  # task is dispatched: ansible-core does not settle the keyword at parse
  # time, its strategy does, once per queued host, with
  # `int(templar.template(task.throttle))` (plugins/strategy/__init__.py's
  # _queue_task). Anything Python's int() refuses there is an AnsibleError
  # that takes the WHOLE run down - after that task's banner, before any
  # host's result, no PLAY RECAP, exit 1 (live-verified vs ansible-core
  # 2.21.6 on issue #1454's `throttle: kpg-many`).
  #
  # So the parse keeps what int() will be handed rather than an Int32:
  # * expr        - a `{{ }}` template, rendered against each host's vars
  #                 at dispatch;
  # * literal     - a plain string int() may refuse (its text is what the
  #                 ValueError quotes);
  # * python_type - a null/list/dict literal, which int() refuses with a
  #                 TypeError naming its Python type;
  # * value       - the number the parse could already settle (an integer,
  #                 bool or numeric string), used for this engine's own
  #                 per-task host cap;
  # * origin      - the value token's own source position, which real
  #                 labels the abort's Origin block with.
  struct ThrottleValue
    getter value : Int32
    getter expr : String?
    getter literal : String?
    getter python_type : String?
    getter origin : {String, Int32, Int32}?
    getter? written : Bool

    def initialize(@value : Int32 = 0, @expr : String? = nil, @literal : String? = nil,
                   @python_type : String? = nil, @origin : {String, Int32, Int32}? = nil,
                   @written : Bool = true)
    end

    # No `throttle:` written at this scope (the default, and what a task
    # inherits from when neither it nor an enclosing block wrote one).
    ABSENT = ThrottleValue.new(written: false)

    def with_origin(origin : {String, Int32, Int32}?) : ThrottleValue
      ThrottleValue.new(@value, @expr, @literal, @python_type, origin, @written)
    end

    def self.from_yaml(yaml : YAML::Any?) : ThrottleValue
      return ABSENT unless yaml

      if expr = template_text(yaml)
        return new(expr: expr)
      end

      case raw = yaml.raw
      when Int    then new(value: clamp_int(raw.to_i64))
      when Bool   then new(value: raw ? 1 : 0)
      when String then from_string(raw)
      else             from_non_numeric(yaml)
      end
    end

    # A whole-value `{{ }}`/`{% %}` template, whose type only a rendered
    # value can decide.
    private def self.template_text(yaml : YAML::Any) : String?
      text = yaml.as_s?
      return nil unless text
      text.includes?("{{") || text.includes?("{%") ? text : nil
    end

    private def self.from_string(raw : String) : ThrottleValue
      if number = python_int(raw)
        new(value: clamp_int(number))
      else
        new(literal: raw)
      end
    end

    private def self.from_non_numeric(yaml : YAML::Any) : ThrottleValue
      case yaml.raw
      when Float
        # real's dispatch conversion accepts int(1.5) == 1, but its
        # keyword post_validate then REFUSES a float ("The value 1.5
        # could not be converted to 'int'", a task failure, rc=2) - a
        # shape this engine does not model. Settling 0 keeps the
        # pre-existing "no cap" behavior instead of applying a truncated
        # cap real never runs a task with.
        new(value: 0)
      when Nil
        new(python_type: "NoneType")
      when Array
        new(python_type: "_AnsibleTaggedList")
      when Hash
        new(python_type: "_AnsibleTaggedDict")
      else
        new
      end
    end

    # Python's int() over a string: surrounding whitespace is ignored, an
    # optional sign is allowed, and single underscores may separate digits
    # ("1_0" is 10, while "1_" and "_1" are refused). nil for everything
    # else int() refuses.
    def self.python_int(text : String) : Int64?
      stripped = text.strip
      return nil unless stripped.matches?(/\A[+-]?\d(?:_?\d)*\z/)
      stripped.delete('_').to_i64?
    end

    # int()'s own refusal text for *text*, or nil when it converts - the
    # ValueError real appends to "Failed to convert the throttle value to
    # an integer: ".
    def self.int_error(text : String) : String?
      return nil if python_int(text)
      "invalid literal for int() with base 10: #{python_repr(text)}"
    end

    # int()'s TypeError text for a non-string, non-number argument, naming
    # the argument's Python type the way real's display does.
    def self.type_error(python_type : String) : String
      "int() argument must be a string, a bytes-like object or a real number, not '#{python_type}'"
    end

    # Python's repr() of a str, which is how int()'s ValueError quotes its
    # argument. Python prefers single quotes, switching to double quotes
    # when the text holds a single quote but no double quote. String#gsub's
    # replacement text is literal, so two backslashes make one.
    def self.python_repr(text : String) : String
      quote = text.includes?('\'') && !text.includes?('"') ? '"' : '\''
      escaped = text.gsub("\\", "\\\\")
      escaped = quote == '"' ? escaped.gsub("\"", "\\\"") : escaped.gsub("'", "\\'")
      escaped = escaped.gsub("\n", "\\n").gsub("\r", "\\r").gsub("\t", "\\t")
      "#{quote}#{escaped}#{quote}"
    end

    private def self.clamp_int(number : Int64) : Int32
      number.clamp(Int32::MIN.to_i64, Int32::MAX.to_i64).to_i32
    end
  end
end
