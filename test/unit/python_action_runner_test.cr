require "../minitest_helper"
require "file_utils"
require "../../src/krikri/python_action_runner"

# Role-local controller-side Python action plugin dispatch - see
# PythonActionRunner for the mechanism (delegates to the controller's
# own python3; a dispatched failure raises ActionError with the plugin's
# own error, an unavailable mechanism raises ActionUnavailableError).
#
# The dispatch specs here require the controller python3 to import the
# `ansible` package (the plugin file itself imports ActionBase at its
# top level). On a controller without it, every dispatch degrades to
# kind "unavailable" - those cases assert exactly that degradation
# rather than skipping, so the suite is green either way.
private def ansible_importable : Bool
  python = Krikri::PythonActionRunner.python_executable
  return false unless python
  status = Process.run(python, ["-c", "from ansible.plugins.action import ActionBase"],
    output: Process::Redirect::Close, error: Process::Redirect::Close)
  status.success?
end

private def write_action_plugin(dir : String, name : String, content : String) : String
  plugin_dir = File.join(dir, "action_plugins")
  Dir.mkdir_p(plugin_dir)
  path = File.join(plugin_dir, name)
  File.write(path, content)
  path
end

private def run_plugin(path : String, name : String = "myaction", args : Hash(String, JSON::Any) = Hash(String, JSON::Any).new,
                       connection : String = "local", remote_addr : String = "localhost",
                       port : Int32? = nil, check_mode : Bool = false,
                       task_vars : Hash(String, JSON::Any) = Hash(String, JSON::Any).new) : JSON::Any
  Krikri::PythonActionRunner.run_action(path, name, args, connection, remote_addr, port,
    nil, false, nil, check_mode, task_vars)
end

private def assert_unavailable(call : -> JSON::Any) : Nil
  begin
    call.call
    raise Minitest::Assertion.new("expected ActionUnavailableError")
  rescue e : Krikri::PythonActionRunner::ActionUnavailableError
    e.unavailable?.must_equal(true)
  end
end

