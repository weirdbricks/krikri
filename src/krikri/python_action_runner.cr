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
# None. A plugin that calls `self._execute_module` (agaffney.synology_dsm's
# synology_dsm_api_request delegates to `uri`, issue #399) is answered
# through the engine's OWN module dispatch - the caller's ModuleDispatcher
# - over a line-JSON request/reply channel on the wrapper's stdio; without
# a dispatcher such a plugin still fails with its own exception, the same
# verdict Ansible would give a plugin that crashes.
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
    #
    # `detail` is set only for the TASK_FAILED kind: the plugin raised
    # AnsibleError itself, which Ansible's task executor turns into the
    # task's own failure with the bare exception text in the [ERROR]
    # block and "Task failed: <text>" as the fatal msg (issue #411, on
    # amtega.check_platform's `_check_platform` - live-verified vs
    # 2.19.11). Callers render that shape from detail; a plain runner
    # crash keeps detail nil and surfaces this exception's message.
    class ActionError < Exception
      getter detail : String?

      def initialize(message : String, @detail : String? = nil)
        super(message)
      end
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
    # The dispatched plugin raised AnsibleError inside run() - Ansible's
    # own "this task failed" signal, not a runner crash (see ActionError
    # #detail).
    TASK_FAILED_KIND = "task_failed"

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
    #
    # `dispatcher`, when given, answers the plugin's
    # `self._execute_module(...)` calls through the engine's own module
    # dispatch (see run_wrapper_ipc); without it such a plugin still
    # fails with its own exception, the pre-existing stub behavior.
    def run_action(source : String, name : String, args : Hash(String, JSON::Any),
                   connection : String, remote_addr : String, port : Int32?,
                   remote_user : String?, become : Bool, become_user : String?,
                   check_mode : Bool, task_vars : Hash(String, JSON::Any),
                   dispatcher : ModuleDispatcher? = nil) : JSON::Any
      payload = action_payload(source, name, args, connection, remote_addr, port,
        remote_user, become, become_user, check_mode, task_vars)
      payload["ipc"] = JSON::Any.new(true) if dispatcher
      # A nil wrapper response means the wrapper itself never got to
      # speak (no python3, a crash outside its own top-level handler,
      # unparseable output) - the mechanism is unavailable, not the
      # plugin broken, same degradation as an unimportable `ansible`
      # package.
      result = dispatcher ? run_wrapper_ipc(payload, dispatcher) : run_wrapper(payload)
      raise ActionUnavailableError.new(UNAVAILABLE_KIND,
        "action plugin wrapper produced no result (is python3 available?)") unless result
      if failure = interpretable_failure?(result)
        raise wrapper_failure(name, failure[0], failure[1])
      end
      result["result"]? || JSON::Any.new(nil)
    end

    private def action_payload(source : String, name : String, args : Hash(String, JSON::Any),
                               connection : String, remote_addr : String, port : Int32?,
                               remote_user : String?, become : Bool, become_user : String?,
                               check_mode : Bool, task_vars : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
      {
        "path"        => JSON::Any.new(source),
        "name"        => JSON::Any.new(name),
        "args"        => JSON::Any.new(args),
        "connection"  => JSON::Any.new(connection),
        "remote_addr" => JSON::Any.new(remote_addr),
        "port"        => port.nil? ? JSON::Any.new(nil) : JSON::Any.new(port),
        "remote_user" => remote_user.nil? ? JSON::Any.new(nil) : JSON::Any.new(remote_user),
        "become"      => JSON::Any.new(become),
        "become_user" => become_user.nil? ? JSON::Any.new(nil) : JSON::Any.new(become_user),
        "check_mode"  => JSON::Any.new(check_mode),
        "task_vars"   => JSON::Any.new(task_vars),
      } of String => JSON::Any
    end

    # {kind, detail} of a wrapper response that reports a failure, or nil
    # when the plugin succeeded (its result dict is then the task result).
    private def interpretable_failure?(result : JSON::Any) : {String, String}?
      return nil if result["ok"]?.try(&.as_bool?)
      kind = result["kind"]?.try(&.as_s?) || "error"
      detail = result["error"]?.try(&.as_s?) || "unknown error"
      {kind, detail}
    end

    private def wrapper_failure(name : String, kind : String, detail : String) : ActionError
      return ActionError.new("Task failed: #{detail}", detail) if kind == TASK_FAILED_KIND
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
      kind == UNAVAILABLE_KIND ? ActionUnavailableError.new(kind, message) : ActionError.new(message)
    end

    # Runs one plugin `self._execute_module` request: the engine executes
    # the named module on the task's target exactly as a direct task of
    # it would, and the module's result dict is the reply. An error
    # (a module krikri cannot run, a dispatch failure) comes back as the
    # `error` text, which the wrapper raises as an AnsibleError - the
    # same verdict the plugin sees from ansible's own machinery when the
    # inner module itself fails to load or run.
    alias ModuleDispatcher = Proc(String, Hash(String, JSON::Any), JSON::Any)

    # Runs the wrapper script below against one request. Returns the
    # parsed response JSON, or nil on ANY failure (no python3, nonzero
    # exit, unparseable output) - callers treat nil as "not available".
    private def run_wrapper(payload : Hash(String, JSON::Any)) : JSON::Any?
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

    # The interactive counterpart of run_wrapper: the wrapper stays
    # alive and asks the engine to dispatch a module whenever the plugin
    # calls `self._execute_module`, answering it on stdin. Every protocol
    # line carries the "__krikri__" marker, so plugin noise printed to
    # stdout is skipped, and the wrapper's own final response ends the
    # loop. STDERR is closed rather than buffered: the wrapper reports
    # every outcome through the protocol, and an unread pipe could
    # otherwise deadlock a chatty plugin.
    private def run_wrapper_ipc(payload : Hash(String, JSON::Any), dispatcher : ModuleDispatcher) : JSON::Any?
      python = python_executable
      return nil unless python

      process = Process.new(python, ["-c", WRAPPER],
        input: Process::Redirect::Pipe, output: Process::Redirect::Pipe,
        error: Process::Redirect::Close)
      begin
        input = process.input.as(IO)
        input.puts(payload.to_json)
        input.flush
        while (line = process.output.gets)
          parsed = (JSON.parse(line) rescue nil)
          obj = parsed.try(&.as_h?)
          next unless obj && obj["__krikri__"]?.try(&.as_bool?) == true
          if obj["type"]?.try(&.as_s?) == "execute_module"
            input.puts(ipc_dispatch_reply(obj, dispatcher))
            input.flush
          else
            return parsed
          end
        end
        nil
      rescue
        nil
      ensure
        begin
          process.input.as(IO).close
        rescue
        end
        process.close
      end
    end

    private def ipc_dispatch_reply(request : Hash(String, JSON::Any), dispatcher : ModuleDispatcher) : String
      module_name = request["module"]?.try(&.as_s?) || ""
      module_args = request["args"]?.try(&.as_h?) || Hash(String, JSON::Any).new
      reply = begin
        {"result" => dispatcher.call(module_name, module_args)}
      rescue ex
        {"error" => JSON::Any.new(ex.message.to_s)}
      end
      ({"__krikri__" => JSON::Any.new(true)}.merge(reply)).to_json
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
    WRAPPER = <<-'PYTHON'
      import importlib.util
      import json
      import sys
      import types


      _unavailable = None
      try:
          from ansible.plugins.action import ActionBase
          from ansible.errors import AnsibleError
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


      class _PassthroughTemplar(object):
          # Krikri hands the plugin task_vars as plain values (the
          # executor's own var context); Ansible would template them
          # again here, which is a no-op for the literal data the
          # supported plugins read (amtega.check_platform's
          # check_platform_distributions dict and friends, issue #411).
          # A plugin needing REAL templating gets its value untouched
          # and fails like a plugin crashing in Ansible would.

          def template(self, variable, **kwargs):
              return variable


      def _emit(obj):
          # One protocol line: JSON with the marker that tells the engine
          # this is the wrapper speaking, not plugin noise on stdout.
          obj = dict(obj)
          obj["__krikri__"] = True
          sys.stdout.write(json.dumps(obj, default=_serialize) + "\n")
          sys.stdout.flush()


      def _ipc_execute_module(self, module_name=None, module_args=None, **kwargs):
          # Ansible's real _execute_module transfers and runs a module
          # over a live connection - impossible on this stub runtime, so
          # the engine runs the named module instead (its own dispatch,
          # the task's host/connection/become) and the plugin gets back
          # the module's result dict. agaffney.synology_dsm's
          # synology_dsm_api_request builds 'uri' params and delegates
          # exactly this way, and the uri result IS the task result
          # (issue #399 - live-verified vs 2.19.11).
          name = module_name or self._task.action
          args = module_args if module_args is not None else dict(self._task.args)
          _emit({"type": "execute_module", "module": name, "args": args})
          while True:
              line = sys.stdin.readline()
              if line == "":
                  raise AnsibleError("krikri action dispatch channel closed")
              try:
                  msg = json.loads(line)
              except ValueError:
                  continue
              if not isinstance(msg, dict) or not msg.get("__krikri__"):
                  continue
              if msg.get("error") is not None:
                  raise AnsibleError(msg["error"])
              result = msg.get("result")
              return result if result is not None else {}


      def _ipc_remove_tmp_path(self, tmp_path=None, force=False):
          # The real method deletes the tmp dir over the connection shell;
          # krikri's inner dispatch manages the tmp dirs of the modules it
          # runs, so this is a no-op here rather than a crash on the stub
          # connection (a plugin that cleans up after _execute_module -
          # synology_dsm_api_request does - would otherwise die in
          # _low_level_execute_command).
          return None


      def main():
          payload = json.loads(sys.stdin.readline())
          if _unavailable is not None:
              _emit({"ok": False, "kind": "unavailable",
                     "error": "ansible is not importable by the controller python3: %s"
                              % _unavailable})
              return
          try:
              module = _load_plugin(payload.get("path"))
          except ImportError as exc:
              _emit({"ok": False, "kind": "load", "error": str(exc)})
              return
          plugin_class = getattr(module, "ActionModule", None)
          if plugin_class is None or not isinstance(plugin_class, type) or \
                  not issubclass(plugin_class, ActionBase):
              _emit({"ok": False, "kind": "not_found",
                     "error": "no ActionModule subclass of ActionBase in %s"
                              % payload.get("path")})
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
          instance = plugin_class(task, connection, play_context, None, _PassthroughTemplar())
          if payload.get("ipc"):
              instance._execute_module = types.MethodType(_ipc_execute_module, instance)
              instance._remove_tmp_path = types.MethodType(_ipc_remove_tmp_path, instance)
          try:
              result = instance.run(task_vars=payload.get("task_vars") or {})
          except AnsibleError as exc:
              # An AnsibleError raised by the plugin itself IS the task's
              # failure (Ansible's task executor reports it as the plain
              # action-level "Task failed: <text>" shape, live-verified vs
              # 2.19.11) - report the bare text under its own kind, not
              # the class-name-prefixed runner-crash shape.
              _emit({"ok": False, "kind": "task_failed", "error": "%s" % exc})
              return
          _emit({"ok": True, "result": result})


      try:
          main()
      # BaseException, not Exception: a plugin's `sys.exit()` raises
      # SystemExit, which would otherwise kill the wrapper before any
      # JSON response - reported as a kind "error" plugin failure here
      # rather than silently degrading the whole mechanism.
      except BaseException as exc:
          _emit({"ok": False, "kind": "error",
                 "error": "%s: %s" % (type(exc).__name__, exc)})
      PYTHON
  end
end
