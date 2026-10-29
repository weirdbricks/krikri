require "json"

# Runner for role-local CONTROLLER-side Python ACTION plugins - a role's
# own `action_plugins/<name>.py` dispatched when a task names the
# module the plugin shadows (gzm55.local_ssh_known_hosts, issue #519:
# the role ships `action_plugins/current_play_context_known_hosts.py`
# beside an empty `library/` placeholder, and Ansible resolves the
# action plugin first - `library/` never runs). Ansible instantiates
# the plugin's `ActionModule` with (task, connection, play_context,
# loader, templar) and its `run(task_vars=...)` return dict IS the
# task result - so `register:` sees e.g. the play context's
# connection/remote_addr/port straight out of the plugin's own return
# value, and its `changed`/`failed` verdicts are honoured.
#
# Like PythonLookupRunner, the runner delegates to the CONTROLLER's
# own python3 (the interpreter Ansible itself needs on the controller):
# a wrapper script is fed the plugin path plus the call as JSON on
# stdin, imports the real `ansible.plugins.action.ActionBase`, loads
# the plugin file, finds `ActionModule` and instantiates it with
# lightweight stub task/connection/play_context objects - real
# SimpleNamespaces carrying only what `ActionBase.__init__`/`run` and
# the play-context-reading plugins this scope covers touch
# (`_connection._shell.tmpdir` stays a non-None placeholder so
# `ActionBase.run` skips `_make_tmp_path`, which no
# TRANSFERS_FILES=False plugin reaches anyway). Loader/templar are
# None; a plugin needing real loader/templar services (e.g. calling
# `self._execute_module`) fails the task with its own exception
# instead - the same verdict Ansible would give a plugin that crashes,
# and out of scope for a stub runtime.
#
# No Python is embedded or reimplemented here; nothing runs unless the
# role's own `action_plugins/<name>.py` actually exists, and every
# failure (no python3, the `ansible` package not importable by the
# controller python3, a plugin syntax error, an exception inside
# `run`, a non-JSON-serializable result) degrades to the caller - which
# keeps the historical "not supported by krikri" failure for an
# unavailable mechanism and surfaces a dispatched plugin exception as
# the task's own failure message.
module Krikri
  module PythonActionRunner
    extend self

    # Raised when a dispatched action plugin fails after the file was
    # found (a Python exception inside `run`, no `ActionModule` in the
    # file, an unparseable wrapper response). Callers surface it as a
    # real task failure - it is never an "unsupported" condition.
    class ActionError < Exception
    end

    # Raised when the mechanism itself is unavailable on this
    # controller (no python3, or the `ansible` package - which the
    # plugin file imports at its top level - not importable): the
    # caller keeps the unchanged "not supported by krikri" failure.
    class ActionUnavailableError < ActionError
      getter kind : String

      def initialize(@kind : String, message : String)
        super(message)
      end

      def unavailable? : Bool
        kind == UNAVAILABLE_KIND
      end
    end

    UNAVAILABLE_KIND = "unavailable"

    # The CONTROLLER's own python3 - the interpreter Ansible needs on
    # the controller anyway (same detection pattern as
    # PythonLookupRunner#python_executable).
    def python_executable : String?
      Process.find_executable("python3") || Process.find_executable("python")
    end

    # Invokes the `ActionModule` from *source* with the substituted
    # task *args* (already typed: containers JSON-decoded, scalars
    # native) and the connection/play-context values Ansible's own
    # play_context carries for THIS task (remote_addr/port resolved
    # from the connection, port null when unset - ansible's
    # play_context.port is None there, verified against
    # ansible-playbook 2.19.11). Raises ActionUnavailableError when the
    # mechanism is unavailable, ActionError for a dispatched failure;
    # returns the plugin's result dict on success.
    def run_action(source : String, name : String, args : Hash(String, JSON::Any),
                   connection : String, remote_addr : String, port : Int32?,
                   remote_user : String?, become : Bool, become_user : String?,
                   check_mode : Bool, task_vars : Hash(String, JSON::Any)) : JSON::Any
      result = run_wrapper({
        "path"        => source,
        "name"        => name,
        "args"        => args,
        "connection"  => connection,
        "remote_addr" => remote_addr,
        "port"        => port,
        "remote_user" => remote_user,
        "become"      => become,
        "become_user" => become_user,
        "check_mode"  => check_mode,
        "task_vars"   => task_vars,
      })
      # A nil wrapper response means the wrapper itself never got to
      # speak (no python3, a crash outside its own top-level handler,
      # unparseable output) - the mechanism is unavailable, not the
      # plugin broken, same degradation as an unimportable `ansible`
      # package.
      raise ActionUnavailableError.new(UNAVAILABLE_KIND,
        "action plugin wrapper produced no result (is python3 available?)") unless result
      unless result["ok"]?.try(&.as_bool?)
        kind = result["kind"]?.try(&.as_s?) || "error"
        detail = result["error"]?.try(&.as_s?) || "unknown error"
        # Ansible words an import failure while loading the plugin file
        # as "failed to load", without the exception class name.
        message = case kind
                  when "load"
                    "The action plugin '#{name}' failed to load: #{detail}"
                  when "not_found"
                    "no ActionModule subclass of ActionBase in #{detail}"
                  else
                    "custom action plugin '#{name}' failed: #{detail}"
                  end
        raise kind == UNAVAILABLE_KIND ? ActionUnavailableError.new(kind, message) : ActionError.new(message)
      end
      result["result"]? || JSON::Any.new(nil)
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

      parsed = (JSON.parse(stdout.to_s.lines.reject(&.blank?).last? || "") rescue nil)
      return nil unless parsed && parsed.as_h?
      parsed
    rescue
      nil
    end

    # The controller-side wrapper: imports the plugin file, finds its
    # `ActionModule` class (required to subclass the real
    # `ansible.plugins.action.ActionBase`, exactly like Ansible's own
    # loader check), instantiates it with the stub task/connection/
    # play_context objects, and calls `run(task_vars=...)`, printing
    # the JSON-encoded result. Always responds with a single-line JSON
    # object ({"ok": true, ...} / {"ok": false, kind, error}), so a
    # plugin that prints its own noise cannot corrupt the protocol -
    # only the LAST line of stdout is parsed. An `ansible` package the
    # controller python3 cannot import reports kind "unavailable" (the
    # whole mechanism degrades; the plugin file could not have imported
    # its own base class either).
    WRAPPER = <<-PYTHON
      import importlib.util
      import json
      import sys
      import types


      _unavailable = None
      try:
          from ansible.plugins.action import ActionBase
      except Exception as exc:
          _unavailable = "%s: %s" % (type(exc).__name__, exc)


      def _load_plugin(path):
          modname = "krikri_action_%d" % hash(path)
          spec = importlib.util.spec_from_file_location(modname, path)
          if spec is None or spec.loader is None:
              raise ImportError("cannot load action plugin: %s" % path)
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
          try:
              module = _load_plugin(payload.get("path"))
          except ImportError as exc:
              sys.stdout.write(json.dumps(
                  {"ok": False, "kind": "load", "error": str(exc)}))
              return
          plugin_class = getattr(module, "ActionModule", None)
          if plugin_class is None or not isinstance(plugin_class, type) or \\
                  not issubclass(plugin_class, ActionBase):
              sys.stdout.write(json.dumps(
                  {"ok": False, "kind": "not_found",
                   "error": "no ActionModule subclass of ActionBase in %s"
                            % payload.get("path")}))
              return
          task = types.SimpleNamespace(
              args=payload.get("args") or {},
              action=payload.get("name"),
              async_val=0,
              check_mode=bool(payload.get("check_mode")),
              become=bool(payload.get("become")),
              become_user=payload.get("become_user"),
              diff=False,
              poll=0,
              no_log=False,
              environment=[],
              delegate_to=None,
          )
          # The non-None tmpdir placeholder keeps ActionBase.run's
          # `_connection._shell.tmpdir is None` early check from calling
          # _make_tmp_path - which would need a real connection shell.
          connection = types.SimpleNamespace(
              transport=payload.get("connection"),
              _shell=types.SimpleNamespace(tmpdir="/tmp/krikri-action-tmpdir"),
          )
          play_context = types.SimpleNamespace(
              connection=payload.get("connection"),
              remote_addr=payload.get("remote_addr"),
              port=payload.get("port"),
              remote_user=payload.get("remote_user"),
              become=bool(payload.get("become")),
              become_user=payload.get("become_user"),
              become_method=None,
              become_flags=None,
              check_mode=bool(payload.get("check_mode")),
              diff=False,
          )
          instance = plugin_class(task, connection, play_context, None, None)
          result = instance.run(task_vars=payload.get("task_vars") or {})
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
