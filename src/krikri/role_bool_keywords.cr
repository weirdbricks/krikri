require "json"
require "yaml"

module Krikri
  # include_role:/import_role:'s own boolean keywords (`public:`,
  # `allow_duplicates:`, `rolespec_validate:`) are converted to a Python
  # bool by real ansible-core 2.19.11 BEFORE the role itself is
  # resolved, and a value that is not a bool at all fails the task with a
  # three-link cause chain:
  #
  #     [ERROR]: Task failed: Error processing keyword 'public':
  #     The value 'snhvdg' could not be converted to 'bool'.
  #
  #     Task failed.
  #     Origin: pb.yml:4:5
  #     ...
  #     <<< caused by >>>
  #     Error processing keyword 'public'.
  #     Origin: pb.yml:5:81
  #     ...
  #     <<< caused by >>>
  #     The value 'snhvdg' could not be converted to 'bool'.
  #     Origin: pb.yml:5:81
  #
  # The same conversion failure on a STATIC import_role: aborts the whole
  # run at playbook-load time instead (rc=4, no play banner, and the
  # chain without its "Task failed." link) - same split real has between
  # IncludeRole.load and the dynamic task body. What is convertible is
  # ansible's own BOOLEANS set (case-insensitive y/yes/on/1/true/t and
  # n/no/off/0/false/f), plus 0/1 and 0.0/1.0 as numbers, plus None;
  # every other number, list and mapping is refused (live-verified vs
  # 2.19.11: `public: 2` fails, `public: 1` does not).
  #
  # Lives in its own file because both the parser (which needs it at
  # parse time, for import_role:) and the task executor (which needs it
  # at run time, for include_role:) use it, and neither can require the
  # other's file without a cycle.
  module RoleBoolKeywords
    # Real's own conversion order - public is converted before
    # allow_duplicates, which is converted before rolespec_validate
    # (live-verified vs 2.19.11: a task with all three unconvertible
    # reports `public`).
    KEYWORDS = %w[public allow_duplicates rolespec_validate]

    TRUE_WORDS  = %w[y yes on 1 true t]
    FALSE_WORDS = %w[n no off 0 false f]

    # One unconvertible keyword, as real's error block needs it: the
    # keyword's own name, the value in Python repr() form (the innermost
    # chain link quotes a string value, prints an int bare - real's
    # message interpolates the value with repr(), live-verified), and
    # the value's source position when the parser could resolve one.
    struct Failure
      getter keyword : String
      getter value_repr : String
      property origin : Tuple(Int32, Int32)?

      def initialize(@keyword : String, @value_repr : String, @origin : Tuple(Int32, Int32)? = nil)
      end

      # Real's innermost cause link: "The value <repr> could not be
      # converted to 'bool'."
      def conversion_message : String
        "The value #{@value_repr} could not be converted to 'bool'."
      end

      # Real's middle cause link: "Error processing keyword '<kw>'."
      def keyword_message : String
        "Error processing keyword '#{@keyword}'."
      end

      # Real's collapsed brief - the whole chain joined with ": ", which
      # is what the "[ERROR]:" line shows and what a fatal dump carries.
      def brief : String
        "#{keyword_message.chomp('.')}: #{conversion_message}"
      end
    end

    # The first keyword (in real's conversion order) whose value is not
    # convertible to a bool, or nil when they are all fine (or are
    # templated values, which real resolves before this conversion runs -
    # see the file comment).
    def self.failure(role_args : Hash(YAML::Any, YAML::Any)) : Failure?
      KEYWORDS.each do |keyword|
        value = role_args[keyword]?
        next unless value
        next if templated?(value)
        return nil if convertible_to_bool?(value)
        return Failure.new(keyword, python_repr(value))
      end
      nil
    end

    # A value real would resolve before converting it; its conversion
    # (and any failure message) is the executor's own finalization path,
    # not this one.
    private def self.templated?(value : YAML::Any) : Bool
      value.as_s?.try { |text| text.includes?("{{") } || false
    end

    private def self.convertible_to_bool?(value : YAML::Any) : Bool
      case raw = value.raw
      when Nil      then true
      when Bool     then true
      when Int64    then raw == 0 || raw == 1
      when Float64  then raw == 0.0 || raw == 1.0
      when String   then TRUE_WORDS.includes?(raw.downcase) || FALSE_WORDS.includes?(raw.downcase)
      else               false
      end
    end

    # Python repr() of a YAML value, as real's error message renders it:
    # a string is quoted (with its quotes escaped), a container is
    # rendered with Python's spacing, scalars bare.
    def self.python_repr(value : YAML::Any) : String
      case raw = value.raw
      when Nil          then "None"
      when Bool         then raw ? "True" : "False"
      when Int64, Float64 then raw.to_s
      when String       then "'" + raw.gsub("\\", "\\\\\\\\").gsub("'", "\\\\'") + "'"
      when Array(YAML::Any)
        "[" + raw.map { |item| python_repr(item) }.join(", ") + "]"
      when Hash(YAML::Any, YAML::Any)
        "{" + raw.map { |key, item| "'#{key}': #{python_repr(item)}" }.join(", ") + "}"
      else                   raw.to_s
      end
    end
  end
end