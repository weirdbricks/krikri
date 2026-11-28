module Krikri
  module Lint
    # Upstream parity: ansible-lint's opt-in no-same-owner rule
    # (severity LOW, tags opt-in). Flags a file transfer that keeps the
    # source's owner/group, which may not exist on the other machine.
    class NoSameOwnerRule < Rule
      # Upstream's RE_ARCHIVES: `^.*\.tar(\.(gz|bz2|xz))?$`, applied with
      # re.match (so it anchors at the start too). Python's `$` also
      # matches before one final newline, which a block scalar src keeps,
      # so `\z` alone would miss a src real ansible-lint reports.
      ARCHIVE_PATTERN = /\A.*\.tar(\.(gz|bz2|xz))?\n?\z/

      # PyYAML's YAML 1.1 spellings that resolve to the bool True.
      TRUE_WORDS = {"yes", "Yes", "YES", "true", "True", "TRUE", "on", "On", "ON"}

      def id : String
        "no-same-owner"
      end

      def severity : Severity
        Severity::LOW
      end

      def tags : Array(String)
        ["opt-in"]
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
        TaskWalker.each_task(file) do |task|
          next unless flagged?(task)
          violations << Violation.new(
            file.path, task.line, 0, id, severity,
            "Do not preserve the owner and group when transferring files across hosts.",
            task.line
          )
        end
      end

      private def flagged?(task : LintTask) : Bool
        # Upstream strips only the ansible.builtin. prefix before
        # matching (normalize_task_v2), so ansible.legacy.unarchive is
        # not one of its module spellings either.
        case task.module_name.lchop("ansible.builtin.")
        when "synchronize", "ansible.posix.synchronize"
          synchronize?(task)
        when "unarchive"
          unarchive?(task)
        else
          false
        end
      end

      # Upstream compares the task's delegate_to against ansible's
      # Sentinel, which only an absent key yields: any explicit value,
      # null included, turns the rule off.
      private def synchronize?(task : LintTask) : Bool
        return false if task.has_task_key?("delegate_to")
        # archive defaults to true and sets the default for owner/group
        # (upstream's `action.get("owner", archive)`).
        archive = truthy_param?(task, "archive", true)
        truthy_param?(task, "owner", archive) ||
          truthy_param?(task, "group", archive)
      end

      private def unarchive?(task : LintTask) : Bool
        # A task delegated to localhost unpacks a local src; anywhere
        # else the src is only local when remote_src is off.
        delegate = task.task_value("delegate_to")
        return false unless delegate == "localhost" ||
                            !truthy_param?(task, "remote_src", false)
        src = string_param?(task, "src") || return false
        extra_opts = param_node(task, "extra_opts")

        if src.ends_with?("zip") && contains?(extra_opts, "-X")
          return true
        end
        src.matches?(ARCHIVE_PATTERN) && !contains?(extra_opts, "--no-same-owner")
      end

      # The effective module parameter node: the action mapping's entry
      # wins over the task's `args:` mapping, as Ansible merges them.
      private def param_node(task : LintTask, key : String) : YAML::Nodes::Node?
        [task.action_node, task.args_node].each do |source|
          mapping = source.as?(YAML::Nodes::Mapping) || next
          if entry = NodeUtil.entry(mapping, key)
            return entry[1]
          end
        end
        nil
      end

      private def truthy_param?(task : LintTask, key : String, default : Bool) : Bool
        node = param_node(task, key) || return default
        python_truthy?(node)
      end

      # A parameter only counts when PyYAML resolves it to a string: an
      # unquoted `src: 123` is an int upstream, which the rule rejects.
      private def string_param?(task : LintTask, key : String) : String?
        node = param_node(task, key) || return nil
        scalar = node.as?(YAML::Nodes::Scalar) || return nil
        arg = Arg.new(scalar)
        arg.kind == :str ? arg.text : nil
      end

      # Python's `item in value`: a sequence's members, a mapping's keys
      # (real ansible-lint silences a mapping extra_opts whose key names
      # the option), or a substring of a string (ansible modules accept
      # extra_opts both ways).
      private def contains?(node : YAML::Nodes::Node?, item : String) : Bool
        return false unless node
        case node
        when YAML::Nodes::Sequence
          node.nodes.any? { |member| member.as?(YAML::Nodes::Scalar).try(&.value) == item }
        when YAML::Nodes::Mapping
          found = false
          NodeUtil.each_entry(node) do |key, _value|
            found = true if key.as?(YAML::Nodes::Scalar).try(&.value) == item
          end
          found
        when YAML::Nodes::Scalar
          (node.value || "").includes?(item)
        else
          false
        end
      end

      # Python truthiness of the value PyYAML resolves the node to, as
      # upstream's `or`/`not` see it: only Python's own falsy values are
      # falsy, so a quoted "false" is a non-empty string and stays true.
      private def python_truthy?(node : YAML::Nodes::Node) : Bool
        case node
        when YAML::Nodes::Sequence
          !node.nodes.empty?
        when YAML::Nodes::Mapping
          !node.nodes.empty?
        when YAML::Nodes::Scalar
          arg = Arg.new(node)
          case arg.kind
          when :none        then false
          when :bool        then TRUE_WORDS.includes?(arg.text)
          when :int, :float then !(arg.number == 0)
          else                   arg.text != ""
          end
        else
          true
        end
      end
    end
  end
end
