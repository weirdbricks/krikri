require "json"

module Krikri
  module Lint
    # Minimal JSON Schema (Draft-07-style) validator covering the keyword
    # subset ansible-lint's vendored schemas use, with jsonschema-style
    # best-match error selection (deepest instance path wins).
    #
    # Instance data is JSON::Any; schema is JSON::Any.
    module JsonSchema
      struct Error
        getter path : Array(String) # JSON pointer segments
        getter instance : JSON::Any
        getter clause : JSON::Any # schema dict containing the failing keyword
        getter keyword : String
        getter message : String

        def initialize(@path, @instance, @clause, @keyword, @message)
        end

        def depth : Int32
          path.size
        end

        # "$.galaxy_info" style, matching upstream's message formatting.
        def formatted_path : String
          return "$" if path.empty?
          "$." + path.join(".")
        end

        def formatted_instance : String
          instance.to_s
        end

        def formatted_clause : String
          JsonSchema.python_repr(clause)
        end
      end

      # Upstream formats the failing clause with Python dict/list repr
      # (single quotes), not JSON.
      def self.python_repr(node : JSON::Any) : String
        case node.raw
        when Hash
          inner = node.as_h.map { |k, v| "#{python_str_repr(k)}: #{python_repr(v)}" }
          "{#{inner.join(", ")}}"
        when Array
          inner = node.as_a.map { |v| python_repr(v) }
          "[#{inner.join(", ")}]"
        when String
          python_str_repr(node.as_s)
        when Bool
          node.as_bool ? "True" : "False"
        when Nil
          "None"
        else
          node.to_s
        end
      end

      # Python's str repr: single quotes unless the value holds one and no
      # double quote, with backslashes and control characters escaped. A
      # schema pattern (schema[playbook] quotes one in a failure message)
      # can carry both, and a bare slice would print a real newline where
      # jsonschema prints \n.
      def self.python_str_repr(value : String) : String
        quote = value.includes?('\'') && !value.includes?('"') ? '"' : '\''
        String.build do |io|
          io << quote
          value.each_char do |char|
            case char
            when '\\' then io << "\\\\"
            when '\n' then io << "\\n"
            when '\r' then io << "\\r"
            when '\t' then io << "\\t"
            else
              if char == quote
                io << '\\' << char
              elsif char.ord < 0x20 || char.ord == 0x7f
                io << "\\x" << char.ord.to_s(16).rjust(2, '0')
              else
                io << char
              end
            end
          end
          io << quote
        end
      end

      SCHEMA_KEYWORDS = %w[$defs $ref type enum const pattern minLength
        properties required additionalProperties items
        allOf anyOf oneOf not if then else]

      struct ValidationResult
        getter? valid : Bool
        getter error : Error?

        def initialize(@valid, @error)
        end
      end

      def self.validate(instance : JSON::Any, schema : JSON::Any) : ValidationResult
        errors = [] of Error
        validate_node(instance, schema, [] of String, schema, errors)
        if errors.empty?
          ValidationResult.new(true, nil)
        else
          best = errors.max_by do |err|
            # jsonschema's best_match heuristic: deepest path wins
            err.depth
          end
          ValidationResult.new(false, best)
        end
      end

      private def self.deref(schema : JSON::Any, root : JSON::Any) : JSON::Any
        if schema.as_h?.try(&.has_key?("$ref"))
          ref = schema["$ref"].as_s
          unless ref.starts_with?("#/")
            return schema
          end
          target = root
          ref.split("/")[1..].each do |segment|
            target = target.as_h[segment.gsub("~1", "/").gsub("~0", "~")]?
            return schema unless target
          end
          return target
        end
        schema
      end

      private def self.validate_node(instance : JSON::Any, raw_schema : JSON::Any,
                                     path : Array(String), root : JSON::Any,
                                     errors : Array(Error)) : Nil
        schema = deref(raw_schema, root)
        obj = schema.as_h?
        if obj.nil?
          # boolean schema
          return if schema.raw == true
          errors << Error.new(path, instance, schema, "false", "should not be valid under false schema") if schema.raw == false
          return
        end

        # combinators first (they recurse with the same path)
        obj.each do |keyword, subschema|
          case keyword
          when "allOf"
            subschema.as_a.each do |sub|
              validate_node(instance, sub, path, root, errors)
            end
          when "anyOf"
            matched = subschema.as_a.any? do |sub|
              sub_errors = [] of Error
              validate_node(instance, sub, path, root, sub_errors)
              sub_errors.empty?
            end
            unless matched
              errors << Error.new(path, instance, schema, "anyOf", "is not valid under any of the given schemas")
              return
            end
          when "oneOf"
            matches = subschema.as_a.count do |sub|
              sub_errors = [] of Error
              validate_node(instance, sub, path, root, sub_errors)
              sub_errors.empty?
            end
            unless matches == 1
              errors << Error.new(path, instance, schema, "oneOf", "is not valid under any of the given schemas")
              return
            end
          when "not"
            sub_errors = [] of Error
            validate_node(instance, subschema, path, root, sub_errors)
            if sub_errors.empty?
              errors << Error.new(path, instance, subschema, "not", "is valid under schema")
              return
            end
          when "if"
            if_errors = [] of Error
            validate_node(instance, subschema, path, root, if_errors)
            if_ok = if_errors.empty?
            branch = obj[if_ok ? "then" : "else"]?
            if branch
              validate_node(instance, branch, path, root, errors)
            end
          end
        end

        # type checks
        if (type_value = obj["type"]?)
          expected = type_value.as_a? ? type_value.as_a.map(&.as_s) : [type_value.as_s]
          unless expected.any? { |type_name| type_matches?(instance, type_name) }
            errors << Error.new(path, instance, schema, "type", "is not of type")
            return
          end
        end

        case instance.raw
        when Hash
          props = obj["properties"]?.try(&.as_h)
          required = obj["required"]?.try(&.as_a.map(&.as_s))
          additional = obj["additionalProperties"]?

          # jsonschema skips required for non-object instances; each
          # missing key gets its own error with the std message.
          if required
            required.each do |key|
              unless instance.as_h.has_key?(key)
                errors << Error.new(path, instance, schema, "required",
                  "'#{key}' is a required property")
              end
            end
          end

          instance.as_h.each do |key, value|
            child_path = path + [key]
            prop_schema = props.try(&.[key]?)
            if prop_schema
              validate_node(value, prop_schema, child_path, root, errors)
            elsif additional
              if additional.raw == false
                errors << Error.new(child_path, value, schema,
                  "additionalProperties", "has additional properties")
              else
                validate_node(value, additional, child_path, root, errors)
              end
            end
          end
        when Array
          if (items = obj["items"]?)
            instance.as_a.each_with_index do |item, idx|
              validate_node(item, items, path + [idx.to_s], root, errors)
            end
          end
        when String
          # jsonschema yields errors in schema keyword order and best_match
          # keeps the first one at equal depth, so minLength (declared before
          # pattern in our meta schema) decides a value that fails both.
          if (min_length = obj["minLength"]?)
            if instance.as_s.size < min_length.as_i
              errors << Error.new(path, instance, schema, "minLength",
                "#{python_repr(instance)} is too short")
            end
          end
          if (pattern = obj["pattern"]?)
            value = instance.as_s
            unless Regex.new(pattern.as_s).matches?(value)
              errors << Error.new(path, instance, schema, "pattern",
                "#{python_repr(instance)} does not match #{python_repr(pattern)}")
            end
          end
        end

        if (enum_values = obj["enum"]?)
          unless enum_values.as_a.any? { |v| v.raw == instance.raw }
            errors << Error.new(path, instance, schema, "enum", "is not one of the enum values")
          end
        end
        if (const_value = obj["const"]?)
          unless const_value.raw == instance.raw
            errors << Error.new(path, instance, schema, "const", "does not match const")
          end
        end
      end

      private def self.type_matches?(instance : JSON::Any, type : String) : Bool
        case type
        when "object"  then instance.raw.is_a?(Hash)
        when "array"   then instance.raw.is_a?(Array)
        when "string"  then instance.raw.is_a?(String)
        when "boolean" then instance.raw.is_a?(Bool)
        when "null"    then instance.raw.nil?
        when "integer" then instance.raw.is_a?(Int)
        when "number"  then instance.raw.is_a?(Number)
        else                true
        end
      end

      # One segment of a jsonschema absolute_path: a property name or an
      # array index. json_path spells an index as [n] and a key as .name,
      # so the distinction has to survive past validation.
      alias Segment = Int32 | String

      # A JSON Schema failure laid out the way jsonschema reports it:
      # keyword and message as the failing keyword produced them, plus the
      # nested errors a combinator collected (upstream resolves a
      # combinator down to one of them, see best_match).
      struct UpstreamError
        getter path : Array(Segment)
        # Path segments this error added below its immediate parent; the
        # deep-match tiebreak uses the length of jsonschema's .path.
        getter relative_depth : Int32
        getter keyword : String
        getter message : String
        getter context : Array(UpstreamError)
        # The schema dict holding the failing keyword, which upstream reads
        # its documentation URL from.
        getter clause : JSON::Any

        def initialize(@path, @relative_depth, @keyword, @message, @context, @clause)
        end

        # jsonschema's json_path: "$" then ".key"/"[index]" per segment.
        def json_path : String
          String.build do |io|
            io << '$'
            @path.each do |segment|
              case segment
              in Int32  then io << '[' << segment << ']'
              in String then io << '.' << segment
              end
            end
          end
        end
      end

      # Keywords whose message jsonschema only produces when no branch of
      # them matched: upstream's deep-match heuristic prefers a real
      # keyword failure over one of these.
      COMBINATOR_KEYWORDS = %w[anyOf oneOf]

      # Upstream's first JSON Schema error for the instance - the order
      # jsonschema's iter_errors yields them in - resolved through its
      # _deep_match_relevance heuristic (schema.py's find_best_deep_match).
      def self.upstream_error(instance : JSON::Any, schema : JSON::Any) : UpstreamError?
        first = iter_errors(instance, schema, schema, [] of Segment, 0).first?
        return nil unless first
        best_match(first)
      end

      # The deepest leaf of the first error's context tree, first one wins
      # on a tie (Python's max over the flattened context).
      def self.best_match(error : UpstreamError) : UpstreamError
        candidates = [] of UpstreamError
        collect_context(error.context, candidates)
        candidates.max_by { |candidate| relevance(candidate) } || error
      end

      private def self.collect_context(errors : Array(UpstreamError),
                                       into : Array(UpstreamError)) : Nil
        errors.each do |error|
          into << error
          collect_context(error.context, into)
        end
      end

      private def self.relevance(error : UpstreamError) : {Int32, Int32, Int32}
        # Python's relevance tuple starts with a bool; an int keeps the
        # Crystal tuple comparable (Bool has no <=>).
        {COMBINATOR_KEYWORDS.includes?(error.keyword) ? 0 : 1,
         error.path.size,
         -error.relative_depth}
      end

      # jsonschema's iter_errors: keywords in the schema's own order, each
      # yielding its failures, with a $ref replacing its schema outright
      # (Draft-07 ignores $ref siblings).
      private def self.iter_errors(instance : JSON::Any, raw_schema : JSON::Any,
                                   root : JSON::Any, path : Array(Segment),
                                   relative_depth : Int32) : Array(UpstreamError)
        schema = deref(raw_schema, root)
        obj = schema.as_h?
        if obj.nil?
          return [] of UpstreamError unless schema.raw == false
          return [failure(path, relative_depth, "false",
            "False schema does not allow #{python_repr(instance)}", schema)]
        end

        errors = [] of UpstreamError
        obj.each do |keyword, clause|
          case keyword
          when "additionalProperties"
            errors.concat(additional_property_errors(instance, clause, schema, root,
              path, relative_depth))
          when "allOf"
            clause.as_a.each do |subschema|
              errors.concat(iter_errors(instance, subschema, root, path, relative_depth))
            end
          when "anyOf"
            errors.concat(any_of_errors(instance, clause, schema, root, path,
              relative_depth, "anyOf"))
          when "oneOf"
            errors.concat(any_of_errors(instance, clause, schema, root, path,
              relative_depth, "oneOf"))
          when "const"
            unless clause.raw == instance.raw
              errors << failure(path, relative_depth, keyword,
                "#{python_repr(clause)} was expected", schema)
            end
          when "enum"
            unless clause.as_a.any? { |value| value.raw == instance.raw }
              errors << failure(path, relative_depth, keyword,
                "#{python_repr(instance)} is not one of #{python_repr(clause)}",
                schema)
            end
          when "if"
            if_errors = iter_errors(instance, clause, root, path, relative_depth)
            branch = obj[if_errors.empty? ? "then" : "else"]?
            if branch
              errors.concat(iter_errors(instance, branch, root, path, relative_depth))
            end
          when "items"
            if items = instance.as_a?
              items.each_with_index do |item, index|
                errors.concat(iter_errors(item, clause, root, path + [index],
                  relative_depth + 1))
              end
            end
          when "minLength"
            value = instance.as_s?
            if value && value.size < clause.as_i
              errors << failure(path, relative_depth, keyword,
                "#{python_repr(instance)} is too short", schema)
            end
          when "not"
            if iter_errors(instance, clause, root, path, 0).empty?
              errors << failure(path, relative_depth, keyword,
                "#{python_repr(instance)} should not be valid under #{python_repr(clause)}",
                schema)
            end
          when "pattern"
            value = instance.as_s?
            if value && !Regex.new(clause.as_s).matches?(value)
              errors << failure(path, relative_depth, keyword,
                "#{python_repr(instance)} does not match #{python_repr(clause)}",
                schema)
            end
          when "patternProperties"
            errors.concat(pattern_property_errors(instance, clause, root, path,
              relative_depth))
          when "properties"
            errors.concat(property_errors(instance, clause, root, path, relative_depth))
          when "required"
            hash = instance.as_h?
            if hash
              clause.as_a.each do |key|
                name = key.as_s
                next if hash.has_key?(name)
                errors << failure(path, relative_depth, keyword,
                  "'#{name}' is a required property", schema)
              end
            end
          when "type"
            expected = clause.as_a? ? clause.as_a.map(&.as_s) : [clause.as_s]
            unless expected.any? { |type_name| type_matches?(instance, type_name) }
              reprs = expected.map { |type_name| "'#{type_name}'" }.join(", ")
              errors << failure(path, relative_depth, keyword,
                "#{python_repr(instance)} is not of type #{reprs}", schema)
            end
          end
        end
        errors
      end

      private def self.failure(path : Array(Segment), relative_depth : Int32,
                               keyword : String, message : String,
                               clause : JSON::Any,
                               context : Array(UpstreamError) = [] of UpstreamError) : UpstreamError
        UpstreamError.new(path, relative_depth, keyword, message, context, clause)
      end

      # anyOf starts no error at all once a branch matches; oneOf also
      # flags an instance that satisfies more than one branch ("is valid
      # under each of"), reporting the branches in jsonschema's order.
      private def self.any_of_errors(instance : JSON::Any, clause : JSON::Any,
                                     schema : JSON::Any, root : JSON::Any,
                                     path : Array(Segment), relative_depth : Int32,
                                     keyword : String) : Array(UpstreamError)
        branches = clause.as_a
        nested = [] of UpstreamError
        first_valid = nil
        branches.each_with_index do |subschema, index|
          branch_errors = iter_errors(instance, subschema, root, path, 0)
          if branch_errors.empty?
            first_valid = index
            break
          end
          nested.concat(branch_errors)
        end

        unless first_valid
          return [failure(path, relative_depth, keyword,
            "#{python_repr(instance)} is not valid under any of the given schemas",
            schema, nested)]
        end
        return [] of UpstreamError if keyword == "anyOf"

        more_valid = [] of JSON::Any
        branches.each_with_index do |subschema, index|
          next unless index > first_valid
          more_valid << subschema if iter_errors(instance, subschema, root, path, 0).empty?
        end
        return [] of UpstreamError if more_valid.empty?

        more_valid << branches[first_valid]
        reprs = more_valid.map { |subschema| python_repr(subschema) }.join(", ")
        [failure(path, relative_depth, keyword,
          "#{python_repr(instance)} is valid under each of #{reprs}",
          schema)]
      end

      private def self.property_errors(instance : JSON::Any, clause : JSON::Any,
                                       root : JSON::Any, path : Array(Segment),
                                       relative_depth : Int32) : Array(UpstreamError)
        hash = instance.as_h? || return [] of UpstreamError
        errors = [] of UpstreamError
        clause.as_h.each do |key, subschema|
          value = hash[key]?
          next unless value
          errors.concat(iter_errors(value, subschema, root, path + [key],
            relative_depth + 1))
        end
        errors
      end

      private def self.pattern_property_errors(instance : JSON::Any, clause : JSON::Any,
                                               root : JSON::Any, path : Array(Segment),
                                               relative_depth : Int32) : Array(UpstreamError)
        hash = instance.as_h? || return [] of UpstreamError
        errors = [] of UpstreamError
        clause.as_h.each do |pattern, subschema|
          regex = Regex.new(pattern)
          hash.each do |key, value|
            next unless regex.matches?(key)
            errors.concat(iter_errors(value, subschema, root, path + [key],
              relative_depth + 1))
          end
        end
        errors
      end

      # jsonschema's additionalProperties: keys no `properties` entry and no
      # `patternProperties` regex claims. With patternProperties present the
      # message names the regexes it tried, otherwise the "Additional
      # properties are not allowed" form.
      private def self.additional_property_errors(instance : JSON::Any, clause : JSON::Any,
                                                  schema : JSON::Any, root : JSON::Any,
                                                  path : Array(Segment),
                                                  relative_depth : Int32) : Array(UpstreamError)
        hash = instance.as_h? || return [] of UpstreamError
        props = schema.as_h["properties"]?.try(&.as_h)
        patterns = schema.as_h["patternProperties"]?.try(&.as_h)
        regexes = patterns.try(&.keys.map { |pattern| Regex.new(pattern) }) || [] of Regex
        extras = hash.keys.reject do |key|
          next true if props.try(&.has_key?(key))
          regexes.any?(&.matches?(key))
        end
        return [] of UpstreamError if extras.empty?

        if clause.as_h?
          errors = [] of UpstreamError
          extras.each do |key|
            errors.concat(iter_errors(hash[key], clause, root, path + [key],
              relative_depth + 1))
          end
          return errors
        end
        return [] of UpstreamError unless clause.raw == false

        [failure(path, relative_depth, "additionalProperties",
          additional_properties_message(extras, patterns), schema)]
      end

      private def self.additional_properties_message(extras : Array(String),
                                                     patterns : Hash(String, JSON::Any)?) : String
        quoted = extras.sort.map { |key| "'#{key}'" }
        if patterns
          verb = quoted.size == 1 ? "does" : "do"
          regexes = patterns.keys.sort!.map { |pattern| "'#{pattern}'" }.join(", ")
          "#{quoted.join(", ")} #{verb} not match any of the regexes: #{regexes}"
        else
          verb = quoted.size == 1 ? "was" : "were"
          "Additional properties are not allowed (#{quoted.join(", ")} #{verb} unexpected)"
        end
      end
    end
  end
end
