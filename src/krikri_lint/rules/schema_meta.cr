require "json"
require "yaml"

module Krikri
  module Lint
    # Upstream parity: ansible-lint's schema[meta] (severity VERY_HIGH,
    # tags core; profile basic). Validates a role's meta/main.yml against
    # the vendored JSON Schema (ansible-lint v25.2.1's meta.json) with a
    # minimal Draft-07 validator (see json_schema.cr). Fires only in role
    # context, like upstream; reported at file start with no column.
    class SchemaMetaRule < Rule
      SCHEMA_TEXT = {{ read_file("#{__DIR__}/../schemas/meta.json") }}
      SCHEMA      = JSON.parse(SCHEMA_TEXT)

      def id : String
        "schema[meta]"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["core"]
      end

      def applies_to : Array(FileType)
        [FileType::META]
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        return unless in_role?(file.path)
        root = file.root
        return if root.nil? || file.parse_error
        return unless root.is_a?(YAML::Nodes::Mapping)
        instance = yaml_node_to_json(root)
        result = JsonSchema.validate(instance, SCHEMA)
        return if result.valid?
        err = result.error || raise "expected error"
        message = if err.keyword == "required"
                    "#{err.formatted_path} #{err.message}"
                  else
                    "#{err.formatted_path} #{err.formatted_instance} should not be valid under #{err.formatted_clause}"
                  end
        violations << Violation.new(file.path, 1, 0, id, severity,
          "#{message}. See https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html#using-role-dependencies")
      end

      # Upstream only schema-validates meta when the file belongs to a
      # role: either the roles/ path pattern or a sibling tasks/ dir.
      private def in_role?(path : String) : Bool
        parts = path.split('/')
        roles_idx = parts.index("roles")
        if roles_idx && parts.size > roles_idx + 2 &&
           parts[roles_idx + 2] == "meta"
          return true
        end
        # a <dir>/meta/main.yml file marks the dir as a role, even
        # without tasks/ yet (matches upstream's classification)
        parts.size >= 2 && parts[-2] == "meta"
      end

      private def yaml_node_to_json(node : YAML::Nodes::Node) : JSON::Any
        case node
        when YAML::Nodes::Mapping
          obj = {} of String => JSON::Any
          NodeUtil.each_entry(node) do |k, v|
            key = k.as?(YAML::Nodes::Scalar).try(&.value)
            next unless key
            obj[key] = yaml_node_to_json(v)
          end
          JSON::Any.new(obj)
        when YAML::Nodes::Sequence
          JSON::Any.new(node.nodes.map { |child| yaml_node_to_json(child) })
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
