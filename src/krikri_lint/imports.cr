module Krikri
  module Lint
    # Resolves the files a playbook or task file pulls in, mirroring
    # upstream's HandleChildren traversal (ansiblelint/utils.py, reached
    # from Runner#find_children). Real ansible-lint walks this graph
    # before linting, so imported task files, imported playbooks and role
    # content are linted *and* counted in the "on N files" summary;
    # without it krikri-lint silently skipped them and under-counted.
    #
    # Dynamic inclusions (a path containing `{{ }}`) are skipped, same as
    # upstream: they cannot be resolved statically.
    module Imports
      extend self

      INCLUSION_ACTIONS = %w[
        include include_tasks import_tasks
        ansible.builtin.include
        ansible.builtin.include_tasks
        ansible.builtin.import_tasks
      ]

      ROLE_IMPORT_ACTIONS = %w[
        include_role import_role
        ansible.builtin.include_role
        ansible.builtin.import_role
      ]

      PLAY_KEYS      = %w[import_playbook ansible.builtin.import_playbook]
      ROLE_LIST_KEYS = %w[roles dependencies]
      TASK_LIST_KEYS = %w[tasks pre_tasks post_tasks handlers block rescue always]

      # Upstream walks a role's well-known subdirectories only.
      ROLE_SUBDIRS = %w[tasks meta handlers vars defaults]

      private def self.home_dir : String
        ENV["HOME"]? || Dir.current
      end

      # Same candidate list as upstream's HandleChildren#_rolepath, in
      # order: relative to the including file first, then the standard
      # roles directories.
      private def self.role_candidates(basedir : String, role : String) : Array(String)
        [
          File.join(basedir, "roles", role),
          File.join(basedir, role),
          File.join(basedir, "..", "..", "..", "roles", role),
          File.join(basedir, "..", "..", role),
          File.join(basedir, "..", role),
          File.join("roles", role),
          File.join(home_dir, ".ansible", "roles", role),
          File.join("/etc", "ansible", "roles", role),
        ]
      end

      # Breadth-first closure over `paths`, each file appearing once, in
      # discovery order followed by the order its children were found.
      # Paths are reported relative to the working directory when they
      # live under it, the way upstream's Lintable normalizes them, so
      # both tools print the same file names.
      def self.expand(paths : Array(String)) : Array(String)
        seen = Set(String).new
        result = [] of String
        queue = paths.dup
        until queue.empty?
          raw = queue.shift
          next if raw.nil?
          # Normalize first: a discovered file is relative while an
          # import resolves to an absolute path, and both must collapse
          # onto the same entry or the file is linted and counted twice.
          path = relative(raw)
          next if seen.includes?(path)
          seen << path
          next unless File.exists?(path)
          result << path
          queue.concat(children(path))
        end
        result
      end

      # Relative to the working directory when under it, absolute
      # otherwise (upstream's Lintable keeps an outside-cwd path as-is).
      def self.relative(path : String) : String
        absolute = File.expand_path(path)
        cwd = File.expand_path(Dir.current)
        return absolute unless absolute.starts_with?(cwd + "/")
        absolute[(cwd.size + 1)..]
      end

      # Files reachable from one playbook or task file.
      def self.children(path : String) : Array(String)
        file = PositionedFile.load(path)
        return [] of String unless root = file.root
        # Only playbooks and task files are walked upstream; handlers,
        # vars and defaults files are leaves.
        return [] of String unless file.file_type.playbook? || file.file_type == FileType::TASKS

        found = [] of String
        walk(root, File.dirname(File.expand_path(path)), found)
        found.reject { |child| !File.exists?(child) }
      end

      private def self.walk(node : YAML::Nodes::Node, basedir : String, found : Array(String))
        case node
        when YAML::Nodes::Mapping
          NodeUtil.each_entry(node) { |key, value| dispatch(key, value, basedir, found) }
        when YAML::Nodes::Sequence
          node.nodes.each { |item| walk(item, basedir, found) }
        end
      end

      private def self.dispatch(key : YAML::Nodes::Node, value : YAML::Nodes::Node,
                                basedir : String, found : Array(String))
        name = NodeUtil.scalar_value(key) || return
        if TASK_LIST_KEYS.includes?(name)
          walk(value, basedir, found)
        elsif PLAY_KEYS.includes?(name)
          if (playbook = NodeUtil.scalar_value(value)) &&
             (playbook_path = resolve_playbook(basedir, playbook))
            found << playbook_path
          end
        elsif ROLE_LIST_KEYS.includes?(name)
          role_names(value).each { |role| found.concat(role_files(basedir, role)) }
        elsif INCLUSION_ACTIONS.includes?(name)
          if (included = include_file(value)) &&
             (included_path = resolve_include(basedir, included))
            found << included_path
          end
        elsif ROLE_IMPORT_ACTIONS.includes?(name)
          if (imported = imported_role_name(value))
            found.concat(role_files(basedir, imported))
          end
        end
      end

      # `import_role: {name: myrole}` names the role in a `name` key.
      private def self.imported_role_name(value : YAML::Nodes::Node) : String?
        return nil unless mapping = value.as?(YAML::Nodes::Mapping)
        return nil unless entry = NodeUtil.entry(mapping, "name")
        NodeUtil.scalar_value(entry[1])
      end

      # `include_tasks: file.yml` (scalar), `include_tasks: {file: file.yml}`
      # and the old `include: file.yml tags=nginx` form.
      private def self.include_file(value : YAML::Nodes::Node) : String?
        case value
        when YAML::Nodes::Scalar
          first_token(value.value)
        when YAML::Nodes::Mapping
          if (entry = NodeUtil.entry(value, "file"))
            NodeUtil.scalar_value(entry[1])
          end
        end
      end

      # Upstream drops trailing `key=value` tokens from the old include
      # syntax and skips anything templated.
      private def self.first_token(value : String) : String?
        return nil if value.empty? || value.includes?("{{")
        value.split(' ').each do |token|
          break if token.includes?("=")
          return token unless token.empty?
        end
        nil
      end

      # Mirrors upstream's include resolution: try the including file's
      # directory, then walk up towards the root.
      private def self.resolve_include(basedir : String, file : String) : String?
        dir = basedir
        loop do
          candidate = File.expand_path(file, dir)
          return candidate if File.exists?(candidate)
          break if dir == "/" || dir.empty?
          parent = File.dirname(dir)
          break if parent == dir
          dir = parent
        end
        nil
      end

      private def self.resolve_playbook(basedir : String, playbook : String) : String?
        # Collection playbooks (namespace.collection.playbook) belong to
        # another project; upstream does not lint them.
        return nil if playbook.count('.') >= 2
        return nil if playbook.includes?("{{")
        path = File.expand_path(playbook, basedir)
        File.exists?(path) ? path : nil
      end

      # A roles entry is a bare role name, or a mapping naming one.
      private def self.role_names(value : YAML::Nodes::Node) : Array(String)
        names = [] of String
        case value
        when YAML::Nodes::Scalar
          names << value.value
        when YAML::Nodes::Sequence
          value.nodes.each do |item|
            names.concat(role_names(item))
          end
        when YAML::Nodes::Mapping
          if (entry = NodeUtil.entry(value, "role") || NodeUtil.entry(value, "name"))
            names << NodeUtil.scalar_value(entry[1]).to_s
          end
        end
        names.reject(&.empty?)
      end

      private def self.role_files(basedir : String, role : String) : Array(String)
        return [] of String if role.empty? || role.includes?("{{")
        # `ns.coll.role` lives in a collection, which is not this
        # project's content; upstream skips those too.
        return [] of String if role.count('.') >= 2

        candidate = role_candidates(basedir, role).find { |dir| File.directory?(dir) }
        return [] of String unless candidate

        found = [] of String
        ROLE_SUBDIRS.each do |subdir|
          dir = File.join(candidate, subdir)
          next unless File.directory?(dir)
          Dir.glob(File.join(dir, "**", "*.{yml,yaml}")).sort.each do |file|
            found << File.expand_path(file)
          end
        end
        found
      end
    end
  end
end
