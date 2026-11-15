module Krikri
  module Lint
    # Play `roles:` entries ansible cannot resolve when it loads a
    # playbook. `ansible-playbook --syntax-check` aborts at the first one
    # with "The role 'x' was not found in: <search paths>", which
    # ansible-lint reports as syntax-check[specific] at the entry itself.
    #
    # The search order is ansible's own: the playbook's roles/ directory,
    # then roles_path, then the playbook's directory. ansible-lint runs
    # the check with ANSIBLE_ROLES_PATH pointing at the project's
    # .ansible/roles followed by ansible's defaults, so an unset variable
    # falls back to that same list (verified against ansible-lint 25.2.1).
    module RoleLookup
      extend self

      struct Missing
        getter name : String
        getter line : Int32
        getter column : Int32
        getter search_paths : Array(String)

        def initialize(@name, @line, @column, @search_paths)
        end

        # ansible's own wording, minus the Origin/offending-line block
        # ansible-lint parses with it.
        def message : String
          "The role '#{name}' was not found in: #{search_paths.join(':')}"
        end
      end

      # The first unresolvable role in load order, or nil. Plays load in
      # file order and ansible stops at the first missing role.
      def first_missing(file : PositionedFile) : Missing?
        root = file.root.as?(YAML::Nodes::Sequence) || return nil
        basedir = File.dirname(File.expand_path(file.path))
        paths = search_paths(basedir)
        root.nodes.each do |play|
          play = play.as?(YAML::Nodes::Mapping) || next
          entry = NodeUtil.entry(play, "roles") || next
          roles = entry[1].as?(YAML::Nodes::Sequence) || next
          roles.nodes.each do |item|
            name, position = role_entry(item)
            next if name.nil? || skip_name?(name)
            next if found?(name, paths)
            return Missing.new(name, NodeUtil.line(position), NodeUtil.column(position), paths)
          end
        end
        nil
      end

      # A `roles:` item is a bare role name or a mapping naming one; the
      # position ansible reports is the item's first token (the scalar,
      # or the mapping's first key).
      private def role_entry(item : YAML::Nodes::Node) : {String?, YAML::Nodes::Node}
        case item
        when YAML::Nodes::Scalar
          {item.value, item}
        when YAML::Nodes::Mapping
          if entry = NodeUtil.entry(item, "role") || NodeUtil.entry(item, "name")
            {NodeUtil.scalar_value(entry[1]), entry[0]}
          else
            {nil, item}
          end
        else
          {nil, item}
        end
      end

      # Names this lookup must not judge: an empty entry, a templated one
      # (resolved only at run time), and an `ns.coll.role` (owned by a
      # collection, which is not this project's content).
      private def skip_name?(name : String) : Bool
        name.empty? || name.includes?("{{") || name.count('.') >= 2
      end

      private def found?(name : String, paths : Array(String)) : Bool
        paths.any? { |path| File.directory?(File.expand_path(name, path)) }
      end

      private def search_paths(basedir : String) : Array(String)
        candidates = [File.join(basedir, "roles")]
        candidates.concat(roles_path)
        candidates << basedir
        seen = Set(String).new
        candidates.compact_map do |path|
          absolute = File.expand_path(path)
          absolute if seen.add?(absolute)
        end
      end

      private def roles_path : Array(String)
        value = ENV["ANSIBLE_ROLES_PATH"]?
        if value && !value.empty?
          return value.split(':', remove_empty: true)
        end
        home = ENV["HOME"]? || return ["/usr/share/ansible/roles", "/etc/ansible/roles"]
        [
          File.join(Dir.current, ".ansible", "roles"),
          File.join(home, ".ansible", "roles"),
          "/usr/share/ansible/roles",
          "/etc/ansible/roles",
        ]
      end
    end
  end
end
