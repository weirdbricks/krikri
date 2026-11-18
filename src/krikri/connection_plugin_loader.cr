require "json"
require "./bigint_json"
require "./controller_python"
require "./python_filter_runner"

module Krikri
  # Where Ansible's connection-plugin loader looks for a plugin FILE, and
  # which of this engine's two transports that plugin's own class implies.
  #
  # A Python connection plugin cannot be executed here (its connection
  # lifecycle - _connect/exec_command/put_file/fetch_file - is the whole
  # transport layer this engine replaces with SSH or local execution), so
  # a plugin found on an Ansible loader path is resolved and then run with
  # the closest transport: a plugin whose class derives from Ansible's
  # own `local` connection executes on the controller like that base
  # class, every other plugin keeps the long-standing SSH approximation
  # that a resolvable-but-unported collection plugin
  # (containers.podman.podman) has always had. Without this, a plugin Ansible
  # happily loads made every host fail with the false "the connection
  # plugin 'X' was not found" (issue #1457).
  #
  # Ansible's paths, in order: every loaded directory's
  # `connection_plugins/` (the playbook's basedir and each role's own
  # directory - `add_all_plugin_dirs` from PlaybookCLI.run, Playbook.__init__
  # and Role._load_role_data), then the configured roots
  # (ANSIBLE_CONNECTION_PLUGINS, which REPLACES the defaults
  # `$ANSIBLE_HOME/plugins/connection` and
  # `/usr/share/ansible/plugins/connection`), then a collection's
  # `plugins/connection/`. `ansible.legacy.<name>` is the same bare-name
  # search under its explicit prefix (live-verified vs ansible-core 2.21.6:
  # `-c ansible.legacy.mylocal` runs a custom plugin from
  # ANSIBLE_CONNECTION_PLUGINS).
  module ConnectionPluginLoader
    extend self

    SUBDIR        = "connection_plugins"
    ENV_VAR       = "ANSIBLE_CONNECTION_PLUGINS"
    LEGACY_PREFIX = "ansible.legacy."

    # Keyed by expanded source path: a plugin file's own class hierarchy
    # cannot change mid-run (Ansible caches a loaded plugin the same way),
    # while the probe itself costs a controller-python spawn.
    @@local_cache = {} of String => Bool
    @@cache_mutex = Mutex.new

    # The `.py` file Ansible's connection loader would load for *name*, or
    # nil when no loader path carries it.
    def find_source(name : String, playbook_dir : String?) : String?
      return find_bare_source(name.lchop(LEGACY_PREFIX), playbook_dir) if name.starts_with?(LEGACY_PREFIX)

      parts = name.split('.')
      return find_collection_source(parts[0], parts[1], parts[2]) if parts.size == 3
      find_bare_source(name, playbook_dir)
    end

    private def find_bare_source(name : String, playbook_dir : String?) : String?
      bare_roots(playbook_dir).each do |root|
        candidate = File.join(root, "#{name}.py")
        return candidate if File.file?(candidate)
      end
      nil
    end

    private def find_collection_source(namespace : String, collection : String, name : String) : String?
      relative = File.join("ansible_collections", namespace, collection,
        "plugins", "connection", "#{name}.py")
      RoleLoader.collections_paths.each do |base|
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
      roots.concat(PythonFilterRunner.configured_roots("connection", ENV_VAR))
      roots
    end

    # Whether the plugin at *source* is a subclass of Ansible's `local`
    # connection. Anything else (and any probe that cannot run - no
    # ansible-capable controller python, a plugin the probe cannot import)
    # keeps the SSH approximation.
    def local_source?(source : String) : Bool
      path = File.expand_path(source)
      @@cache_mutex.synchronize do
        if cached = @@local_cache[path]?
          return cached
        end
      end
      verdict = probe(path)
      @@cache_mutex.synchronize { @@local_cache[path] = verdict }
      verdict
    end

    private def probe(path : String) : Bool
      captured = ControllerPython.run_wrapper(PythonFilterRunner.python_executable,
        PROBE, {"path" => path}.to_json)
      return false unless captured
      return false unless captured[:status].success?
      answer = captured[:stdout].lines.reverse_each.find { |line| !line.blank? }
      return false unless answer
      parsed = (Krikri::BigJson.parse(answer) rescue nil)
      hash = parsed.try(&.as_h?)
      return false unless hash
      hash["ok"]?.try(&.as_bool?) == true && hash["local"]?.try(&.as_bool?) == true
    rescue SpawnError
      false
    end

    # Imports the plugin FILE exactly as Ansible's loader would (its module
    # level code runs either way) and walks the class hierarchy. A probe
    # that cannot import ansible answers "unavailable" so the shared
    # controller-python retry tries the interpreter the user's own
    # ansible-playbook runs under (issue #778).
    PROBE = <<-'PYTHON'
      import importlib.util, json, sys
      def answer(**payload):
          sys.stdout.write(json.dumps(payload) + "\n")
          sys.exit(0)
      try:
          payload = json.loads(sys.stdin.read())
      except Exception:
          answer(ok=False, kind="probe_failed")
      try:
          from ansible.plugins.connection.local import Connection as LocalConnection
      except Exception:
          answer(ok=False, kind="unavailable")
      try:
          spec = importlib.util.spec_from_file_location("_krikri_connection_probe", payload["path"])
          module = importlib.util.module_from_spec(spec)
          sys.modules[spec.name] = module
          spec.loader.exec_module(module)
          cls = getattr(module, "Connection", None)
          answer(ok=True, local=bool(cls) and isinstance(cls, type) and issubclass(cls, LocalConnection))
      except Exception:
          answer(ok=False, kind="probe_failed")
      PYTHON
  end
end
