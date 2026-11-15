module Krikri
  module Lint
    # Upstream parity: no-tabs (severity LOW, tags formatting). Ansible's
    # matchtask walks every key and string value of the normalized task -
    # the whole nested structure, module arguments included - and flags
    # each one whose decoded text holds a tab, at that scalar's own
    # position (a block scalar is reported where it starts, not on each
    # line containing a tab). Keys are never exempted; only the
    # lineinfile options that legitimately carry tabs are, and only when
    # the value sits directly under that option, since a list element's
    # key is its index upstream.
    class NoTabsRule < Rule
      MESSAGE = "Most files should not contain tabs."

      # Upstream's allow_list, verbatim: lineinfile parameters whose
      # value is expected to contain tabs.
      ALLOW_LIST = [
        {"lineinfile", "insertafter"},
        {"lineinfile", "insertbefore"},
        {"lineinfile", "regexp"},
        {"lineinfile", "line"},
        {"win_lineinfile", "insertafter"},
        {"win_lineinfile", "insertbefore"},
        {"win_lineinfile", "regexp"},
        {"win_lineinfile", "line"},
        {"ansible.builtin.lineinfile", "insertafter"},
        {"ansible.builtin.lineinfile", "insertbefore"},
        {"ansible.builtin.lineinfile", "regexp"},
        {"ansible.builtin.lineinfile", "line"},
        {"ansible.legacy.lineinfile", "insertafter"},
        {"ansible.legacy.lineinfile", "insertbefore"},
        {"ansible.legacy.lineinfile", "regexp"},
        {"ansible.legacy.lineinfile", "line"},
        {"community.windows.win_lineinfile", "insertafter"},
        {"community.windows.win_lineinfile", "insertbefore"},
        {"community.windows.win_lineinfile", "regexp"},
        {"community.windows.win_lineinfile", "line"},
      ]

      # ansiblelint.text.RE_HAS_JINJA: any {{...}}, {%...%} or {#...#}
      # span. Upstream skips a tab-bearing key or value that contains
      # one, since the tab may be produced by templating.
      JINJA_PATTERN = /\{[{%#].*[%#}]/m

      def id : String
        "no-tabs"
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

      # Task-oriented: violations belong to an enclosing task, so a
      # `# noqa:` anywhere in that task's body suppresses them.
      def task_scoped? : Bool
        true
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task_mapping(file) do |node|
          module_name = TaskWalker.from_mapping(node, file).try(&.module_name)
          scan(node, file, module_name, NodeUtil.line(node), violations)
        end
      end

      # Walks one task statement's nodes. Mapping entries carry the key
      # upstream's allow_list is matched against; sequence members have
      # only an index there, which never matches.
      private def scan(root : YAML::Nodes::Node, file : PositionedFile,
                       module_name : String?, task_line : Int32,
                       violations : Array(Violation)) : Nil
        stack = [] of YAML::Nodes::Node
        stack << root
        while current = stack.pop?
          case current
          when YAML::Nodes::Mapping
            scan_mapping(current, stack, file, module_name, task_line, violations)
          when YAML::Nodes::Sequence
            scan_sequence(current, stack, file, task_line, violations)
          end
        end
      end

      private def scan_mapping(mapping : YAML::Nodes::Mapping,
                               stack : Array(YAML::Nodes::Node), file : PositionedFile,
                               module_name : String?, task_line : Int32,
                               violations : Array(Violation)) : Nil
        NodeUtil.each_entry(mapping) do |key_node, value_node|
          key = NodeUtil.scalar_value(key_node)
          flag(file, key_node, task_line, violations) if key && tabbed?(key)
          if value_node.is_a?(YAML::Nodes::Scalar)
            scan_value(value_node, key, file, module_name, task_line, violations)
          else
            stack << value_node
          end
        end
      end

      private def scan_value(node : YAML::Nodes::Scalar, key : String?,
                             file : PositionedFile, module_name : String?,
                             task_line : Int32, violations : Array(Violation)) : Nil
        value = NodeUtil.scalar_value(node)
        return unless value && tabbed?(value)
        return if allow_listed?(module_name, key)
        flag(file, node, task_line, violations)
      end

      private def scan_sequence(sequence : YAML::Nodes::Sequence,
                                stack : Array(YAML::Nodes::Node), file : PositionedFile,
                                task_line : Int32, violations : Array(Violation)) : Nil
        sequence.nodes.each do |item|
          if item.is_a?(YAML::Nodes::Scalar)
            scan_value(item, nil, file, nil, task_line, violations)
          else
            stack << item
          end
        end
      end

      private def tabbed?(text : String) : Bool
        text.includes?('\t') && !(text =~ JINJA_PATTERN)
      end

      private def allow_listed?(module_name : String?, key : String?) : Bool
        return false unless module_name && key
        ALLOW_LIST.includes?({module_name, key})
      end

      private def flag(file : PositionedFile, node : YAML::Nodes::Node,
                       task_line : Int32, violations : Array(Violation)) : Nil
        violations << Violation.new(file.path, NodeUtil.line(node),
          NodeUtil.column(node), id, severity, MESSAGE, task_line)
      end
    end
  end
end
