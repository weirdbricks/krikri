require "json"

# Runner for role-local custom LOOKUP plugins - a role's own
# `lookup_plugins/*.py` (and the playbook-adjacent `lookup_plugins/`),
# the lookup-side twin of PythonFilterRunner's `filter_plugins/*.py`
# support. Real Ansible loads a role's own `lookup_plugins/` directory
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
# vanished from the run where real ansible-playbook executes it once
# per result item.
#
# Unlike a module, a lookup runs controller-side during Jinja2 template
# rendering - there is nothing to upload to a target. The runner
# instead delegates to the CONTROLLER's own python3 (the same
# interpreter real Ansible itself needs on the controller): a small
# wrapper script is fed the plugin source paths plus the call as JSON
# on stdin, imports the plugin file, finds its `LookupModule` class,
# instantiates it (real Ansible's own PluginLoader passes
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
# Deliberately scoped to role-private `lookup_plugins/` directories and
# the playbook-adjacent `lookup_plugins/` (real Ansible's two most
# common search roots, mirroring PythonFilterRunner#find_sources and
# PythonModuleRunner#find_source); third-party COLLECTION lookup
# plugins are still the unchanged scope cut - those live inside
# installed collections, not in the playbook tree this runner can see.
module Krikri
  module PythonLookupRunner
    extend self

    # Raised when a lookup invocation fails after the plugin was found
    # and dispatched (a Python exception inside `run`, an unparseable
    # wrapper response). Callers surface it as a real lookup failure
    # (real Ansible fails the task with the plugin's own error) - it is
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
    # one (nearest-first, same convention as
    # PythonFilterRunner#find_sources). Unlike filters - whose names
    # come from each FilterModule's `filters()` dict - real Ansible's
    # plugin loader derives a lookup plugin's name from its FILE NAME,
    # so no Python introspection (and no mtime cache) is needed here:
    # `lookup_plugins/manala_environment_files.py` IS the
    # `manala_environment_files` lookup, whatever class it declares.
    def find_source(name : String, role_path : String?, playbook_dir : String?) : String?
      [role_path, playbook_dir].each do |root|
        next unless root && !root.empty?
        path = File.join(root, "lookup_plugins", "#{name}.py")
        return path if File.file?(path)
      end
      nil
    end

    # The CONTROLLER's own python3 - the interpreter real Ansible needs
    # on the controller anyway (same detection pattern as
    # PythonFilterRunner#python_executable).
    def python_executable : String?
      Process.find_executable("python3") || Process.find_executable("python")
    end

    # Invokes the `LookupModule` from the plugin source for *name* with
    # the resolved *terms*/*kwargs* and the current task *variables*
    # (real Ansible passes its own vars dict, which conventionally
    # carries an `omit` key - see expression_evaluator's call site),
    # returning the structured result list. Raises LookupError when the
    # invocation fails (callers degrade to "undefined" only when the
    # mechanism itself is unavailable - a dispatched failure is a real
    # lookup error).
    def call_lookup(name : String, source : String, terms : Array(JSON::Any),
                    variables : Hash(String, JSON::Any), kwargs : Hash(String, JSON::Any)) : JSON::Any
      result = run_wrapper({
        "path"      => source,
        "name"      => name,
        "terms"     => terms,
        "variables" => variables,
        "kwargs"    => kwargs,
      })
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
        raise LookupUnavailableError.new(kind, "custom lookup '#{name}' failed: #{detail}")
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

    # The controller-side wrapper: imports the plugin file, finds its
    # `LookupModule` class (required to subclass the real
    # `ansible.plugins.lookup.LookupBase`, exactly like real Ansible's
    # own loader check), instantiates it with the base class's own
    # defaults, and calls `run(terms, variables=..., **kwargs)`,
    # printing the JSON-encoded result. Always responds with a
    # single-line JSON object ({"ok": true, ...} / {"ok": false, kind,
    # error}), so a plugin that prints its own noise cannot corrupt the
    # protocol - only the LAST line of stdout is parsed. An `ansible`
    # package the controller python3 cannot import reports kind
    # "unavailable" (the whole mechanism degrades; the plugin file
    # could not have imported its own base class either).
    WRAPPER = <<-PYTHON
      import importlib.util
      import json
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
          module = _load_plugin(payload.get("path"))
          plugin_class = getattr(module, "LookupModule", None)
          if plugin_class is None or not isinstance(plugin_class, type) or \\
                  not issubclass(plugin_class, LookupBase):
              sys.stdout.write(json.dumps(
                  {"ok": False, "kind": "not_found",
                   "error": "no LookupModule subclass of LookupBase in %s"
                            % payload.get("path")}))
              return
          instance = plugin_class()
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
