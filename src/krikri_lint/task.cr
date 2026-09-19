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

      def initialize(@node, @file, @module_name, @action_node)
      end

      def path : String
        file.path
      end

      def line : Int32
        NodeUtil.line(@node)
      end

      def name : String?
        if (entry = NodeUtil.entry(@node, "name")) && (v = NodeUtil.scalar_value(entry[1]))
          v
        end
      end

      def param(key : String) : String?
        action = @action_node.as?(YAML::Nodes::Mapping) || return nil
        if (entry = NodeUtil.entry(action, key)) && (v = NodeUtil.scalar_value(entry[1]))
          v
        end
      end

      def has_param?(key : String) : Bool
        action = @action_node.as?(YAML::Nodes::Mapping) || return false
        !NodeUtil.entry(action, key).nil?
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
    end

    module TaskKeywords
      # Task-level keywords that are not module actions. Modeled on
      # Ansible's TASK_KEYWORDS + loop keywords; anything else is
      # treated as a module name.
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
      def self.each_task(file : PositionedFile, &)
        root = file.root || return
        list = root.as?(YAML::Nodes::Sequence) || return
        if file.file_type.playbook?
          list.nodes.each do |play_node|
            play = play_node.as?(YAML::Nodes::Mapping) || next
            %w[pre_tasks tasks post_tasks handlers].each do |section|
              if (entry = NodeUtil.entry(play, section)) &&
                 (tasks = entry[1].as?(YAML::Nodes::Sequence))
                walk_list(tasks, file) { |task| yield task }
              end
            end
          end
        else
          walk_list(list, file) { |task| yield task }
        end
      end

      private def self.walk_list(list : YAML::Nodes::Sequence, file : PositionedFile, &)
        list.nodes.each do |item|
          node = item.as?(YAML::Nodes::Mapping) || next
          if (block_entry = NodeUtil.entry(node, "block"))
            %w[block rescue always].each do |section|
              if (entry = NodeUtil.entry(node, section)) &&
                 (sub = entry[1].as?(YAML::Nodes::Sequence))
                walk_list(sub, file) { |task| yield task }
              end
            end
            next
          end
          if (task = from_mapping(node, file))
            yield task
          end
        end
      end

      def self.from_mapping(node : YAML::Nodes::Mapping, file : PositionedFile) : LintTask?
        return nil if !NodeUtil.entry(node, "block").nil?
        action_entry = nil
        NodeUtil.each_entry(node) do |k, v|
          next unless action_entry.nil?
          if (key = k.as?(YAML::Nodes::Scalar)) && key.value &&
             !modifier?(key.value)
            action_entry = {key.value, v}
          end
        end
        return nil unless action_entry
        module_name, action_node = action_entry
        LintTask.new(node, file, module_name.not_nil!, action_node.not_nil!)
      end
    end
  end
end
