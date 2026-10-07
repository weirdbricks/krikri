require "json"

# Runner for role-local custom TEST plugins - a role's own
# `test_plugins/*.py` (and the playbook-adjacent `test_plugins/`),
# the test-side twin of PythonFilterRunner's `filter_plugins/*.py`
# support. Ansible loads a role's own `test_plugins/` directory on the
# CONTROLLER the same way it loads role-private `filter_plugins/`: a
# plugin file exposing a `TestModule` class whose `tests()` method
# returns the `{test_name: callable}` dict (e.g. Aisbergg.networkmanager's
# `list`, round 2300110 - its templates use `value is list`, which
# jinja2/ansible-core does NOT provide as a builtin test, so krikri
# hard-failed the render with "unknown test \"list\"" while
# ansible-playbook resolved and ran the role's own plugin).
#
# Delegates to the CONTROLLER's own python3 exactly like
# PythonFilterRunner: a wrapper script is fed the plugin source paths
# plus the test call as JSON on stdin, imports the plugin files,
# instantiates `TestModule`, calls `tests()`, and either reports the
# exposed names ("list") or invokes the requested test with the given
# arguments and prints the JSON-encoded result ("call"). Nothing runs
# unless a `test_plugins/*.py` source actually exists for the current
# role/playbook, and every failure (no python3, plugin syntax error, an
# exception inside the test, a non-JSON-serializable result) degrades to
# the caller - which falls back to the plain "No test named 'X'."
# UnknownTestError exactly as before, so roles WITHOUT custom test
# plugins behave bit-for-bit identically.
#
# Same scope cut as PythonFilterRunner: role-private `test_plugins/`
# directories and the playbook-adjacent `test_plugins/` only;
# third-party COLLECTION test plugins are still the unchanged scope cut.
module Krikri
  module PythonTestRunner
    extend self

    # Raised when a test invocation fails after the test was found and
    # dispatched (a Python exception inside the test, an unparseable
    # wrapper response). Callers surface it as the test's own failure -
    # never as an unknown-test condition.
    class TestError < Exception
    end

    # Finds every `.py` file under the role's own `test_plugins/` and
    # the playbook-adjacent `test_plugins/` (nearest-first order;
    # Ansible loads ALL files in a plugin directory, not name-matched
    # ones). Empty when neither root exists - the overwhelmingly common
    # case.
    def find_sources(role_path : String?, playbook_dir : String?) : Array(String)
      roots = [] of String
      roots << File.join(role_path, "test_plugins") if role_path && !role_path.empty?
      roots << File.join(playbook_dir, "test_plugins") if playbook_dir && !playbook_dir.empty?

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

    # Whether *name* is exposed by any of *sources*' TestModule classes.
    # Results are cached per source file (keyed by path, invalidated by
    # mtime) - the `when:` clause's compile-time test-name pre-pass can
    # ask this repeatedly for the same role.
    def defines_test?(name : String, sources : Array(String)) : Bool
      test_names(sources).includes?(name)
    end

    # The set of test names exposed across *sources*. A source file that
    # fails to introspect (syntax error, no python3, a `tests()` that
    # raises) contributes no names - never raises.
    def test_names(sources : Array(String)) : Set(String)
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

    # Invokes test *name* from *sources* with the Jinja operand *value*
    # and its resolved arguments, returning the structured result (the
    # caller decides truthiness - Ansible tests may return any Python
    # value, Jinja coerces it). Raises TestError when the test is not
    # found or the invocation fails (callers degrade to the plain
    # unknown-test error).
    def call_test(name : String, sources : Array(String), value : JSON::Any,
                  args : Array(JSON::Any), kwargs : Hash(String, JSON::Any),
                  vars : Hash(String, JSON::Any)? = nil) : JSON::Any
      result = run_wrapper({
        "action" => "call",
        "paths"  => sources,
        "name"   => name,
        "value"  => value,
        "args"   => args,
        "kwargs" => kwargs,
        "vars"   => vars,
      })
      raise TestError.new("test plugin wrapper produced no result (is python3 available?)") unless result
      unless result["ok"]?.try(&.as_bool?)
        detail = result["error"]?.try(&.as_s?) || "unknown error"
        raise TestError.new("custom test '#{name}' failed: #{detail}")
      end
      result["result"]? || JSON::Any.new(nil)
    end

    @@names_cache = Hash(String, {Int64, Set(String)}).new

    # Runs the wrapper script below against one request. Returns the
    # parsed response JSON, or nil on ANY failure (no python3, nonzero
    # exit, unparseable output) - callers treat nil as "not available".
    private def run_wrapper(payload) : JSON::Any?
      python = PythonFilterRunner.python_executable
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
    # every TestModule class's `tests()` dict, then either reports the
    # merged names ("list") or invokes the requested test with the
    # JSON-encoded operand and arguments ("call") and prints the
    # JSON-encoded result. Always responds with a single-line JSON
    # object, so a plugin that prints its own noise cannot corrupt the
    # protocol - only the LAST line of stdout is parsed.
    WRAPPER = <<-PYTHON
      import importlib.util
      import json
      import os
      import sys


      _loaded = []


      def _load_plugin(path):
          modname = "krikri_test_%d" % len(_loaded)
          spec = importlib.util.spec_from_file_location(modname, path)
          if spec is None or spec.loader is None:
              raise ImportError("cannot load test plugin: %s" % path)
          module = importlib.util.module_from_spec(spec)
          spec.loader.exec_module(module)
          _loaded.append(module)
          return module


      def _is_pass_context(func):
          # Same detection as the filter wrapper (jinja2 >= 3.0's
          # `jinja_pass_arg`, older `contextfilter`): a @pass_context
          # test gets a Context injected as its FIRST positional
          # argument by Jinja's own calling convention.
          arg = getattr(func, "jinja_pass_arg", None)
          if arg is not None and getattr(arg, "name", None) == "context":
              return True
          return bool(getattr(func, "contextfilter", False))


      class _StubContext(object):
          # Same minimal stand-in as the filter wrapper's: covers the
          # variable-lookup patterns custom tests actually use over the
          # play vars snapshot krikri passes in.
          def __init__(self, variables):
              self.vars = variables
              self.parent = variables
              self.environment = None

          def resolve(self, name, default=None):
              return self.vars.get(name, default)

          def get(self, key, default=None):
              return self.vars.get(key, default)

          def get_all(self):
              return self.vars

          def __getitem__(self, key):
              return self.vars[key]

          def __contains__(self, key):
              return key in self.vars


      def _plugin_tests(path):
          module = _load_plugin(path)
          plugin_dir = os.path.dirname(os.path.abspath(path))
          if plugin_dir not in sys.path:
              sys.path.insert(0, plugin_dir)
          plugin_class = getattr(module, "TestModule", None)
          if plugin_class is None:
              return {}
          # Ansible's own PluginLoader instantiates the plugin class
          # before calling tests() on the instance - a tests() defined
          # as a plain instance method (the common spelling) fails with
          # "missing self" when called on the class directly.
          tests = plugin_class().tests()
          if not isinstance(tests, dict):
              return {}
          return tests


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
              names.update(_plugin_tests(path))
          if payload.get("action") == "list":
              sys.stdout.write(json.dumps({"ok": True, "names": sorted(names)}))
              return
          name = payload.get("name")
          func = names.get(name)
          if func is None:
              sys.stdout.write(json.dumps(
                  {"ok": False, "kind": "not_found",
                   "error": "no test named %s in the given plugin files" % name}))
              return
          if _is_pass_context(func):
              call_args = [_StubContext(payload.get("vars") or {})]
          else:
              call_args = []
          call_args.append(payload.get("value"))
          call_args.extend(payload.get("args") or [])
          result = func(*call_args, **(payload.get("kwargs") or {}))
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
