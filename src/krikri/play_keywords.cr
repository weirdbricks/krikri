require "yaml"
require "./param_sentinels"
require "./role_bool_keywords"
require "./yaml_source_map"

module Krikri
  # Play-level keyword post-validation. ansible-core's PlaybookExecutor
  # calls Play.post_validate after the play's vars_prompt answers are
  # consumed but before its banner and hosts matching, so a play keyword
  # declared `always_post_validate` that is not convertible to its
  # declared type aborts the WHOLE run (rc=4) at that point - plays
  # before it already ran and printed, the play itself prints nothing:
  #
  #     [ERROR]: Error processing keyword 'gather_facts': The value
  #     'kpg-maybe' could not be converted to 'bool'.
  #
  #     Error processing keyword 'gather_facts'.
  #     Origin: pb.yml:5:17
  #     ...
  #     <<< caused by >>>
  #
  #     The value 'kpg-maybe' could not be converted to 'bool'.
  #     Origin: pb.yml:5:17
  #     ...
  #
  # Only the play's own always_post_validate keywords reach this. For the
  # bool ones that is `gather_facts:` and `force_handlers:`: every other
  # bool play keyword (`become:`, `any_errors_fatal:`, `check_mode:`) is
  # an inherited FieldAttribute, and Play.post_validate skips those
  # unless `always_post_validate` is set. Their conversion failure belongs
  # to the TASK post-validation each inheriting task (handlers included)
  # performs when it runs - `Task` sets `_post_validate_object`, unlike
  # `Play` - which is why `any_errors_fatal: kpg-maybe` fails every task
  # it reaches instead of the play (issue #1465; see Task#
  # any_errors_fatal_invalid).
  # `max_fail_percentage:` is another one, with ansible's `percent` type:
  # a string loses its `%` characters and is then parsed by Python's
  # float(), so `50%` is accepted while `kpg-many` aborts the run with
  # "... could not be converted to 'percent'." (issue #1471).
  # The conversions are ansible's `boolean(strict=True)` / `float()`
  # over the raw value, and the reported value is its Python repr().
  module PlayKeywords
    # Each keyword with the field-attribute type ansible declares for it,
    # in ansible's own fattributes order - a play with several
    # unconvertible ones reports the first (live-verified vs 2.21.6).
    KEYWORDS = [
      {"gather_facts", "bool"},
      {"force_handlers", "bool"},
      {"max_fail_percentage", "percent"},
    ]

    struct Failure
      getter keyword : String
      getter isa : String
      getter value_repr : String
      getter origin : Tuple(Int32, Int32)?

      def initialize(@keyword : String, @isa : String, @value_repr : String, @origin : Tuple(Int32, Int32)? = nil)
      end

      # Ansible's innermost cause link.
      def conversion_message : String
        "The value #{@value_repr} could not be converted to '#{@isa}'."
      end

      # Ansible's outer cause link.
      def keyword_message : String
        "Error processing keyword '#{@keyword}'."
      end
    end

    # The first keyword (in Ansible's order) whose literal value is not
    # convertible to its declared type, with the value's source position
    # when the parser could resolve one.
    def self.failure(play_yaml : Hash(YAML::Any, YAML::Any), source_map : YamlSourceMap?, prefix : String) : Failure?
      KEYWORDS.each do |(keyword, isa)|
        value = play_yaml[keyword]?
        next unless value
        # A templated value is resolved against the play's vars before the
        # conversion runs, at execution time; its failure (and message)
        # belongs to that path, not this one.
        next if templated?(value)
        convertible = isa == "bool" ? convertible_to_bool?(value) : percent_convertible?(value)
        next if convertible
        origin = source_map.try(&.at?("#{prefix}/#{keyword}"))
        return Failure.new(keyword, isa, RoleBoolKeywords.python_repr(value), origin)
      end
      nil
    end

    # ansible's `percent` field conversion: a string's `%` characters are
    # removed, then Python's float() parses the rest. nil means "not a
    # percent value" - Play.post_validate never converts a None one.
    def self.percent_value(value : YAML::Any) : Float64?
      case raw = value.raw
      when Nil     then nil
      when Bool    then raw ? 1.0 : 0.0
      when Int64   then raw.to_f64
      when Float64 then raw
      when String
        # An integer wider than Int64 arrives as our bigint sentinel,
        # which is a Python int to ansible; float() raises OverflowError
        # on one it cannot represent, so that stays unconvertible.
        if digits = Krikri.bigint_digits(raw)
          number = digits.to_f64
          return number.infinite? ? nil : number
        end
        python_float(raw.includes?('%') ? raw.gsub('%', "") : raw)
      end
    end

    private def self.percent_convertible?(value : YAML::Any) : Bool
      value.raw.nil? || !percent_value(value).nil?
    end

    # ansible's boolean() lowercases AND strips a string before matching
    # its tables, so `gather_facts: " true "` is accepted - but the error
    # message still quotes the value as written.
    private def self.convertible_to_bool?(value : YAML::Any) : Bool
      if text = value.as_s?
        normalized = text.strip.downcase
        return RoleBoolKeywords::TRUE_WORDS.includes?(normalized) ||
          RoleBoolKeywords::FALSE_WORDS.includes?(normalized)
      end
      RoleBoolKeywords.convertible_to_bool?(value)
    end

    # Python's float() over a string: surrounding whitespace, an optional
    # sign, `inf`/`infinity`/`nan` spellings, or a decimal literal whose
    # digits may be separated by underscores. Crystal's own to_f? is more
    # permissive (hex floats, trailing underscores), so the shape is
    # checked here before the value is parsed. Repeated underscores
    # between digits are allowed on purpose: PyYAML tags `1__0` as an int
    # and strips them, so a value that only Crystal's resolver leaves a
    # string must not be refused here.
    private def self.python_float(text : String) : Float64?
      body = text.strip
      return nil if body.empty?
      sign = 1.0
      if body.starts_with?('+') || body.starts_with?('-')
        sign = -1.0 if body.starts_with?('-')
        body = body[1..]
      end
      case body.downcase
      when "inf", "infinity" then return sign * Float64::INFINITY
      when "nan"             then return Float64::NAN
      end
      return nil unless body.matches?(/\A(?:\d(?:_*\d)*(?:\.(?:\d(?:_*\d)*)?)?|\.\d(?:_*\d)*)(?:[eE][+-]?\d(?:_*\d)*)?\z/)
      sign * body.delete('_').to_f
    end

    private def self.templated?(value : YAML::Any) : Bool
      text = value.as_s?
      !text.nil? && (text.includes?("{{") || text.includes?("{%"))
    end
  end
end
