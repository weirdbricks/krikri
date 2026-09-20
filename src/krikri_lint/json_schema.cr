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
          python_repr(clause)
        end

        # Upstream formats the failing clause with Python dict/list repr
        # (single quotes), not JSON.
        private def python_repr(node : JSON::Any) : String
          case node.raw
          when Hash
            inner = node.as_h.map { |k, v| "'#{k}': #{python_repr(v)}" }
            "{#{inner.join(", ")}}"
          when Array
            inner = node.as_a.map { |v| python_repr(v) }
            "[#{inner.join(", ")}]"
          when String
            "'#{node.as_s}'"
          when Bool
            node.as_bool ? "True" : "False"
          when Nil
            "None"
          else
            node.to_s
          end
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
          if (pattern = obj["pattern"]?)
            value = instance.as_s
            unless Regex.new(pattern.as_s).matches?(value)
              errors << Error.new(path, instance, schema, "pattern", "does not match pattern")
            end
          end
          if (min_length = obj["minLength"]?)
            if instance.as_s.size < min_length.as_i
              errors << Error.new(path, instance, schema, "minLength", "is too short")
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
    end
  end
end
