require "../krikri/collection_index"
require "../krikri/python_filter_runner"
require "./imports"

module Krikri
  module Lint
    # Upstream's failed-file gate, for the syntax-check failure kinds
    # krikri-lint can reach a verdict on: unresolvable module names,
    # unresolvable play `roles:` entries, and tasks whose shape
    # ModuleArgsParser refuses.
    # ansible-lint runs `ansible-playbook --syntax-check` per
    # playbook/role lintable and then runs NO other rule on a file the
    # check failed on (Lintable.failed()/stop_processing in
    # ansiblelint/file_utils.py and runner.py, and the file.failed()
    # guards at the top of name.py's matchplay/matchtask). A task whose
    # module name the controller cannot resolve aborts the check with
    # "couldn't resolve module/action 'x'" (syntax-check[unknown-module]):
    # #violation builds that single match and the runner emits it, so the
    # file reports nothing else and the triples stay identical. A task
    # whose shape ModuleArgsParser itself refuses - a conflicting second
    # action statement, no action at all - aborts the load the same way,
    # with ansible-lint's syntax-check[specific] at the task mapping. A play
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
      # Modules krikri ships that are NOT Ansible modules at all, so the
      # captured reference tables (and upstream ansible-lint) have never
      # heard of them. They do resolve for krikri-playbook, so a task
      # using one must not be reported as an unknown module. Currently
      # just json_file (issue #1835).
      KRIKRI_EXTENSION_MODULES = %w[json_file]

      def initialize(files : Array(String), targets : Array(String),
                     @kinds : Array(KindPattern) = [] of KindPattern)
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
      # no other rule on it: one of its tasks is one ansible's own load
      # refuses, and the file is one a playbook/role syntax check names.
      # Nil for every file the check does not fail on.
      def violation(file : PositionedFile) : Violation?
        return nil unless file.root
        role = role_dir_for(file.path)
        named_by_check = playbook_kind?(file) ||
                         (!role.nil? && @walked.includes?(Imports.relative(file.path)))
        return nil unless named_by_check
        first_task_failure(file, role) || vars_file_failure(file)
      end

      # Whether this file's own playbook syntax check failed on a role no
      # search path holds, so no rule but syntax-check may report on it.
      # (A task failure is the match #violation reports; the runner never
      # reaches here for such a file.)
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
          queue.concat(Imports.static_children(normalized, @kinds))
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
        queue = Imports.children(root, @kinds)
        until queue.empty?
          child = queue.shift
          next unless child
          rel = Imports.relative(child)
          next unless File.exists?(rel)
          next unless into.add?(rel)
          queue.concat(Imports.children(rel, @kinds))
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
        FileType.playbook_path?(file.path) || FileType.playbook_document?(file.root)
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

      # The match for the file's own first task ansible's syntax check
      # refuses, or nil when every task parses and resolves. A task fails
      # the load on its shape (ModuleArgsParser.failure) or on a module name
      # krikri's OWN baked reference tables say cannot resolve to a module
      # file (CollectionIndex.reference_resolves?) - resolved with the
      # same inputs the real load uses (the task's own `collections:`
      # replaces the play's list plus the role's meta declaration) - and
      # the scan stops at the first task that fails either, since a load
      # aborts there. The tables are captured, not read from this
      # controller, so the rule reports the same files whether or not
      # ansible-core/collections are installed here. Names the tables
      # cannot decide (a collection krikri kept no file tree for,
      # templated action strings) stay permissive, so a file reports only
      # on a definite negative. Unlike the parser, this rule does not
      # exempt names krikri has ported: upstream's ansible-playbook
      # --syntax-check has no such carve-out.
      private def first_task_failure(file : PositionedFile, role_path : String?) : Violation?
        playbook_dir = File.dirname(File.expand_path(file.path))
        inherited = play_collections(file) +
                    CollectionIndex.role_meta_collections(role_path)
        TaskWalker.each_statement(file) do |node|
          # A `block:` statement is handed to Block.load, never to
          # ModuleArgsParser, so there is no module name to resolve.
          if NodeUtil.entry(node, "block").nil?
            if message = ModuleArgsParser.failure(node)
              return SyntaxCheckRule.task_parse_failure(file, node, message)
            end
          end
          task = TaskWalker.from_mapping(node, file) || next
          name = action_module_name(task) || next
          next if KRIKRI_EXTENSION_MODULES.includes?(name)
          collections = task_collections(task) || inherited
          resolution = CollectionIndex.reference_resolves?(name, collections,
            role_path, playbook_dir)
          if resolution[:resolves] == false
            return SyntaxCheckRule.unknown_module(file, task, name)
          end
        end
        nil
      end

      # A play's `vars_files:` entry that the loader can find but cannot
      # read as a file aborts the syntax check after the playbook has
      # loaded. get_vars reads each entry through
      # DataLoader#load_from_file, whose read of a directory (or any
      # unreadable path) raises OSError and becomes an AnsibleParserError
      # carrying no "Origin:" line - so no OUTPUT_PATTERNS entry matches
      # and ansible-lint reports its catch-all internal-error instead of a
      # syntax-check[...] tag, at the playbook's first line. A play whose
      # role was missing already failed the load itself, before any
      # vars_files is read, so that verdict wins.
      private def vars_file_failure(file : PositionedFile) : Violation?
        return nil unless playbook_kind?(file)
        return nil if failed?(file)
        root = file.root.as?(YAML::Nodes::Sequence) || return nil
        playbook_dir = File.dirname(File.expand_path(file.path))
        root.nodes.each do |item|
          play = item.as?(YAML::Nodes::Mapping) || next
          entry = NodeUtil.entry(play, "vars_files") || next
          vars_file_entries(entry[1]).each do |name|
            path = resolve_vars_file(playbook_dir, name) || next
            reason = vars_file_read_cause(path) || next
            return InternalErrorRule.read_failure(file, path, reason)
          end
        end
        nil
      end

      # Every path a `vars_files:` value names: an item is itself a list
      # of candidates (the conditional include form, like
      # with_first_found), so a nested sequence contributes its own
      # entries.
      private def vars_file_entries(node : YAML::Nodes::Node) : Array(String)
        case node
        when YAML::Nodes::Scalar
          [node.value]
        when YAML::Nodes::Sequence
          node.nodes.flat_map { |item| vars_file_entries(item) }
        else
          [] of String
        end
      end

      # Where the loader resolves one vars_files entry for a play:
      # DataLoader#path_dwim_relative_stack with the play's own directory
      # as the search path and "vars" as the dirname, i.e.
      # `<playbook_dir>/vars/<item>` first (unless the item already names
      # a vars/ path) and `<playbook_dir>/<item>` last, an absolute path
      # as-is. Existence alone decides, the way os.path.exists does, so a
      # directory resolves here exactly as it does there. A templated
      # entry cannot be resolved statically and stays permissive.
      private def resolve_vars_file(playbook_dir : String, name : String) : String?
        return nil if name.empty?
        return nil if name.includes?("{{") || name.includes?("{%")
        return File.exists?(name) ? File.expand_path(name) : nil if name.starts_with?('/')
        candidates = [] of String
        candidates << File.join(playbook_dir, "vars", name) unless name.split('/').first? == "vars"
        candidates << File.join(playbook_dir, name)
        candidates.find { |candidate| File.exists?(candidate) }.try do |path|
          File.expand_path(path)
        end
      end

      # The OSError cause the loader's read hits for a path that exists
      # but cannot be read as a file, rendered the way Python's OSError
      # str() does ("[Errno 21] Is a directory: '<path>'"). A directory is
      # the reachable case: os.path.exists is true for it, so the search
      # stops there and the read raises IsADirectoryError.
      private def vars_file_read_cause(path : String) : String?
        info = File.info?(path) || return nil
        return "[Errno 21] Is a directory: '#{path}'" if info.directory?
        return nil if File::Info.readable?(path)
        "[Errno 13] Permission denied: '#{path}'"
      end

      # The module a task calls, the way ansible's loader reads it: a
      # bare key is the module name. An `action:`/`local_action:`
      # directive resolves its module lazily at run time, so an
      # unresolvable one never fails the load-time check (verified
      # against ansible-lint 25.2.1: a play around `action: unknown x=1`
      # keeps reporting name[play]), even though the linter's own task
      # view already names the module the directive points at.
      private def action_module_name(task : LintTask) : String?
        return nil if task.alias_action?
        key = task.module_name
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
