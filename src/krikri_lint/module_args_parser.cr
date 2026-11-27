module Krikri
  module Lint
    # ansible-core's ModuleArgsParser, as much of it as decides whether a
    # task statement loads at all.
    #
    # load_list_of_tasks parses every task statement with
    # `ModuleArgsParser.parse(skip_action_validation=True)`, which makes
    # every key that is not a Task/Handler attribute an action
    # candidate. A second candidate aborts the load with "conflicting
    # action statements: <first>, <second>", a lone candidate whose value
    # is not a string/mapping/null aborts with "unexpected parameter type
    # in action", and a statement whose every key is an attribute has no
    # action at all ("no module/action detected in task."). ansible-lint
    # reports the first such failure two ways: as a lintable's
    # syntax-check[specific] when a `--syntax-check` reached it, and as a
    # task list's parser-error when only the lint pipeline parsed it.
    #
    # A `block:` statement is handed to Block.load, never to
    # ModuleArgsParser, so its own keys are never a failure - its nested
    # task lists are statements of their own.
    module ModuleArgsParser
      # Task.fattributes plus Handler.fattributes plus the
      # pseudo-attributes ModuleArgsParser treats as its own
      # (`local_action`, `static`). A key outside this set - and outside
      # the `with_` loop family, which the parser filters too - is an
      # action candidate. ansible-lint parses with
      # skip_action_validation=True, so every such key counts as an
      # action, not just names that resolve to a module.
      ATTRIBUTES = Set{
        "action", "any_errors_fatal", "args", "async", "async_val",
        "become", "become_exe", "become_flags", "become_method",
        "become_user", "changed_when", "check_mode", "collections",
        "connection", "debugger", "delay", "delegate_facts",
        "delegate_to", "diff", "environment", "failed_when",
        "ignore_errors", "ignore_unreachable", "listen", "local_action",
        "loop", "loop_control", "loop_with", "module_defaults", "name",
        "no_log", "notify", "poll", "port", "register", "remote_user",
        "retries", "run_once", "static", "tags", "throttle", "timeout",
        "until", "vars", "when",
      }

      # The datatag class names ansible 2.19+ prints for a refused action
      # value; the PyYAML YAML 1.1 resolvers that decide which one applies
      # are NodeUtil's, shared with the rules that ask the same question.
      INT_CLASS    = "ansible.module_utils._internal._datatag._AnsibleTaggedInt"
      FLOAT_CLASS  = "ansible.module_utils._internal._datatag._AnsibleTaggedFloat"
      LIST_CLASS   = "ansible.module_utils._internal._datatag._AnsibleTaggedList"
      NULL_SCALARS = NodeUtil::PY_NULL_SCALARS
      BOOL_SCALARS = NodeUtil::PY_BOOL_SCALARS
      INT_SCALAR   = NodeUtil::PY_INT_SCALAR
      FLOAT_SCALAR = NodeUtil::PY_FLOAT_SCALAR

      # Ansible's error for one task statement, or nil when it parses.
      def self.failure(task : YAML::Nodes::Mapping) : String?
        return nil unless NodeUtil.entry(task, "block").nil?
        action, failure = directive_action(task)
        return failure if failure
        conflicting_action_failure(task, action)
      end

      # The module an `action:`/`local_action:` directive names (nil when
      # neither is written) and, when one of them refuses its value, that
      # error. Ansible normalizes the directives before it walks the other
      # keys, so the module one names leads the conflicting pair whichever
      # key order wrote it; both together are refused before that walk.
      private def self.directive_action(task : YAML::Nodes::Mapping) : {String?, String?}
        action = nil.as(String?)
        if entry = NodeUtil.entry(task, "action")
          if type_name = directive_value_class(entry[1])
            return {nil.as(String?), type_failure(type_name)}
          end
          action = action_directive_module(entry[1])
        end
        if entry = NodeUtil.entry(task, "local_action")
          return {nil.as(String?), "action and local_action are mutually exclusive"} if action
          if type_name = directive_value_class(entry[1])
            return {nil.as(String?), type_failure(type_name)}
          end
          action = action_directive_module(entry[1])
        end
        {action, nil.as(String?)}
      end

      # The error for the first of the task's remaining action candidates,
      # given the module a directive already names: a candidate beside one
      # is a conflict (its value is never type-checked), a lone candidate
      # whose value cannot be normalized is a type error, and no candidate
      # at all is a missing action.
      private def self.conflicting_action_failure(task : YAML::Nodes::Mapping,
                                                  action : String?) : String?
        first = nil.as(String?)
        NodeUtil.each_entry(task) do |key_node, value_node|
          key = NodeUtil.scalar_value(key_node) || next
          next if ATTRIBUTES.includes?(key)
          next if key.starts_with?("with_")
          if earlier = action || first
            return "conflicting action statements: #{earlier}, #{key}"
          end
          if type_name = action_value_class(value_node)
            return type_failure(type_name)
          end
          first = key
        end
        return nil if action || first
        "no module/action detected in task."
      end

      private def self.type_failure(type_name : String) : String
        "unexpected parameter type in action: <class '#{type_name}'>"
      end

      # The module an old-style `action:`/`local_action:` directive
      # names: the first token of its string form ("command echo one") or
      # the `module:` value of its mapping form. Nil when the directive
      # names no module that way.
      private def self.action_directive_module(value : YAML::Nodes::Node) : String?
        if (text = NodeUtil.scalar_value(value))
          token = text.strip.split(/\s+/).first?
          return token.nil? || token.empty? ? nil : token
        end
        if (mapping = value.as?(YAML::Nodes::Mapping)) &&
           (module_entry = NodeUtil.entry(mapping, "module"))
          return NodeUtil.scalar_value(module_entry[1])
        end
        nil
      end

      # The class name for an `action:`/`local_action:` directive's value.
      # A module key's null value is accepted (a module taking no params),
      # but _normalize_old_style_args takes only a string or a mapping and
      # raises for everything else, NoneType included.
      private def self.directive_value_class(node : YAML::Nodes::Node) : String?
        return "NoneType" if node.is_a?(YAML::Nodes::Scalar) && null_scalar?(node)
        action_value_class(node)
      end

      private def self.null_scalar?(node : YAML::Nodes::Scalar) : Bool
        return true if node.tag == "tag:yaml.org,2002:null"
        node.style.plain? && NULL_SCALARS.includes?(node.value)
      end

      # The Python class name ModuleArgsParser's "unexpected parameter
      # type in action" names for an action value it cannot normalize, or
      # nil for the shapes it accepts (a string, a mapping, or null).
      # Ansible's YAML loader resolves plain scalars with PyYAML's YAML
      # 1.1 rules, so an unquoted `yes`/`true` is a bool and `5` an int;
      # the non-bool containers and numbers print under the datatag
      # subclasses ansible 2.19+ tags them with.
      private def self.action_value_class(node : YAML::Nodes::Node) : String?
        case node
        when YAML::Nodes::Mapping
          nil
        when YAML::Nodes::Sequence
          LIST_CLASS
        when YAML::Nodes::Scalar
          scalar_action_class(node)
        end
      end

      private def self.scalar_action_class(node : YAML::Nodes::Scalar) : String?
        case node.tag
        when "tag:yaml.org,2002:str", "tag:yaml.org,2002:null", "!vault"
          return nil
        when "tag:yaml.org,2002:bool"
          return "bool"
        when "tag:yaml.org,2002:int"
          return INT_CLASS
        when "tag:yaml.org,2002:float"
          return FLOAT_CLASS
        end
        return nil unless node.style.plain?
        value = node.value
        return nil if NULL_SCALARS.includes?(value)
        return "bool" if BOOL_SCALARS.includes?(value)
        return INT_CLASS if value.matches?(INT_SCALAR)
        return FLOAT_CLASS if value.matches?(FLOAT_SCALAR)
        nil
      end
    end
  end
end
