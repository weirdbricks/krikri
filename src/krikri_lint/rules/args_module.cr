module Krikri
  module Lint
    # Upstream parity: ansible-lint's args[module] rule (reported as a
    # warning by upstream). Validates task params against the module's
    # argument spec; core modules only (see arg_specs.cr). Reported at
    # the task line with no column.
    class ArgsModuleRule < Rule
      VALID_BOOLEANS = %w[0 1 true false yes no on off y n t f]

      def id : String
        "args[module]"
      end

      def severity : Severity
        Severity::VERY_LOW
      end

      def tags : Array(String)
        ["core"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          spec = ArgSpecs.find(task.module_name) || next
          # A missing/empty action block still validates against required
          # params (upstream runs AnsibleModule init with no args); a
          # scalar action (raw command string) for a spec'd module is
          # treated as no parameters.
          action = task.action_node.as?(YAML::Nodes::Mapping)
          given = {} of String => YAML::Nodes::Node
          unknown = [] of String
          if action
            NodeUtil.each_entry(action) do |k, v|
              key = k.as?(YAML::Nodes::Scalar).try(&.value) || next
              given[key] = v
            end
          end
          # resolve aliases to canonical names
          canonical = {} of String => YAML::Nodes::Node
          given.each do |key, value|
            canon = key
            spec.aliases.each do |canonical_name, alias_list|
              if alias_list.includes?(key)
                canon = canonical_name
              end
            end
            if spec.params.includes?(canon)
              canonical[canon] = value
            else
              unknown << key
            end
          end

          unless unknown.empty?
            aliases = spec.aliases.values.flatten.uniq!.reject { |alias_name| spec.params.includes?(alias_name) }
            tail = aliases.empty? ? "." : " (#{aliases.join(", ")})."
            violations << msg(file, task, "Unsupported parameters for (basic.py) module: #{unknown.join(", ")}. Supported parameters include: #{spec.params.join(", ")}#{tail}")
            next
          end

          spec.required_together.each do |group|
            next if group.all? { |required_name| canonical.has_key?(required_name) } ||
                    group.none? { |required_name| canonical.has_key?(required_name) }
            violations << msg(file, task, "parameters are required together: #{group.join(", ")}")
          end

          missing = spec.required.reject { |required_name| canonical.has_key?(required_name) }
          spec.required_one_of.each do |group|
            next if group.any? { |required_name| canonical.has_key?(required_name) }
            missing << "one-of:#{group.join(", ")}"
          end
          missing.each do |entry|
            violations << msg(file, task, entry.starts_with?("one-of:") ? "one of the following is required: #{entry[7..]}" : "missing required arguments: #{entry}")
          end

          spec.required_if.each do |cond|
            text = if (entry = canonical[cond.param]?)
                     NodeUtil.scalar_value(entry)
                   else
                     spec.defaults[cond.param]?
                   end
            next unless text == cond.value
            still_missing = cond.needed.reject { |needed_name| canonical.has_key?(needed_name) }
            next if still_missing.empty? || (cond.any && cond.needed.any? { |needed_name| canonical.has_key?(needed_name) })
            violations << msg(file, task, "#{cond.param} is #{cond.value} but #{cond.any ? "any" : "all"} of the following are missing: #{still_missing.join(", ")}")
          end

          spec.required_by.each do |param, needs|
            next unless canonical.has_key?(param)
            needs.each do |need|
              unless canonical.has_key?(need)
                violations << msg(file, task, "missing parameter(s) required by '#{param}': #{need}")
              end
            end
          end

          spec.choices.each do |param, values|
            value = canonical[param]?
            next unless value
            text = NodeUtil.scalar_value(value)
            next unless text
            next if text.includes?("{{")
            unless values.includes?(text) || boolean_choice?(value, text, values)
              violations << msg(file, task, "value of #{param} must be one of: #{values.join(", ")}, got: #{text}")
            end
          end

          spec.list_choices.each do |param, values|
            value = canonical[param]?
            next unless value
            items = value.as?(YAML::Nodes::Sequence) ? value.as(YAML::Nodes::Sequence).nodes.compact_map { |entry_node| NodeUtil.scalar_value(entry_node) } : [NodeUtil.scalar_value(value)].compact
            items = items.reject { |i| i.includes?("{{") }
            bad = items.reject { |i| values.includes?(i) }
            next if bad.empty?
            violations << msg(file, task, "value of #{param} must be one or more of: #{values.join(", ")}. Got no match for: #{bad.join(", ")}")
          end

          spec.booleans.each do |param|
            value = canonical[param]?
            next unless value
            text = NodeUtil.scalar_value(value)
            next unless text
            next if text.includes?("{{")
            unless VALID_BOOLEANS.includes?(text.downcase)
              violations << msg(file, task, "argument '#{param}' is of type str and we were unable to convert to bool: The value '#{text}' is not a valid boolean. Valid booleans include: 0, 1, 'no', 'on', 'yes', '1', 'false', 'n', '0', 'y', 'f', 't', 'off', 'true'")
            end
          end
        end
      end

      private def msg(file : PositionedFile, task : LintTask, text : String) : Violation
        Violation.new(file.path, task.line, 0, id, severity, text, task.line)
      end

      # A plain YAML boolean (true/false/yes/no/...) becomes Python
      # True/False, which for a str-typed choices parameter converts to
      # the string 'True'/'False' and is then remapped back into the
      # choices when they contain exactly one boolean-word member
      # (ansible-core parameters.py). So `upgrade: true` passes apt's
      # choices via the 'yes' member.
      private def boolean_choice?(node : YAML::Nodes::Node, text : String, values : Array(String)) : Bool
        scalar = node.as?(YAML::Nodes::Scalar) || return false
        return false unless scalar.style == YAML::ScalarStyle::PLAIN
        word = text.downcase
        bool_words = %w[true false yes no on off]
        return false unless bool_words.includes?(word)
        boolset = (word == "true" || word == "yes" || word == "on") ? %w[y yes on 1 true t] : %w[n no off 0 false f]
        overlap = values.select { |choice| boolset.includes?(choice) }
        overlap.size == 1
      end
    end
  end
end
