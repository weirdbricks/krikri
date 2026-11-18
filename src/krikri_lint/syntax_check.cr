require "../krikri/collection_index"
require "../krikri/python_filter_runner"
require "./imports"

module Krikri
  module Lint
    # Upstream's failed-file gate, for the two syntax-check failure kinds
    # krikri-lint can reach a verdict on: unresolvable module names and
    # unresolvable play `roles:` entries.
    # ansible-lint runs `ansible-playbook --syntax-check` per
    # playbook/role lintable and then runs NO other rule on a file the
    # check failed on (Lintable.failed()/stop_processing in
    # ansiblelint/file_utils.py and runner.py, and the file.failed()
    # guards at the top of name.py's matchplay/matchtask). A task whose
    # module name the controller cannot resolve aborts the check with
    # "couldn't resolve module/action 'x'" (syntax-check[unknown-module]):
    # #violation builds that single match and the runner emits it, so the
    # file reports nothing else and the triples stay identical. A play
    # whose `roles:` entry names a role no search path holds fails the
    # check on the playbook itself (syntax-check[specific]), which the
    # SyntaxCheckRule reports at the entry.
    #
    # Only the files the failing check actually NAMES report the match
    # (each verified against ansible-lint 25.2.1): the playbook carrying
    # the bad task, and role content a check loads - a role's
    # tasks/handlers/meta entry points and their static imports, reached
    # from a playbook's `roles:`/import_role or from a targeted role. A
    # task file nothing loads (a sibling of main.yml, a dynamic
    # include_tasks/include_role) and a non-role task file imported from
    # a playbook are not named upstream - its failed-file marking misses
    # them - and they keep reporting here too.
    #
    # A playbook the check itself failed on is never walked for children
    # upstream (runner.py's `if lintable.failed(): continue`), so nothing
    # it loads is linted either - which is why a playbook broken on a
    # missing role reports one match and no role-file matches.
    class SyntaxCheck
      def initialize(files : Array(String), targets : Array(String))
        @walked = Set(String).new
        @missing = {} of String => RoleLookup::Missing
        @suppressed = Set(String).new
        @kept = Set(String).new
        @targets = targets
        roots = walk_roots(files, targets)
        expand(roots)
        mark_missing_roles
        collect_suppressed(roots)
      end

      # The match upstream reports for this file, and the reason it runs
      # no other rule on it: its tasks carry a module name the controller
      # cannot resolve, and the file is one a playbook/role syntax check
      # names. Nil for every file the check does not fail on.
      def violation(file : PositionedFile) : Violation?
        return nil unless file.root
        role = role_dir_for(file.path)
        named_by_check = playbook_kind?(file) ||
                         (!role.nil? && @walked.includes?(Imports.relative(file.path)))
        return nil unless named_by_check
        unknown_module(file, role)
      end

      # Whether this file's own playbook syntax check failed on a role no
      # search path holds, so no rule but syntax-check may report on it.
      # (An unresolvable module name is the match #violation reports; the
      # runner never reaches here for such a file.)
      def failed?(file : PositionedFile) : Bool
        @missing.has_key?(Imports.relative(file.path))
      end

      # Whether upstream never had this file as a lintable at all: only a
      # failed playbook could have loaded it, and a failed playbook is
      # never walked for children. Explicit targets and files another
      # passing root loads stay linted.
      def suppressed?(path : String) : Bool
        return false if @suppressed.empty?
        rel = Imports.relative(path)
        return false unless @suppressed.includes?(rel)
        return false if @kept.includes?(rel)
        !explicit_target?(path)
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

      private def mark_missing_roles : Nil
        @walked.each do |path|
          file = PositionedFile.load(path)
          next unless playbook_kind?(file)
          if missing = RoleLookup.first_missing(file)
            @missing[path] = missing
          end
        end
      end

      # Children of a failed playbook are not lintables upstream, and
      # neither are their children - `_emit_matches` skips a failed file
      # before walking it. Everything a root that did not fail on a
      # missing role reaches stays.
      private def collect_suppressed(roots : Array(String)) : Nil
        @missing.each_key { |path| collect_children(path, @suppressed) }
        roots.each do |root|
          rel = Imports.relative(root)
          next if @missing.has_key?(rel)
          @kept << rel
          collect_children(root, @kept)
        end
      end

      private def collect_children(root : String, into : Set(String)) : Nil
        queue = Imports.children(root)
        until queue.empty?
          child = queue.shift
          next unless child
          rel = Imports.relative(child)
          next unless File.exists?(rel)
          next unless into.add?(rel)
          queue.concat(Imports.children(rel))
        end
      end

      # A path the user named outright (a file target, or any file under
      # a directory target) is a lintable whatever a playbook's check
      # says, so it is never suppressed.
      private def explicit_target?(path : String) : Bool
        real = File.exists?(path) ? File.realpath(path) : File.expand_path(path)
        @targets.any? do |target|
          next false unless File.exists?(target)
          expanded = File.realpath(target)
          File.directory?(expanded) ? real.starts_with?(expanded + "/") : real == expanded
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

      # The match for the file's own first task carrying a module name
      # the real controller cannot resolve to a module file - the same
      # CollectionIndex verdict the parser consults, with the same
      # inputs (the task's own `collections:` replaces the play's list
      # plus the role's meta declaration), but without the parser's
      # native-module carve-out: a name krikri has ported still refuses
      # here, because upstream's ansible-playbook --syntax-check has no
      # such carve-out. Ansible's check stops at the first such name, so
      # only that task is reported. Names resolution cannot decide (no
      # discoverable ansible-core, templated action strings) stay
      # permissive, so a file reports only on a definite negative.
      private def unknown_module(file : PositionedFile, role_path : String?) : Violation?
        playbook_dir = File.dirname(File.expand_path(file.path))
        inherited = play_collections(file) +
                    CollectionIndex.role_meta_collections(role_path)
        TaskWalker.each_task(file) do |task|
          name = action_module_name(task) || next
          collections = task_collections(task) || inherited
          resolution = CollectionIndex.controller_resolves?(name, collections,
            role_path, playbook_dir)
          if resolution[:resolves] == false
            return SyntaxCheckRule.unknown_module(file, task, name)
          end
        end
        nil
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
