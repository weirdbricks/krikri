require "crinja"

module Krikri
  module Lint
    # Upstream parity: ansible-lint's jinja rule family (severity LOW,
    # tags formatting). We implement two sub-rules:
    #  - jinja[invalid]: Jinja templates that fail to parse (via Crinja)
    #  - jinja[spacing]: missing inner padding, `{{ x }}` not `{{x}}`
    # Upstream additionally reformats expressions with black; that full
    # reformat is a known gap (see krikri-lint.md).
    class JinjaRule < Rule
      def id : String
        "jinja"
      end

      def severity : Severity
        Severity::LOW
      end

      def tags : Array(String)
        ["formatting"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          found = [] of {String, Int32, Int32}
          collect_templates(task.node, found)
          found.each do |(value, line, column)|
            unless valid_jinja?(value)
              violations << Violation.new(file.path, line, column,
                "jinja[invalid]", severity,
                "Syntax error in jinja2 template: #{value}", task.line)
              next
            end
            if (reformatted = spacing_fix(value)) && reformatted != value
              violations << Violation.new(file.path, line, column,
                "jinja[spacing]", severity,
                "Jinja2 spacing could be improved: #{value} -> #{reformatted}",
                task.line)
            end
          end
        end
      end

      # Walks every string value in the task (skipping the name key and
      # block/rescue/always sublists, like upstream's nested_items_path).
      private def collect_templates(node : YAML::Nodes::Node, found : Array({String, Int32, Int32})) : Nil
        case node
        when YAML::Nodes::Mapping
          NodeUtil.each_entry(node) do |k, v|
            key = k.as?(YAML::Nodes::Scalar).try(&.value)
            next if key == "name" || key == "block" || key == "rescue" ||
                    key == "always"
            collect_templates(v, found)
          end
        when YAML::Nodes::Sequence
          node.nodes.each do |child|
            collect_templates(child, found)
          end
        when YAML::Nodes::Scalar
          if (value = node.value) && value.includes?("{{")
            found << {value, NodeUtil.line(node), NodeUtil.column(node)}
          end
        end
      end

      private def valid_jinja?(value : String) : Bool
        Crinja.render(value, Crinja::Variables.new)
        true
      rescue Crinja::TemplateSyntaxError
        # Parse failures are jinja[invalid]; runtime-resolvable render
        # failures (undefined vars, unknown filters) are not.
        false
      rescue
        true
      end

      # Narrow spacing normalization: `{{x}}` -> `{{ x }}`. Only fires
      # when both braces lack padding on their inner side; upstream's
      # black-based reformat covers more cases.
      private def spacing_fix(value : String) : String?
        return nil unless value.includes?("{{")
        fixed = value.gsub(/\{\{\s*/, "{{ ").gsub(/\s*\}\}/, " }}")
        fixed == value ? nil : fixed
      end
    end
  end
end
