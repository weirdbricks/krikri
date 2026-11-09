require "../krikri/collection_index"
require "../krikri/python_filter_runner"
require "./imports"

module Krikri
  module Lint
    # Upstream's failed-file gate, for the one syntax-check failure kind
    # krikri-lint can reach a verdict on: unresolvable module names.
    # ansible-lint runs `ansible-playbook --syntax-check` per
    # playbook/role lintable and then runs NO other rule on a file the
    # check failed on (Lintable.failed()/stop_processing in
    # ansiblelint/file_utils.py and runner.py, and the file.failed()
    # guards at the top of name.py's matchplay/matchtask). A task whose
    # module name the controller cannot resolve aborts the check with
    # "couldn't resolve module/action 'x'" (syntax-check[unknown-module]),
    # so upstream reports just that one match for the file - a rule
    # krikri-lint deliberately does not implement, which the parity
    # harness books as an unimplemented-rule gap - and the file must
    # emit no violations at all for the triples to stay identical.
    #
    # Only the files the failing check actually NAMES go silent (each
    # verified against ansible-lint 25.2.1): the playbook carrying the
    # bad task, and role content a check loads - a role's
    # tasks/handlers/meta entry points and their static imports, reached
    # from a playbook's `roles:`/import_role or from a targeted role. A
    # task file nothing loads (a sibling of main.yml, a dynamic
    # include_tasks/include_role) and a non-role task file imported from
    # a playbook are not silenced upstream - its failed-file marking
    # misses them - and they keep reporting here too.
    class SyntaxCheck
      def initialize(files : Array(String), targets : Array(String))
        @walked = Set(String).new
        expand(walk_roots(files, targets))
      end

      # Whether upstream's failed-file gate silences this file: its
      # tasks carry a module name the controller cannot resolve, and the
      # file is one a playbook/role syntax check names.
      def silenced?(file : PositionedFile) : Bool
        return false unless file.root
        role = role_dir_for(file.path)
        named_by_check = playbook_kind?(file) ||
                         (!role.nil? && @walked.includes?(Imports.relative(file.path)))
        return false unless named_by_check
        unresolvable_name?(file, role)
      end

      # Walk roots: every playbook in the run is syntax-checked itself,
      # and a role target's entry points are what its temporary
      # import_role check loads.
      private def walk_roots(files : Array(String), targets : Array(String)) : Array(String)
        roots = files.select do |path|
          File.exists?(path) && playbook_kind?(PositionedFile.load(path))
        end
        targets.each do |target|
          dir = File.expand_path(target)
          next unless File.directory?(dir)
          next unless role_target?(dir)
          roots.concat(Imports.entry_point_files(dir))
        end
        roots
      end

      private def expand(roots : Array(String)) : Nil
        queue = roots.dup
        until queue.empty?
          path = queue.shift
          next unless path
          normalized = Imports.relative(path)
          next unless File.exists?(normalized)
          next unless @walked.add?(normalized)
          queue.concat(Imports.static_children(normalized))
        end
      end

      # A directory target upstream's kind detection calls a role: named
      # `roles/<name>`, or carrying one of the role subdirectories.
      private def role_target?(dir : String) : Bool
        File.basename(File.dirname(dir)) == "roles" ||
          Imports::ROLE_SUBDIRS.any? { |sub| File.directory?(File.join(dir, sub)) }
      end

      # Upstream's kind detection (kind_from_path's playbook patterns,
      # then file_utils.py's _guess_kind sniff): the path patterns
      # `**/playbooks/*.yml` / `**/*playbook*.yml` force the playbook
      # kind, and otherwise a list of mappings whose first entry carries
      # hosts/import_playbook is a playbook (a `rules` key makes it a
      # rulebook instead). Only playbook-kind lintables get a syntax
      # check of their own.
      private def playbook_kind?(file : PositionedFile) : Bool
        return true if playbook_path?(file.path)
        root = file.root.as?(YAML::Nodes::Sequence) || return false
        first = root.nodes.first?.try(&.as?(YAML::Nodes::Mapping)) || return false
        return false if NodeUtil.entry(first, "rules")
        !NodeUtil.entry(first, "hosts").nil? ||
          !NodeUtil.entry(first, "import_playbook").nil? ||
          !NodeUtil.entry(first, "ansible.builtin.import_playbook").nil?
      end

      private def playbook_path?(path : String) : Bool
        name = File.basename(path)
        File.basename(File.dirname(path)) == "playbooks" ||
          (name.includes?("playbook") && name.ends_with?(".yml")) ||
          (name.includes?("playbook") && name.ends_with?(".yaml"))
      end

      # The canonical role directory a file lives in (…/roles/<name>/),
      # or nil outside one: only role content goes silent when a check
      # failure names it, and only when a check walks it (see the class
      # comment).
      private def role_dir_for(path : String) : String?
        dir = File.dirname(File.expand_path(path))
        while !dir.empty? && dir != "/"
          parent = File.dirname(dir)
          return dir if File.basename(parent) == "roles"
          break if parent == dir
          dir = parent
        end
        nil
      end

      # True when the file's own tasks carry a module name the real
      # controller cannot resolve to a module file - the same verdict
      # behind the engine's playbook-load refusal (CollectionIndex
      # #controller_resolves?, consulted exactly like the parser: the
      # task's own `collections:` replaces the play's list plus the
      # role's meta declaration). Names resolution cannot decide (no
      # discoverable ansible-core, templated action strings) stay
      # permissive, so a file goes silent only on a definite negative.
      private def unresolvable_name?(file : PositionedFile, role_path : String?) : Bool
        playbook_dir = File.dirname(File.expand_path(file.path))
        inherited = play_collections(file) +
                    CollectionIndex.role_meta_collections(role_path)
        TaskWalker.each_task(file) do |task|
          name = action_module_name(task) || next
          collections = task_collections(task) || inherited
          resolution = CollectionIndex.controller_resolves?(name, collections,
            role_path, playbook_dir)
          return true if resolution[:resolves] == false
        end
        false
      end

      # The module a task calls, the way ansible's loader reads it: a
      # bare key is the module name. An `action:`/`local_action:`
      # directive resolves its module lazily at run time, so an
      # unresolvable one never fails the load-time check (verified
      # against ansible-lint 25.2.1: a play around `action: unknown x=1`
      # keeps reporting name[play]); the directive key is not a module
      # name and must not be resolved as one.
      private def action_module_name(task : LintTask) : String?
        key = task.module_name
        return nil if key == "action" || key == "local_action"
        key.empty? ? nil : key
      end

      private def play_collections(file : PositionedFile) : Array(String)
        found = [] of String
        root = file.root.as?(YAML::Nodes::Sequence) || return found
        root.nodes.each do |item|
          play = item.as?(YAML::Nodes::Mapping) || next
          entry = NodeUtil.entry(play, "collections") || next
          found.concat(string_list(entry[1]))
        end
        found
      end

      private def task_collections(task : LintTask) : Array(String)?
        entry = NodeUtil.entry(task.node, "collections") || return nil
        string_list(entry[1])
      end

      private def string_list(node : YAML::Nodes::Node) : Array(String)
        case node
        when YAML::Nodes::Scalar
          node.value.empty? ? [] of String : [node.value]
        when YAML::Nodes::Sequence
          node.nodes.compact_map { |item| NodeUtil.scalar_value(item) }
        else
          [] of String
        end
      end
    end
  end
end
