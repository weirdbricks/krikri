module Krikri
  module Lint
    # View over one task mapping node, shared by all task-oriented rules.
    # Resolves the action module the way Ansible does: the first key that
    # is not a task modifier keyword, with `ansible.builtin.` /
    # `ansible.legacy.` prefixes stripped for the bare module name.
    struct LintTask
      getter node : YAML::Nodes::Mapping
      getter file : PositionedFile
      # Module name as written (e.g. "apt", "ansible.builtin.shell")
      getter module_name : String
      # The module's parameters node (mapping or scalar)
      getter action_node : YAML::Nodes::Node
      # The node upstream's matchtask rules report violations at: the
      # module key for a normal task, the alias value for
      # `action:`/`local_action:` (ansible-lint pins fqcn at 6:17 for a
      # mapping's `module: debug` and at the string value's own start).
      getter action_key_node : YAML::Nodes::Node
      getter? handlers_section : Bool
      # True when the action was written as `action:`/`local_action:`,
      # which Ansible's ModuleArgsParser resolves to the module it names.
      getter? alias_action : Bool

      def initialize(@node, @file, @module_name, @action_node, @action_key_node,
                     @handlers_section = false, @alias_action = false)
      end

      def action_line : Int32
        NodeUtil.line(@action_key_node)
      end

      def action_column : Int32
        NodeUtil.column(@action_key_node)
      end

      # The `name:` value node, for rules that point at the name text
      # (upstream's name[casing]/name[template] do).
      def name_node : YAML::Nodes::Node?
        if (entry = NodeUtil.entry(@node, "name"))
          entry[1]
        end
      end

      def path : String
        file.path
      end

      def line : Int32
        NodeUtil.line(@node)
      end

      # Last line belonging to this task, as a human reads it: the task's
      # body runs until a blank line or a dedent back to its own
      # indentation. Node end marks cannot be used - a scalar's end
      # mark points at the *next* token, so neighbouring tasks would
      # come out overlapping.
      #
      # Blank lines inside a block scalar belong to the task and do not
      # end it; `covered` (see YamlText.scalar_continuation_lines) marks
      # them.
      def end_line(covered : Set(Int32)? = nil) : Int32
        lines = YamlText.physical_lines(@file.path)
        start = line
        indent = indent_of(lines[start - 1]?)
        last = start
        idx = start + 1
        while idx <= lines.size
          text = lines[idx - 1]?
          if text.nil? || text.strip.empty?
            break if covered.nil? || !covered.includes?(idx)
          elsif idx > start && indent_of(text) <= indent
            break
          end
          last = idx
          idx += 1
        end
        last
      end

      private def indent_of(text : String?) : Int32
        return 0 unless text
        text.size - text.lstrip.size
      end

      def name : String?
        if (entry = NodeUtil.entry(@node, "name")) && (v = NodeUtil.scalar_value(entry[1]))
          v
        end
      end

      # Upstream's Task.__str__: the task's name, falling back to the module
      # it calls plus its free-form arguments. Used for the
      # "Task/Handler: ..." detail the default formatter appends.
      def display_name : String
        if (task_name = name)
          return task_name
        end
        # Upstream joins as f"{module} {' '.join(args)}", so the space
        # after the module is always present, even with no arguments
        # (leaving a trailing space in the rendered detail).
        "#{bare_module} #{action_args}"
      end

      # The task's arguments as upstream's Task.__str__ renders them for
      # an unnamed task: free-form arguments verbatim, a mapping action
      # as `key=value` pairs. An alias's value begins with the module
      # token (and a mapping form carries its `module:` key), neither of
      # which upstream counts as an argument.
      private def action_args : String
        return alias_arguments if alias_action?
        if (free_form = NodeUtil.scalar_value(action_node))
          return free_form
        end
        return "" unless mapping = action_node.as?(YAML::Nodes::Mapping)
        pairs = [] of String
        NodeUtil.each_entry(mapping) do |key_node, value_node|
          key = NodeUtil.scalar_value(key_node)
          value = NodeUtil.scalar_value(value_node)
          next unless key && value
          pairs << "#{key}=#{value}"
        end
        pairs.join(' ')
      end

      # An alias's arguments as upstream's normalized action dict holds
      # them: the string form's tail past the module token, the mapping
      # form's entries without the `module:` key that names the module.
      # Rules that read free-form arguments need this rather than the raw
      # value, which still starts with the module token an alias adds.
      def alias_arguments : String
        if (free_form = NodeUtil.scalar_value(action_node))
          return free_form.lstrip.split(/\s+/, 2)[1]? || ""
        end
        return "" unless mapping = action_node.as?(YAML::Nodes::Mapping)
        pairs = [] of String
        NodeUtil.each_entry(mapping) do |key_node, value_node|
          key = NodeUtil.scalar_value(key_node)
          value = NodeUtil.scalar_value(value_node)
          next unless key && value
          next if key == "module"
          pairs << "#{key}=#{value}"
        end
        pairs.join(' ')
      end

      def param(key : String) : String?
        [action_node, args_node].each do |source|
          mapping = source.as?(YAML::Nodes::Mapping) || next
          if (entry = NodeUtil.entry(mapping, key)) && (v = NodeUtil.scalar_value(entry[1]))
            return v
          end
        end
        nil
      end

      def has_param?(key : String) : Bool
        [action_node, args_node].each do |source|
          mapping = source.as?(YAML::Nodes::Mapping) || next
          return true unless NodeUtil.entry(mapping, key).nil?
        end
        false
      end

      # Task-level `args:` mapping (Ansible merges it into module params).
      def args_node : YAML::Nodes::Node?
        if (entry = NodeUtil.entry(@node, "args"))
          entry[1]
        end
      end

      def has_task_key?(key : String) : Bool
        !NodeUtil.entry(@node, key).nil?
      end

      def task_value(key : String) : String?
        if (entry = NodeUtil.entry(@node, key)) && (v = NodeUtil.scalar_value(entry[1]))
          v
        end
      end

      # Resolved canonical module, or nil when not a known builtin.
      def builtin_alias : String?
        MODERNIZATION.builtin_alias(module_name)
      end

      # Module name with ansible.builtin./ansible.legacy. prefix stripped.
      def bare_module : String
        module_name.sub("ansible.builtin.", "").sub("ansible.legacy.", "")
      end
    end

    module TaskKeywords
      # Task-level keywords that are not module actions. Modeled on
      # Ansible's TASK_KEYWORDS + loop keywords; anything else is
      # treated as a module name. `action`/`local_action` are here
      # because ModuleArgsParser adds them to a task's attributes: they
      # name an action rather than being one themselves.
      SET = %w[
        name when become become_user become_method become_flags
        tags register ignore_errors ignore_unreachable changed_when
        failed_when until retries delay loop loop_control with_items
        with_list with_fileglob with_lines with_dict with_flattened
        with_first_found with_together with_sequence with_random_choice
        with_indexed_items with_ini with_subelements with_filetree
        with_urls with_community_general_filetree with_inventory_hostnames
        vars delegate_to delegate_facts notify listen args environment
        no_log run_once check_mode diff async poll throttle
        any_errors_fatal remote_user sudo sudo_user su su_user
        connection port ansible_user ansible_connection ansible_port
        collections module_defaults rescue always block debugger
        action local_action
        vars_files fact_path gather_facts hosts tasks pre_tasks
        post_tasks handlers roles become_exe become_prompts
      ]

      def modifier?(key : String) : Bool
        SET.includes?(key)
      end
    end

    module MODERNIZATION
      extend self

      # Core (ansible.builtin) module/action names. Used both to resolve
      # bare module names to their FQCN alias and to detect `fqcn`
      # violations. Mirrors ansible-core's module list.
      BUILTINS = %w[
        add_host apt apt_key apt_repository assemble assert async_status
        blockinfile command copy cron debconf debug dnf dnf5 dpkg_selections
        expect fail fetch file find gather_facts get_url getent git group
        group_by hostname import_playbook import_tasks include_role
        include_tasks include_vars iptables known_hosts lineinfile meta
        mount package package_facts pause ping pip raw reboot replace
        rpm_key script service service_facts set_fact set_stats setup
        shell slurp stat subversion systemd systemd_service sysvinit
        tempfile template unarchive uri user validate_argument_spec
        wait_for wait_for_connection yum yum_repository
        ansible.builtin.add_host ansible.builtin.apt ansible.builtin.apt_key
        ansible.builtin.command ansible.builtin.copy ansible.builtin.file
        ansible.builtin.get_url ansible.builtin.lineinfile
        ansible.builtin.service ansible.builtin.set_fact
        ansible.builtin.shell ansible.builtin.template
        ansible.builtin.uri ansible.builtin.user ansible.builtin.wait_for
        ansible.legacy.command ansible.legacy.file ansible.legacy.shell
        include_action
      ]

      def builtin?(module_name : String) : Bool
        BUILTINS.includes?(module_name)
      end

      def builtin_alias(module_name : String) : String?
        return module_name if module_name.starts_with?("ansible.builtin.") ||
                              module_name.starts_with?("ansible.legacy.")
        "ansible.builtin.#{module_name}" if BUILTINS.includes?(module_name)
      end
    end

    module TaskWalker
      extend TaskKeywords

      # Yield one LintTask for every task found in a loaded file:
      #  - tasks/handlers files: the root list (or a block)
      #  - playbooks: plays' pre_tasks/tasks/post_tasks/handlers
      # Recurses into block/rescue/always sublists.
      # A root list of mappings is a playbook only when its entries are
      # plays (they carry hosts/tasks sections).
      def self.playbook_root?(file : PositionedFile) : Bool
        list = file.root.try(&.as?(YAML::Nodes::Sequence)) || return false
        list.nodes.any? do |item|
          next false unless item.is_a?(YAML::Nodes::Mapping)
          !NodeUtil.entry(item, "hosts").nil? ||
            !NodeUtil.entry(item, "tasks").nil? ||
            !NodeUtil.entry(item, "pre_tasks").nil? ||
            !NodeUtil.entry(item, "post_tasks").nil? ||
            !NodeUtil.entry(item, "handlers").nil?
        end
      end

      def self.collect_tasks(file : PositionedFile) : Array(LintTask)
        tasks = [] of LintTask
        root = file.root || return tasks
        list = root.as?(YAML::Nodes::Sequence) || return tasks
        # A root list of mappings is a playbook only when its entries are
        # plays (they carry `hosts:`); otherwise it is a task/handler file.
        playbook_like = list.nodes.any? do |item|
          next false unless item.is_a?(YAML::Nodes::Mapping)
          !NodeUtil.entry(item, "hosts").nil? ||
            !NodeUtil.entry(item, "tasks").nil? ||
            !NodeUtil.entry(item, "pre_tasks").nil? ||
            !NodeUtil.entry(item, "post_tasks").nil? ||
            !NodeUtil.entry(item, "handlers").nil?
        end
        if playbook_like
          list.nodes.each do |play_node|
            play = play_node.as?(YAML::Nodes::Mapping) || next
            %w[pre_tasks tasks post_tasks handlers].each do |section|
              if (entry = NodeUtil.entry(play, section)) &&
                 (tasks_list = entry[1].as?(YAML::Nodes::Sequence))
                walk_list(tasks_list, file, tasks,
                  in_handlers: section == "handlers")
              end
            end
          end
        else
          walk_list(list, file, tasks)
        end
        tasks
      end

      def self.each_task(file : PositionedFile, &)
        collect_tasks(file).each { |task| yield task }
      end

      # Yield every block parent mapping (a list entry carrying a `block:`
      # key), nested ones included - collect_tasks deliberately skips them
      # because a block has no module to run, but upstream models a block
      # as a task with a dummy "block/always/rescue" action, so rules that
      # look at the task's own keys (name) must see it too.
      def self.each_block(file : PositionedFile, &block : YAML::Nodes::Mapping ->) : Nil
        root = file.root || return
        list = root.as?(YAML::Nodes::Sequence) || return
        if playbook_root?(file)
          list.nodes.each do |play_node|
            play = play_node.as?(YAML::Nodes::Mapping) || next
            %w[pre_tasks tasks post_tasks handlers].each do |section|
              if (entry = NodeUtil.entry(play, section)) &&
                 (tasks_list = entry[1].as?(YAML::Nodes::Sequence))
                walk_blocks(tasks_list, &block)
              end
            end
          end
        else
          walk_blocks(list, &block)
        end
      end

      private def self.walk_blocks(list : YAML::Nodes::Sequence, &block : YAML::Nodes::Mapping ->) : Nil
        list.nodes.each do |item|
          node = item.as?(YAML::Nodes::Mapping) || next
          next if NodeUtil.entry(node, "block").nil?
          block.call(node)
          %w[block rescue always].each do |section|
            if (entry = NodeUtil.entry(node, section)) &&
               (sub = entry[1].as?(YAML::Nodes::Sequence))
              walk_blocks(sub, &block)
            end
          end
        end
      end

      # Every task-statement mapping in the file's task lists, block
      # statements included. Upstream builds a Task for a block statement
      # too (with the synthetic action "block/always/rescue") and keeps
      # its nested task lists in the normalized task, so a rule walking
      # those values sees a nested task's values twice - through the
      # enclosing block and as a task of its own.
      def self.each_task_mapping(file : PositionedFile, &) : Nil
        root = file.root || return
        list = root.as?(YAML::Nodes::Sequence) || return
        statements = [] of YAML::Nodes::Mapping
        if playbook_root?(file)
          list.nodes.each do |play_node|
            play = play_node.as?(YAML::Nodes::Mapping) || next
            %w[pre_tasks tasks post_tasks handlers].each do |section|
              if (entry = NodeUtil.entry(play, section)) &&
                 (tasks_list = entry[1].as?(YAML::Nodes::Sequence))
                collect_statements(tasks_list, statements)
              end
            end
          end
        else
          collect_statements(list, statements)
        end
        statements.each { |node| yield node }
      end

      # A yielding helper cannot recurse here (Crystal inlines blocks, so
      # the call would expand forever); an explicit stack collects the
      # same statements. The order is irrelevant - the report sorts
      # violations by position.
      private def self.collect_statements(list : YAML::Nodes::Sequence, statements : Array(YAML::Nodes::Mapping)) : Nil
        stack = [] of YAML::Nodes::Sequence
        stack << list
        while current = stack.pop?
          current.nodes.each do |item|
            node = item.as?(YAML::Nodes::Mapping) || next
            statements << node
            %w[block rescue always].each do |section|
              if (entry = NodeUtil.entry(node, section)) &&
                 (sub = entry[1].as?(YAML::Nodes::Sequence))
                stack << sub
              end
            end
          end
        end
      end

      # Every task statement mapping in the order ansible's loader parses
      # them: play sections in turn, each list front to back, and a
      # block's own sublists right after the block statement itself.
      # Handlers come first because Base.load_data walks a play's
      # attributes by FieldAttribute priority (all four lists share -1,
      # so class order decides) and handlers are declared first -
      # verified against ansible-lint 25.2.1: one broken task in each
      # section reports the handler.
      # Block statements are yielded too - the syntax-check gate has to
      # skip them, since load_list_of_tasks hands a `block:` to
      # Block.load and never runs ModuleArgsParser over it.
      def self.each_statement(file : PositionedFile, &) : Nil
        root = file.root || return
        list = root.as?(YAML::Nodes::Sequence) || return
        stack = [] of YAML::Nodes::Node
        if playbook_root?(file)
          # Reversed pushes so the first play's first task pops first.
          list.nodes.reverse_each do |play_node|
            play = play_node.as?(YAML::Nodes::Mapping) || next
            %w[tasks post_tasks pre_tasks handlers].each do |section|
              entry = NodeUtil.entry(play, section) || next
              sub = entry[1].as?(YAML::Nodes::Sequence) || next
              sub.nodes.reverse_each { |item| stack << item }
            end
          end
        else
          list.nodes.reverse_each { |item| stack << item }
        end
        while node = stack.pop?
          mapping = node.as?(YAML::Nodes::Mapping) || next
          yield mapping
          %w[always rescue block].each do |section|
            entry = NodeUtil.entry(mapping, section) || next
            sub = entry[1].as?(YAML::Nodes::Sequence) || next
            sub.nodes.reverse_each { |item| stack << item }
          end
        end
      end

      private def self.walk_list(list : YAML::Nodes::Sequence, file : PositionedFile, tasks : Array(LintTask), in_handlers : Bool = false) : Nil
        list.nodes.each do |item|
          node = item.as?(YAML::Nodes::Mapping) || next
          if !NodeUtil.entry(node, "block").nil?
            %w[block rescue always].each do |section|
              if (entry = NodeUtil.entry(node, section)) &&
                 (sub = entry[1].as?(YAML::Nodes::Sequence))
                walk_list(sub, file, tasks, in_handlers)
              end
            end
            next
          end
          if (task = from_mapping(node, file))
            tasks << LintTask.new(task.node, task.file, task.module_name,
              task.action_node, task.action_key_node, in_handlers,
              task.alias_action?)
          end
        end
      end

      # Ansible's legacy action directives: the value names the module to
      # run, so the directive keyword itself is never a module name.
      ALIAS_KEYS = %w[action local_action]

      # The action a task statement runs, as ModuleArgsParser resolves it.
      private record ActionEntry,
        module_name : String,
        action_node : YAML::Nodes::Node,
        key_node : YAML::Nodes::Node,
        alias_action : Bool = false

      def self.from_mapping(node : YAML::Nodes::Mapping, file : PositionedFile) : LintTask?
        return nil unless NodeUtil.entry(node, "block").nil?
        entry = nil
        NodeUtil.each_entry(node) do |k, v|
          next unless entry.nil?
          key = k.as?(YAML::Nodes::Scalar).try(&.value) || next
          entry =
            if ALIAS_KEYS.includes?(key)
              alias_entry(key, v)
            elsif modifier?(key)
              nil
            else
              ActionEntry.new(key, v, k)
            end
        end
        action = entry || return nil
        LintTask.new(node, file, action.module_name, action.action_node,
          action.key_node, alias_action: action.alias_action)
      end

      # `action:`/`local_action:` names its module in the mapping's
      # `module:` value or in the string's first token, and every other
      # key/token is that module's argument (ModuleArgsParser's
      # _normalize_old_style_args). The value node itself stays the
      # violation position: ansible-lint reports the resolved action
      # there (6:17 for a mapping's `module: debug`, the string value's
      # own column for `local_action: debug msg=hi`).
      private def self.alias_entry(key : String, value : YAML::Nodes::Node) : ActionEntry
        if mapping = value.as?(YAML::Nodes::Mapping)
          if (module_entry = NodeUtil.entry(mapping, "module")) &&
             (name = NodeUtil.scalar_value(module_entry[1])) && !name.empty?
            return ActionEntry.new(name, mapping, module_entry[1], true)
          end
        elsif scalar = value.as?(YAML::Nodes::Scalar)
          if (name = scalar.value.lstrip.split(/\s+/, 2).first?) && !name.empty?
            return ActionEntry.new(name, scalar, scalar, true)
          end
        end
        # A malformed alias (no module named) keeps the keyword as the
        # action, the way this model saw the task before aliases existed:
        # Ansible refuses to load it, and parsing that failure is the
        # syntax-check rule's job, not the task model's.
        ActionEntry.new(key, value, value, true)
      end
    end
  end
end
