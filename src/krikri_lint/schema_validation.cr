require "json"
require "yaml"

module Krikri
  module Lint
    # The parts every schema[...] rule shares: upstream's description text
    # (ValidateSchemaRule.DESCRIPTION_MD, identical for every schema tag),
    # its message format, and the YAML-to-JSON conversion jsonschema
    # validation needs. Kept in one place so schema[meta] and
    # schema[galaxy] cannot drift apart on wording.
    module SchemaValidation
      # Printed as the match's details: schema errors carry no line
      # numbers, and the rule is not skippable.
      DETAILS = " Errors from schema validation do not include exact line numbers.\n" \
                "The schema name appears as a tag, like ``schema[meta]``.\n\n" \
                "This rule cannot be skipped and stops further processing of the file.\n\n" \
                "If the wrong schema was picked, either:\n\n" \
                "* move the file to its standard location so it is detected correctly.\n" \
                "* use ``kinds:`` in the linter config to set the file type.\n"

      extend self

      # Upstream reports `f"{error.json_path} {error.message}"`; a keyword
      # that has no dedicated match here falls back to jsonschema's
      # "should not be valid under" wording.
      def message(error : JsonSchema::Error) : String
        case error.keyword
        when "required", "pattern", "minLength"
          "#{error.formatted_path} #{error.message}"
        else
          "#{error.formatted_path} #{error.formatted_instance} should not be valid under #{error.formatted_clause}"
        end
      end

      # The YAML tree as the JSON value jsonschema would see: pyyaml's
      # safe loader resolves plain scalars by their YAML 1.1 types, which
      # matters for booleans and for a version: 1.0 scalar that must
      # reach a string-typed schema as a number.
      def instance(node : YAML::Nodes::Node) : JSON::Any
        case node
        when YAML::Nodes::Mapping
          obj = {} of String => JSON::Any
          NodeUtil.each_entry(node) do |k, v|
            key = k.as?(YAML::Nodes::Scalar).try(&.value)
            next unless key
            obj[key] = instance(v)
          end
          JSON::Any.new(obj)
        when YAML::Nodes::Sequence
          JSON::Any.new(node.nodes.map { |child| instance(child) })
        when YAML::Nodes::Scalar
          scalar_to_json(node)
        else
          JSON::Any.new(nil)
        end
      end

      private def scalar_to_json(node : YAML::Nodes::Scalar) : JSON::Any
        value = node.value || ""
        case node.style
        when YAML::ScalarStyle::PLAIN
          case value
          when "true", "True", "yes", "on"   then return JSON::Any.new(true)
          when "false", "False", "no", "off" then return JSON::Any.new(false)
          when "null", "Null", "~", ""       then return JSON::Any.new(nil)
          else
            if value.matches?(/^-?\d+$/)
              return JSON::Any.new(value.to_i64)
            elsif value.matches?(/^-?\d*\.\d+$/)
              return JSON::Any.new(value.to_f64)
            end
          end
        end
        JSON::Any.new(value)
      end
    end
  end
end
