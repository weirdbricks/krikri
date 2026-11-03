require "json"
require "./bigint_json"
require "./spawn_error"
require "./controller_python"

# Runner for role-local custom LOOKUP plugins - a role's own
# `lookup_plugins/*.py` (and the playbook-adjacent `lookup_plugins/`),
# the lookup-side twin of PythonFilterRunner's `filter_plugins/*.py`
# support. Ansible loads a role's own `lookup_plugins/` directory
# on the CONTROLLER the same way it loads role-private
# `filter_plugins/`: a plugin file exposing a `LookupModule` class
# subclassing `ansible.plugins.lookup.LookupBase`, whose `run(terms,
# variables, **kwargs)` method returns the result list (e.g.
# manala.environment's `manala_environment_files`,
# manala.accounts's `manala_accounts_users_authorized_keys`). Before
# this, `lookup('x', ...)`/`query('x', ...)` for such a name silently
# fell through ExpressionEvaluator's "undefined" fallback - which
# `evaluate_query` collapses to an empty list, so a
# `loop: "{{ query(...) }}"` iterated ZERO times and the whole task
# vanished from the run where ansible-playbook executes it once
# per result item.
#
# Unlike a module, a lookup runs controller-side during Jinja2 template
# rendering - there is nothing to upload to a target. The runner
# instead delegates to the CONTROLLER's own python3 (the same
# interpreter Ansible itself needs on the controller): a small
# wrapper script is fed the plugin source paths plus the call as JSON
# on stdin, imports the plugin file, finds its `LookupModule` class,
# instantiates it (Ansible's own PluginLoader passes
# loader/templar; every real-world plugin this scope covers only uses
# inherited `LookupBase` instance methods like `_flatten`, which
# `LookupBase.__init__` sets up fine with its own `loader=None,
# templar=None` defaults), and invokes `run` with the resolved terms/
# kwargs plus the current task vars as the `variables` dict - printed
# back as a JSON-encoded result. No Python is embedded or reimplemented
# here; nothing runs unless a `lookup_plugins/<name>.py` source actually
# exists for the current role/playbook, and every failure (no python3,
# the `ansible` package not importable by the controller python3, a
# plugin syntax error, an exception inside `run`, a non-JSON-serializable
# result) degrades to the caller - which returns "undefined" exactly as
# before, so roles WITHOUT custom lookup plugins (the overwhelming
# majority) behave bit-for-bit identically.
#
# Deliberately scoped to role-private `lookup_plugins/` directories,
# the playbook-adjacent `lookup_plugins/` and the `lookup_plugins/` of
# every role loaded this run (Ansible's most common search roots,
# mirroring PythonFilterRunner#find_sources and
# PythonModuleRunner#find_source); third-party COLLECTION lookup
# plugins are still the unchanged scope cut - those live inside
# installed collections, not in the playbook tree this runner can see.
module Krikri
  module PythonLookupRunner
    extend self

    # Raised when a lookup invocation fails after the plugin was found
    # and dispatched (a Python exception inside `run`, an unparseable
    # wrapper response). Callers surface it as a real lookup failure
    # (Ansible fails the task with the plugin's own error) - it is
    # never an "unknown lookup" condition.
    class LookupError < Exception
    end

    # The wrapper's response kind when the controller python3 cannot
    # import the `ansible` package at all - the plugin file itself
    # (which imports LookupBase at its top level) could never load
    # either, so the whole mechanism is unavailable and the caller
    # keeps the old "unknown lookup" behavior.
    UNAVAILABLE_KIND = "unavailable"

    # A `lookup_plugins/<name>.py` source for *name*, searched in the
    # role's own `lookup_plugins/` first, then the playbook-adjacent
    # one, then the lookup_plugins/ of every role LOADED this run
    # (Ansible's add_all_plugin_dirs at Role.load - a meta dependency's
    # lookup plugin stays reachable from the depending role's own
    # tasks, which is how gzm55.local_id_plugin's `id` served
    # gzm55.local_ssh_known_hosts, issue #519; same nearest-first
    # convention as PythonFilterRunner#find_sources), and finally
    # Ansible's CONFIGURED lookup directories (see configured_roots).
    # Unlike filters - whose names come from each FilterModule's
    # `filters()` dict - Ansible's plugin loader derives a lookup
    # plugin's name from its FILE NAME, so no Python introspection (and
    # no mtime cache) is needed here: `lookup_plugins/
    # manala_environment_files.py` IS the `manala_environment_files`
    # lookup, whatever class it declares.
    def find_source(name : String, role_path : String?, playbook_dir : String?) : String?
      [role_path, playbook_dir].each do |root|
        next unless root && !root.empty?
        path = File.join(root, "lookup_plugins", "#{name}.py")
        return path if File.file?(path)
      end
      PythonFilterRunner.loaded_role_roots("lookup_plugins").each do |root|
        path = File.join(root, "#{name}.py")
        return path if File.file?(path)
      end
      configured_roots.each do |root|
        path = File.join(root, "#{name}.py")
        return path if File.file?(path)
      end
      nil
    end

    # Ansible's configured lookup plugin directories, searched LAST (its
    # loader puts the role/playbook `_extra_dirs` ahead of the configured
    # paths). See PythonFilterRunner#configured_roots for the shared
    # ANSIBLE_<TYPE>_PLUGINS / ANSIBLE_HOME rules.
    def configured_roots : Array(String)
      PythonFilterRunner.configured_roots("lookup", "ANSIBLE_LOOKUP_PLUGINS")
    end

    # The CONTROLLER's own python3 - the interpreter Ansible needs
    # on the controller anyway (same detection pattern as
    # PythonFilterRunner#python_executable).
    def python_executable : String?
      ControllerPython.executable
    end

    # Where the spawn-failure warning goes - STDERR in production,
    # replaceable so a spec can capture the text without touching the
    # process's STDERR (same pattern as PythonFilterRunner's).
    class_property warning_sink : IO = STDERR

    # community.hashi_vault's lookup is not implemented, but ansible's
    # loader imports `hvac` before the lookup runs, so on a controller
    # python3 without it the task fails at load time with this message
    # (the host whose Python is named is the controller itself). With hvac
    # present ansible would go on to reach a Vault server, which krikri
    # cannot do either, so only the missing-library case is reproducible.
    def hashi_vault_load_failure(name : String?, python : String? = python_executable) : String?
      return nil unless name && name.in?("hashi_vault", "community.hashi_vault.hashi_vault")
      return nil unless python
      process = begin
        Krikri.simulated_python_spawn_failure
        Process.new(python, ["-c", "import hvac"],
          output: Process::Redirect::Close, error: Process::Redirect::Close)
      rescue File::Error
        # A vanished interpreter (the find_executable probe's answer went
        # stale) keeps the silent nil, matching LocalExecutor's #704
        # carve-out for a bad executable.
        return nil
      rescue ex
        # A spawn failure here used to be indistinguishable from "cannot
        # determine" and the lookup then failed as a plain "was not
        # found" - put the spawn error text on stderr so the real cause
        # shows in the run's log. The return value stays nil: the probe's
        # verdict is unchanged.
        raise SpawnError.new("Failed to spawn process: #{ex.message}")
      end
      status = process.wait
      return nil if status.success?
      "The lookup plugin '#{name}' failed to load: Failed to import the required Python library (hvac) on #{System.hostname}'s Python #{python}. Please read the module documentation and install it in the appropriate location. If the required library is installed, but Ansible is using the wrong Python interpreter, please consult the documentation on ansible_python_interpreter"
    rescue ex : SpawnError
      warning_sink.puts "[WARNING]: Lookup plugin '#{name}' availability probe failed: #{ex.message}"
      nil
    rescue File::Error
      nil
    rescue
      nil
    end

    # Invokes the `LookupModule` from the plugin source for *name* with
    # the resolved *terms*/*kwargs* and the current task *variables*
    # (Ansible passes its own vars dict, which conventionally
    # carries an `omit` key - see expression_evaluator's call site),
    # returning the structured result list. Raises LookupError when the
    # invocation fails (callers degrade to "undefined" only when the
    # mechanism itself is unavailable - a dispatched failure is a real
    # lookup error).
    def call_lookup(name : String, source : String, terms : Array(JSON::Any),
                    variables : Hash(String, JSON::Any), kwargs : Hash(String, JSON::Any)) : JSON::Any
      result = begin
        run_wrapper({
          "path"      => source,
          "name"      => name,
          "terms"     => terms,
          "variables" => variables,
          "kwargs"    => kwargs,
        })
      rescue ex : SpawnError
        # The wrapper never RAN - carry the spawn text into the error
        # instead of only "is python3 available?".
        raise LookupUnavailableError.new(UNAVAILABLE_KIND,
          "lookup plugin wrapper failed to spawn: #{ex.message}")
      end
      # A nil wrapper response means the wrapper itself never got to
      # speak (no python3, a crash outside its own top-level handler,
      # unparseable output) - the mechanism is unavailable, not the
      # plugin broken, so it is the same degradation as an unimportable
      # `ansible` package, never a hard task failure.
      raise LookupUnavailableError.new(UNAVAILABLE_KIND,
        "lookup plugin wrapper produced no result (is python3 available?)") unless result
      unless result["ok"]?.try(&.as_bool?)
        kind = result["kind"]?.try(&.as_s?) || "error"
        detail = result["error"]?.try(&.as_s?) || "unknown error"
        # Ansible words an import failure while loading the plugin file
        # as "failed to load", without the exception class name.
        message = kind == "load" ? "The lookup plugin '#{name}' failed to load: #{detail}" : "custom lookup '#{name}' failed: #{detail}"
        raise LookupUnavailableError.new(kind, message)
      end
      result["result"]? || JSON::Any.new(nil)
    end

    # Distinguishes "the mechanism is not available on this controller"
    # (kind: unavailable - the caller must keep the unchanged unknown-
    # lookup fallback) from a dispatched plugin failure (any other kind
    # - the caller surfaces the real error). Callers check `unavailable?`
    # rather than matching the kind string themselves.
    class LookupUnavailableError < LookupError
      getter kind : String

      def initialize(@kind : String, message : String)
        super(message)
      end

      # Whether no dispatch happened at all (the mechanism is absent on
      # this controller, or the file declares no LookupModule) - the
      # caller keeps its previous unknown-lookup behavior. False for
      # kind "error": the plugin RAN and raised, which is a real lookup
      # failure to surface, never an unknown-lookup condition.
      def unavailable? : Bool
        kind == UNAVAILABLE_KIND || kind == "not_found"
      end
    end

    # Runs the wrapper script below against one request. Returns the
    # parsed response JSON, nil when the wrapper RAN but did not answer
    # (nonzero exit, unparseable output, a post-spawn I/O failure), and
    # raises Krikri::SpawnError only when python3 could not be spawned
    # at all - LocalExecutor's #704 rule, so a wrapper that ran is never
    # reclassified as a spawn failure.
    private def run_wrapper(payload) : JSON::Any?
      # unquote_bigint_json: a bigint marker must reach the lookup as a
      # real Python int, the way Ansible passes its own int objects.
      # ControllerPython retries an interpreter that answered "ansible is
      # not importable" under the one ansible-playbook itself runs under
      # (issue #778: the plain python3 on PATH need not have ansible).
      captured = ControllerPython.run_wrapper(python_executable, WRAPPER,
        Krikri.unquote_bigint_json(payload.to_json))
      return nil unless captured
      return nil unless captured[:status].success?

      # BigJson, not JSON.parse: a lookup result with an integer wider
      # than Int64 made plain JSON.parse raise "Invalid Int64".
      parsed = (Krikri::BigJson.parse(captured[:stdout]) rescue nil)
      return nil unless parsed && parsed.as_h?
      parsed
    end

    # The controller-side wrapper: imports the plugin file, finds its
    # `LookupModule` class (required to subclass the real
    # `ansible.plugins.lookup.LookupBase`, exactly like Ansible's
    # own loader check), instantiates it with the loader/name Ansible's
    # own loader would give it, and calls `run(terms, variables=...,
    # **kwargs)`, printing the JSON-encoded result. Always responds with
    # a single-line JSON object ({"ok": true, ...} / {"ok": false, kind,
    # error}), so a plugin that prints its own noise cannot corrupt the
    # protocol - only the LAST line of stdout is parsed. An `ansible`
    # package the controller python3 cannot import reports kind
    # "unavailable" (the whole mechanism degrades; the plugin file
    # could not have imported its own base class either).
    #
    # Two pieces of Ansible's loader are reproduced here because real
    # plugins depend on them: the plugin's DOCUMENTATION options get
    # registered with ansible's config manager and its `_load_name` set
    # (PluginLoader._load_config_defs + the loader's own name), without
    # which `self.set_options()`/`self.get_option()` raises KeyError -
    # a very common plugin idiom; and the constructor receives a real
    # DataLoader, so `self._loader.path_dwim_relative(...)` (what
    # `find_file_in_search_path` is built on) works instead of dying on
    # `None`. `_templar` stays None, the one piece this wrapper cannot
    # fake. Both are best-effort: any failure leaves the plugin
    # instantiated exactly as before.
    WRAPPER = <<-PYTHON
      import importlib.util
      import json
      import os
      import sys


      _unavailable = None
      try:
          from ansible.plugins.lookup import LookupBase
      except Exception as exc:
          _unavailable = "%s: %s" % (type(exc).__name__, exc)


      def _load_plugin(path):
          modname = "krikri_lookup_%d" % hash(path)
          spec = importlib.util.spec_from_file_location(modname, path)
          if spec is None or spec.loader is None:
              raise ImportError("cannot load lookup plugin: %s" % path)
          module = importlib.util.module_from_spec(spec)
          spec.loader.exec_module(module)
          return module


      def _register_config(module, name):
          doc = getattr(module, "DOCUMENTATION", None)
          if not doc:
              return
          try:
              import yaml
              from ansible import constants as C
              from ansible.parsing.yaml.loader import AnsibleLoader
              parsed = yaml.load(doc, Loader=AnsibleLoader)
              if isinstance(parsed, dict) and isinstance(parsed.get("options"), dict):
                  C.config.initialize_plugin_configuration_definitions(
                      "lookup", name, parsed["options"])
          except Exception:
              pass


      def _instantiate(module, plugin_class, name):
          _register_config(module, name)
          try:
              from ansible.parsing.dataloader import DataLoader
              instance = plugin_class(loader=DataLoader())
          except Exception:
              instance = plugin_class()
          instance._load_name = name
          return instance


      def _serialize(value):
          if isinstance(value, (set, frozenset)):
              return list(value)
          if isinstance(value, bytes):
              return value.decode("utf-8", "replace")
          return str(value)


      def main():
          payload = json.loads(sys.stdin.read())
          if _unavailable is not None:
              sys.stdout.write(json.dumps(
                  {"ok": False, "kind": "unavailable",
                   "error": "ansible is not importable by the controller python3: %s"
                            % _unavailable}))
              return
          try:
              module = _load_plugin(payload.get("path"))
          except ImportError as exc:
              sys.stdout.write(json.dumps(
                  {"ok": False, "kind": "load", "error": str(exc)}))
              return
          plugin_class = getattr(module, "LookupModule", None)
          if plugin_class is None or not isinstance(plugin_class, type) or \\
                  not issubclass(plugin_class, LookupBase):
              sys.stdout.write(json.dumps(
                  {"ok": False, "kind": "not_found",
                   "error": "no LookupModule subclass of LookupBase in %s"
                            % payload.get("path")}))
              return
          instance = _instantiate(module, plugin_class,
                                  os.path.basename(payload.get("path")).rsplit(".", 1)[0])
          result = instance.run(payload.get("terms") or [],
                                variables=payload.get("variables") or {},
                                **(payload.get("kwargs") or {}))
          sys.stdout.write(json.dumps({"ok": True, "result": result},
                                      default=_serialize))


      try:
          main()
      # BaseException, not Exception: a plugin's `sys.exit()` raises
      # SystemExit, which would otherwise kill the wrapper before any
      # JSON response - reported as a kind "error" plugin failure here
      # rather than silently degrading the whole mechanism.
      except BaseException as exc:
          sys.stdout.write(json.dumps(
              {"ok": False, "kind": "error",
               "error": "%s: %s" % (type(exc).__name__, exc)}))
      PYTHON
  end
end
