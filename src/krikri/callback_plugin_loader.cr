require "json"
require "./python_filter_runner"

module Krikri
  # Where Ansible's callback-plugin loader looks for a plugin FILE named in
  # ANSIBLE_CALLBACKS_ENABLED. Real ansible loads such a plugin and lets it
  # shape the run's reporting; this engine's display is hardcoded, so a
  # plugin found here is skipped rather than executed (issue #1473).
  # Resolving the file anyway is what keeps the warning honest: a callback
  # ansible would have loaded is reported as unexecutable here, while a
  # name nothing provides gets ansible's own "Skipping callback plugin
  # 'X', unable to load" (live-verified vs ansible-core 2.21.5).
  #
  # Ansible's paths, in order: every loaded directory's `callback_plugins/`
  # (the playbook's basedir and each role's own directory -
  # `add_all_plugin_dirs` from PlaybookCLI.run, Playbook.__init__ and
  # Role._load_role_data), then the configured roots
  # (ANSIBLE_CALLBACK_PLUGINS, which REPLACES the defaults
  # `$ANSIBLE_HOME/plugins/callback` and
  # `/usr/share/ansible/plugins/callback`), then a collection's
  # `plugins/callback/`. `ansible.legacy.<name>` is the same bare-name
  # search under its explicit prefix.
  module CallbackPluginLoader
    extend self

    SUBDIR        = "callback_plugins"
    ENV_VAR       = "ANSIBLE_CALLBACK_PLUGINS"
    LEGACY_PREFIX = "ansible.legacy."

    # The `.py` file ansible's callback loader would load for *name*, or nil
    # when no loader path carries it.
    def find_source(name : String, playbook_dir : String?) : String?
      return find_bare_source(name.lchop(LEGACY_PREFIX), playbook_dir) if name.starts_with?(LEGACY_PREFIX)

      parts = name.split('.')
      return find_collection_source(parts[0], parts[1], parts[2], playbook_dir) if parts.size == 3
      find_bare_source(name, playbook_dir)
    end

    private def find_bare_source(name : String, playbook_dir : String?) : String?
      bare_roots(playbook_dir).each do |root|
        candidate = File.join(root, "#{name}.py")
        return candidate if File.file?(candidate)
      end
      nil
    end

    private def find_collection_source(namespace : String, collection : String, name : String, playbook_dir : String?) : String?
      relative = File.join("ansible_collections", namespace, collection,
        "plugins", "callback", "#{name}.py")
      RoleLoader.collections_paths(playbook_dir || ".").each do |base|
        candidate = File.join(base, relative)
        return candidate if File.file?(candidate)
      end
      nil
    end

    private def bare_roots(playbook_dir : String?) : Array(String)
      roots = [] of String
      if dir = playbook_dir
        roots << File.join(dir, SUBDIR) unless dir.empty?
      end
      roots.concat(PythonFilterRunner.loaded_role_roots(SUBDIR))
      roots.concat(PythonFilterRunner.configured_roots("callback", ENV_VAR))
      roots
    end
  end
end
