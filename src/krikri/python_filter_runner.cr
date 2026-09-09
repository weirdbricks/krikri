require "json"

# Runner for role-local custom FILTER plugins - a role's own
# `filter_plugins/*.py` (and the playbook-adjacent `filter_plugins/`),
# the filter-side twin of PythonModuleRunner's `library/*.py` support
# (0.9.819). Real Ansible loads a role's own `filter_plugins/` directory
# on the CONTROLLER the same way it loads role-private modules: a plugin
# file exposing a `FilterModule` class whose `filters()` method returns
# the `{filter_name: callable}` dict (e.g. stackhpc.luks's `luks_key`,
# MichaelRigart.interfaces's `bond_check`). Before this, any task
# templating through such a filter hard-failed with "No filter named
# 'X'." where real ansible-playbook resolved and ran it.
#
# Unlike a module, a filter runs controller-side during Jinja2 template
# rendering - there is nothing to upload to a target. The runner instead
# delegates to the CONTROLLER's own python3 (the same interpreter real
# Ansible itself needs on the controller): a small wrapper script is fed
# the plugin source paths plus the filter call as JSON on stdin, imports
# the plugin files, instantiates `FilterModule`, calls `filters()`, and
# either reports the exposed names ("list") or invokes the requested
# filter with the given arguments and prints the JSON-encoded result
# ("call"). No Python is embedded or reimplemented here; nothing runs
# unless a `filter_plugins/*.py` source actually exists for the current
# role/playbook, and every failure (no python3, plugin syntax error, an
# exception inside the filter, a non-JSON-serializable result) degrades
# to the caller - which falls back to the plain "No filter named 'X'."
# UnknownFilterError exactly as before, so roles WITHOUT custom filter
# plugins (the overwhelming majority) behave bit-for-bit identically.
#
# Deliberately scoped to role-private `filter_plugins/` directories and
# the playbook-adjacent `filter_plugins/` (real Ansible's two most
# common search roots, mirroring PythonModuleRunner#find_source);
# third-party COLLECTION filter plugins (bodsch.*, community.*) are
# still the unchanged scope cut - those live inside installed
# collections, not in the playbook tree this runner can see.
module Krikri
  module PythonFilterRunner
    extend self

    # Raised when a filter invocation fails after the filter was found
    # and dispatched (a Python exception inside the filter, an
    # unparseable wrapper response). Callers either degrade to the
    # plain unknown-filter error or surface it as a task failure.
    class FilterError < Exception
    end

    # Finds every `.py` file under the role's own `filter_plugins/` and
    # the playbook-adjacent `filter_plugins/` (nearest-first order;
    # real Ansible loads ALL files in a plugin directory, not
    # name-matched ones, so there is no per-filter filename check here
    # the way a module's `library/<name>.py` lookup has). Empty when
    # neither root exists - the overwhelmingly common case.
    def find_sources(role_path : String?, playbook_dir : String?) : Array(String)
      roots = [] of String
      roots << File.join(role_path, "filter_plugins") if role_path && !role_path.empty?
      roots << File.join(playbook_dir, "filter_plugins") if playbook_dir && !playbook_dir.empty?

      sources = [] of String
      roots.each do |root|
        next unless Dir.exists?(root)
        Dir.each_child(root) do |entry|
          next unless entry.ends_with?(".py")
          path = File.join(root, entry)
          sources << path if File.file?(path)
        end
      end
      sources.uniq
    end

    # The CONTROLLER's own python3 - the interpreter real Ansible needs
    # on the controller anyway (same detection pattern facts_gatherer
    # uses for its controller-side needs).
    def python_executable : String?
      Process.find_executable("python3") || Process.find_executable("python")
    end

    # Whether *name* is exposed by any of *sources*' FilterModule
    # classes. Results are cached per source file (keyed by path,
    # invalidated by mtime) - a `when:` clause's compile-time filter
    # pre-pass can ask this repeatedly for the same role.
    def defines_filter?(name : String, sources : Array(String)) : Bool
      filter_names(sources).includes?(name)
    end

    # The set of filter names exposed across *sources*. A source file
    # that fails to introspect (syntax error, no python3, a
    # `filters()` that raises) contributes no names - never raises.
    def filter_names(sources : Array(String)) : Set(String)
      names = Set(String).new
      sources.each do |path|
        mtime = (File.info(path).modification_time.to_unix_ms rescue nil)
        next unless mtime

        if cached = @@names_cache[path]?
          if cached[0] == mtime
            cached[1].each { |cached_name| names << cached_name }
            next
          end
        end

        result = run_wrapper({
          "action" => "list",
          "paths"  => [path],
        })
        set = Set(String).new
        if result && result["ok"]?.try(&.as_bool?)
          result["names"]?.try(&.as_a?).try do |exposed|
            exposed.each { |exposed_name| set << exposed_name.to_s }
          end
        end
        @@names_cache[path] = {mtime, set}
        set.each { |set_name| names << set_name }
      end
      names
    end

    # Invokes filter *name* from *sources* with the Jinja operand
    # *value* and its resolved arguments, returning the structured
    # result. Raises FilterError when the filter is not found or the
    # invocation fails (callers degrade to the plain unknown-filter
    # error).
    def call_filter(name : String, sources : Array(String), value : JSON::Any,
                    args : Array(JSON::Any), kwargs : Hash(String, JSON::Any)) : JSON::Any
      result = run_wrapper({
        "action" => "call",
        "paths"  => sources,
        "name"   => name,
        "value"  => value,
        "args"   => args,
        "kwargs" => kwargs,
      })
      raise FilterError.new("filter plugin wrapper produced no result (is python3 available?)") unless result
      unless result["ok"]?.try(&.as_bool?)
        detail = result["error"]?.try(&.as_s?) || "unknown error"
        raise FilterError.new("custom filter '#{name}' failed: #{detail}")
      end
      result["result"]? || JSON::Any.new(nil)
    end

    @@names_cache = Hash(String, {Int64, Set(String)}).new

    # Runs the wrapper script below against one request. Returns the
    # parsed response JSON, or nil on ANY failure (no python3, nonzero
    # exit, unparseable output) - callers treat nil as "not available".
    private def run_wrapper(payload) : JSON::Any?
      python = python_executable
      return nil unless python

      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(python, ["-c", WRAPPER],
        input: IO::Memory.new(payload.to_json),
        output: stdout, error: stderr)
      return nil unless status.success?

      parsed = (JSON.parse(stdout.to_s) rescue nil)
      return nil unless parsed && parsed.as_h?
      parsed
    rescue
      nil
    end

    # The controller-side wrapper: imports each plugin file, merges
    # every FilterModule class's `filters()` dict, then either reports
    # the merged names ("list") or invokes the requested filter with
    # the JSON-encoded operand and arguments ("call") and prints the
    # JSON-encoded result. Always responds with a single-line JSON
    # object ({"ok": true, ...} / {"ok": false, kind, error}), so a
    # plugin that prints its own noise cannot corrupt the protocol -
    # only the LAST line of stdout is parsed.
    WRAPPER = <<-PYTHON
      import importlib.util
      import json
      import os
      import sys


      _loaded = []


      def _load_plugin(path):
          modname = "krikri_filter_%d" % len(_loaded)
          spec = importlib.util.spec_from_file_location(modname, path)
          if spec is None or spec.loader is None:
              raise ImportError("cannot load filter plugin: %s" % path)
          module = importlib.util.module_from_spec(spec)
          spec.loader.exec_module(module)
          _loaded.append(module)
          return module


      def _plugin_filters(path):
          module = _load_plugin(path)
          plugin_dir = os.path.dirname(os.path.abspath(path))
          if plugin_dir not in sys.path:
              sys.path.insert(0, plugin_dir)
          plugin_class = getattr(module, "FilterModule", None)
          if plugin_class is None:
              return {}
          # Real Ansible's own PluginLoader instantiates the plugin
          # class before calling filters() on the instance - a
          # filters() defined as a plain instance method (the common
          # spelling) fails with "missing self" when called on the
          # class directly.
          filters = plugin_class().filters()
          if not isinstance(filters, dict):
              return {}
          return filters


      def _serialize(value):
          if isinstance(value, (set, frozenset)):
              return list(value)
          if isinstance(value, bytes):
              return value.decode("utf-8", "replace")
          return str(value)


      def main():
          payload = json.loads(sys.stdin.read())
          names = {}
          for path in payload.get("paths", []):
              names.update(_plugin_filters(path))
          if payload.get("action") == "list":
              sys.stdout.write(json.dumps({"ok": True, "names": sorted(names)}))
              return
          name = payload.get("name")
          func = names.get(name)
          if func is None:
              sys.stdout.write(json.dumps(
                  {"ok": False, "kind": "not_found",
                   "error": "no filter named %s in the given plugin files" % name}))
              return
          result = func(payload.get("value"), *(payload.get("args") or []),
                        **(payload.get("kwargs") or {}))
          sys.stdout.write(json.dumps({"ok": True, "result": result}, default=_serialize))


      try:
          main()
      except Exception as exc:
          sys.stdout.write(json.dumps(
              {"ok": False, "kind": "error",
               "error": "%s: %s" % (type(exc).__name__, exc)}))
      PYTHON
  end
end