describe Krikri::PythonActionRunner do
  it "returns the plugin's result dict echoing the play context" do
    dir = File.join(Dir.tempdir, "krikri-pyaction-spec-#{Random.rand(1_000_000)}")
    path = write_action_plugin(dir, "myaction.py", <<-PYTHON)
      from ansible.plugins.action import ActionBase

      class ActionModule(ActionBase):
          TRANSFERS_FILES = False

          def run(self, tmp=None, task_vars=None):
              result = super(ActionModule, self).run(tmp, task_vars)
              del tmp
              ctx = self._play_context
              result['connection'] = ctx.connection
              result['remote_addr'] = ctx.remote_addr
              result['port'] = ctx.port
              result['changed'] = False
              return result
      PYTHON

    begin
      call = -> { run_plugin(path) }
      if ansible_importable
        result = call.call
        result.as_h["connection"].as_s.must_equal("local")
        result.as_h["remote_addr"].as_s.must_equal("localhost")
        result.as_h["port"].raw.must_be_nil
        result.as_h["changed"].as_bool.must_equal(false)
      else
        assert_unavailable(call)
      end
    ensure
      FileUtils.rm_r(dir)
    end
  end

  it "passes typed task args and task_vars through to the plugin" do
    dir = File.join(Dir.tempdir, "krikri-pyaction-spec-#{Random.rand(1_000_000)}")
    path = write_action_plugin(dir, "myaction.py", <<-PYTHON)
      from ansible.plugins.action import ActionBase

      class ActionModule(ActionBase):
          TRANSFERS_FILES = False

          def run(self, tmp=None, task_vars=None):
              result = super(ActionModule, self).run(tmp, task_vars)
              del tmp
              result['args_kind'] = type(self._task.args['items']).__name__
              result['arg_value'] = self._task.args['items']
              result['tv'] = task_vars.get('myvar')
              return result
      PYTHON

    begin
      args = {"items" => JSON.parse("[1, 2]")} of String => JSON::Any
      task_vars = {"myvar" => JSON::Any.new("hello")} of String => JSON::Any
      call = -> { run_plugin(path, args: args, task_vars: task_vars) }
      if ansible_importable
        result = call.call
        result.as_h["args_kind"].as_s.must_equal("list")
        result.as_h["arg_value"].as_a.map(&.as_i).must_equal([1, 2])
        result.as_h["tv"].as_s.must_equal("hello")
      else
        assert_unavailable(call)
      end
    ensure
      FileUtils.rm_r(dir)
    end
  end

  it "honours an explicit port and check_mode in the play context" do
    dir = File.join(Dir.tempdir, "krikri-pyaction-spec-#{Random.rand(1_000_000)}")
    path = write_action_plugin(dir, "myaction.py", <<-PYTHON)
      from ansible.plugins.action import ActionBase

      class ActionModule(ActionBase):
          TRANSFERS_FILES = False

          def run(self, tmp=None, task_vars=None):
              result = super(ActionModule, self).run(tmp, task_vars)
              del tmp
              ctx = self._play_context
              result['port'] = ctx.port
              result['check_mode'] = ctx.check_mode
              return result
      PYTHON

    begin
      call = -> { run_plugin(path, port: 2222, check_mode: true) }
      if ansible_importable
        result = call.call
        result.as_h["port"].as_i.must_equal(2222)
        result.as_h["check_mode"].as_bool.must_equal(true)
      else
        assert_unavailable(call)
      end
    ensure
      FileUtils.rm_r(dir)
    end
  end

  it "raises ActionError with the plugin's own exception text" do
    dir = File.join(Dir.tempdir, "krikri-pyaction-spec-#{Random.rand(1_000_000)}")
    path = write_action_plugin(dir, "myaction.py", <<-PYTHON)
      from ansible.plugins.action import ActionBase

      class ActionModule(ActionBase):
          TRANSFERS_FILES = False

          def run(self, tmp=None, task_vars=None):
              raise Exception("boom from action spec")
      PYTHON

    begin
      call = -> { run_plugin(path) }
      if ansible_importable
        failed = false
        begin
          call.call
        rescue ex : Krikri::PythonActionRunner::ActionError
          failed = true
          ex.message.to_s.must_include("boom from action spec")
        end
        failed.must_equal(true)
      else
        assert_unavailable(call)
      end
    ensure
      FileUtils.rm_r(dir)
    end
  end

  it "raises ActionError when the file declares no ActionModule" do
    dir = File.join(Dir.tempdir, "krikri-pyaction-spec-#{Random.rand(1_000_000)}")
    path = write_action_plugin(dir, "myaction.py", "x = 1\n")

    begin
      call = -> { run_plugin(path) }
      if ansible_importable
        failed = false
        begin
          call.call
        rescue ex : Krikri::PythonActionRunner::ActionError
          failed = ex.message.to_s.includes?("no ActionModule")
        end
        failed.must_equal(true)
      else
        assert_unavailable(call)
      end
    ensure
      FileUtils.rm_r(dir)
    end
  end

  it "reports an unavailable mechanism without importing the plugin" do
    dir = File.join(Dir.tempdir, "krikri-pyaction-spec-#{Random.rand(1_000_000)}")
    path = write_action_plugin(dir, "myaction.py", "x = 1\n")

    begin
      call = -> { run_plugin(path) }
      unless ansible_importable
        assert_unavailable(call)
      end
    ensure
      FileUtils.rm_r(dir)
    end
  end

  it "answers the plugin's _execute_module through the engine dispatcher" do
    # agaffney.synology_dsm's synology_dsm_api_request builds 'uri' params
    # and delegates to self._execute_module, whose result dict IS the
    # task's own result (issue #399). The stub runtime cannot run ansible's
    # real module-transfer machinery, so the wrapper relays the call to the
    # caller's dispatcher and the module's result comes back verbatim.
    dir = File.join(Dir.tempdir, "krikri-pyaction-spec-#{Random.rand(1_000_000)}")
    path = write_action_plugin(dir, "myaction.py", <<-PYTHON)
      from ansible.plugins.action import ActionBase

      class ActionModule(ActionBase):
          TRANSFERS_FILES = False

          def run(self, tmp=None, task_vars=None):
              result = super(ActionModule, self).run(tmp, task_vars)
              del tmp
              inner = self._execute_module(
                  'uri', module_args={'url': 'http://example.invalid/', 'method': 'GET'})
              self._remove_tmp_path(self._connection._shell.tmpdir)
              if inner.get('failed', False):
                  inner['failed'] = True
              return inner
      PYTHON

    seen = [] of String
    dispatcher = Krikri::PythonActionRunner::ModuleDispatcher.new do |mod, margs|
      seen << mod
      seen << margs["url"].as_s
      JSON.parse(%({"changed": false, "failed": true, "msg": "Status code was -1"}))
    end

    begin
      call = -> {
        Krikri::PythonActionRunner.run_action(path, "myaction", Hash(String, JSON::Any).new,
          "local", "localhost", nil, nil, false, nil, false,
          Hash(String, JSON::Any).new, dispatcher)
      }
      if ansible_importable
        result = call.call
        seen.must_equal(["uri", "http://example.invalid/"])
        result.as_h["failed"].as_bool.must_equal(true)
        result.as_h["msg"].as_s.must_equal("Status code was -1")
      else
        assert_unavailable(call)
      end
    ensure
      FileUtils.rm_r(dir)
    end
  end

  it "turns a dispatcher failure into the plugin's own task failure" do
    dir = File.join(Dir.tempdir, "krikri-pyaction-spec-#{Random.rand(1_000_000)}")
    path = write_action_plugin(dir, "myaction.py", <<-PYTHON)
      from ansible.plugins.action import ActionBase

      class ActionModule(ActionBase):
          TRANSFERS_FILES = False

          def run(self, tmp=None, task_vars=None):
              result = super(ActionModule, self).run(tmp, task_vars)
              del tmp
              return self._execute_module('nosuchmod', module_args={})
      PYTHON

    dispatcher = Krikri::PythonActionRunner::ModuleDispatcher.new do |mod, _args|
      raise "Plugin not available: #{mod}"
    end

    begin
      call = -> {
        Krikri::PythonActionRunner.run_action(path, "myaction", Hash(String, JSON::Any).new,
          "local", "localhost", nil, nil, false, nil, false,
          Hash(String, JSON::Any).new, dispatcher)
      }
      if ansible_importable
        failed = false
        begin
          call.call
        rescue ex : Krikri::PythonActionRunner::ActionError
          failed = true
          ex.message.to_s.must_include("Plugin not available: nosuchmod")
        end
        failed.must_equal(true)
      else
        assert_unavailable(call)
      end
    ensure
      FileUtils.rm_r(dir)
    end
  end

  # Integers wider than Int64 (issue #695): a task arg carrying a
  # bigint-marked wide int must reach the plugin as a real Python int
  # (the payload is serialized to the wrapper's stdin with
  # unquote_bigint_json, so json.loads sees bare digits), and the wide
  # ints in an _execute_module reply must flow back the same way, both
  # directions over the IPC protocol.
  it "round-trips wide integers through task args and the _execute_module IPC reply" do
    dir = File.join(Dir.tempdir, "krikri-pyaction-spec-#{Random.rand(1_000_000)}")
    path = write_action_plugin(dir, "myaction.py", <<-PYTHON)
      from ansible.plugins.action import ActionBase

      class ActionModule(ActionBase):
          TRANSFERS_FILES = False

          def run(self, tmp=None, task_vars=None):
              result = super(ActionModule, self).run(tmp, task_vars)
              del tmp
              result['arg_type'] = type(self._task.args['big']).__name__
              result['echoed'] = self._task.args['big'] + 1
              result['str_arg'] = self._task.args['s']
              inner = self._execute_module(
                  'mod', module_args={'big': self._task.args['big']})
              result['wide'] = inner['wide']
              result['neg'] = inner['neg']
              return result
      PYTHON

    big = BigInt.new(2) ** 200
    wide_args = {
      "big" => JSON::Any.new(Krikri.bigint_sentinel(big.to_s)),
      "s"   => JSON::Any.new("1606938044258990275541962092341162602522202993782792835301376"),
    } of String => JSON::Any

    seen_digits = nil
    dispatcher = Krikri::PythonActionRunner::ModuleDispatcher.new do |_mod, margs|
      # The args the plugin forwarded arrive as JSON::Any parsed from the
      # IPC request line - bigint-aware, so a real int arrives marked.
      seen_digits = Krikri.bigint_digits(margs["big"])
      JSON.parse({
        "changed" => false,
        "wide"    => Krikri.bigint_sentinel(big.to_s),
        "neg"     => Krikri.bigint_sentinel((-(BigInt.new(2) ** 70)).to_s),
      }.to_json)
    end

    begin
      call = -> {
        Krikri::PythonActionRunner.run_action(path, "myaction", wide_args,
          "local", "localhost", nil, nil, false, nil, false,
          Hash(String, JSON::Any).new, dispatcher)
      }
      if ansible_importable
        result = call.call
        # Inbound: the plugin saw a real Python int, not the marked string.
        result.as_h["arg_type"].as_s.must_equal("int")
        Krikri.bigint_digits(result.as_h["echoed"]).must_equal((big + 1).to_s)
        # The module dispatch received the wide int (marked on the
        # engine side after the bigint-aware parse of the request line).
        seen_digits.must_equal(big.to_s)
        # Outbound: the dispatcher's marked wide ints reached the plugin
        # as ints and come back through the wrapper's json.dumps as bare
        # digits, re-marked by the bigint-aware parse of the final line.
        Krikri.bigint_digits(result.as_h["wide"]).must_equal(big.to_s)
        Krikri.bigint_digits(result.as_h["neg"]).must_equal((-(BigInt.new(2) ** 70)).to_s)
        # A genuine string that merely looks like digits is never altered.
        result.as_h["str_arg"].as_s.must_equal("1606938044258990275541962092341162602522202993782792835301376")
      else
        assert_unavailable(call)
      end
    ensure
      FileUtils.rm_r(dir)
    end
  end
end
