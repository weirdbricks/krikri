require "yaml"
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
  # Only `gather_facts:` and `force_handlers:` reach this: every other
  # bool play keyword (`become:`, `any_errors_fatal:`, `check_mode:`) is
  # an inherited FieldAttribute, and Play.post_validate skips those
  # unless `always_post_validate` is set. Their conversion failure belongs
  # to the TASK post-validation each inheriting task (handlers included)
  # performs when it runs - `Task` sets `_post_validate_object`, unlike
  # `Play` - which is why `any_errors_fatal: kpg-maybe` fails every task
  # it reaches instead of the play (issue #1465; see Task#
  # any_errors_fatal_invalid).
  # The conversion is ansible's `boolean(strict=True)` over the raw
  # value, and the reported value is its Python repr().
  module PlayBoolKeywords
    # Ansible's own fattributes order - a play with both unconvertible
    # reports gather_facts (live-verified vs 2.21.6).
    KEYWORDS = %w[gather_facts force_handlers]

    struct Failure
      getter keyword : String
      getter value_repr : String
      getter origin : Tuple(Int32, Int32)?

      def initialize(@keyword : String, @value_repr : String, @origin : Tuple(Int32, Int32)? = nil)
      end

      # Ansible's innermost cause link.
      def conversion_message : String
        "The value #{@value_repr} could not be converted to 'bool'."
      end

      # Ansible's outer cause link.
      def keyword_message : String
        "Error processing keyword '#{@keyword}'."
      end
    end

    # The first keyword (in Ansible's order) whose literal value is not
    # convertible to a bool, with the value's source position when the
    # parser could resolve one.
    def self.failure(play_yaml : Hash(YAML::Any, YAML::Any), source_map : YamlSourceMap?, prefix : String) : Failure?
      KEYWORDS.each do |keyword|
        value = play_yaml[keyword]?
        next unless value
        # A templated value is resolved against the play's vars before the
        # conversion runs, at execution time; its failure (and message)
        # belongs to that path, not this one.
        next if templated?(value)
        next if convertible?(value)
        origin = source_map.try(&.at?("#{prefix}/#{keyword}"))
        return Failure.new(keyword, RoleBoolKeywords.python_repr(value), origin)
      end
      nil
    end

    # ansible's boolean() lowercases AND strips a string before matching
    # its tables, so `gather_facts: " true "` is accepted - but the error
    # message still quotes the value as written.
    private def self.convertible?(value : YAML::Any) : Bool
      if text = value.as_s?
        normalized = text.strip.downcase
        return RoleBoolKeywords::TRUE_WORDS.includes?(normalized) ||
          RoleBoolKeywords::FALSE_WORDS.includes?(normalized)
      end
      RoleBoolKeywords.convertible_to_bool?(value)
    end

    private def self.templated?(value : YAML::Any) : Bool
      text = value.as_s?
      !text.nil? && (text.includes?("{{") || text.includes?("{%"))
    end
  end
end
