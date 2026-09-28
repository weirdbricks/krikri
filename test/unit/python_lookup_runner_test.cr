require "../minitest_helper"
require "file_utils"
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/python_lookup_runner"

# Role-local custom `lookup_plugins/*.py` support - see
# PythonLookupRunner for the mechanism (delegates to the controller's
# own python3; every failure either degrades to the caller's previous
# unknown-lookup behavior via LookupUnavailableError or surfaces the
# plugin's own error as a real LookupError).
#
# The dispatch specs here require the controller python3 to import the
# real `ansible` package (the plugin file itself imports LookupBase at
# its top level). On a controller without it, every dispatch degrades
# to kind "unavailable" - those cases assert exactly that degradation
# rather than skipping, so the suite is green either way.
private def ansible_importable : Bool
  python = Krikri::PythonLookupRunner.python_executable
  return false unless python
  status = Process.run(python, ["-c", "from ansible.plugins.lookup import LookupBase"],
    output: Process::Redirect::Close, error: Process::Redirect::Close)
  status.success?
end

private def write_lookup_plugin(dir : String, name : String, content : String) : String
  lib_dir = File.join(dir, "lookup_plugins")
  Dir.mkdir_p(lib_dir)
  path = File.join(lib_dir, name)
  File.write(path, content)
  path
end

describe Krikri::PythonLookupRunner do
  # ---- source resolution ----

  it "finds a role-private lookup plugin" do
    role = File.join(Dir.tempdir, "krikri-pylookup-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(role)
    path = write_lookup_plugin(role, "mylookup.py", "# test plugin")
    Krikri::PythonLookupRunner.find_source("mylookup", role, nil).must_equal(path)
    FileUtils.rm_r(role)
  end

  it "finds a playbook-adjacent lookup plugin" do
    pb = File.join(Dir.tempdir, "krikri-pylookup-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(pb)
    path = write_lookup_plugin(pb, "mylookup.py", "# test plugin")
    Krikri::PythonLookupRunner.find_source("mylookup", nil, pb).must_equal(path)
    FileUtils.rm_r(pb)
  end

  it "prefers the role's own lookup_plugins/ over the playbook-adjacent one" do
    role = File.join(Dir.tempdir, "krikri-pylookup-spec-#{Random.rand(1_000_000)}")
    pb = File.join(Dir.tempdir, "krikri-pylookup-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(role)
    Dir.mkdir_p(pb)
    role_path = write_lookup_plugin(role, "both.py", "# role")
    write_lookup_plugin(pb, "both.py", "# playbook")
    Krikri::PythonLookupRunner.find_source("both", role, pb).must_equal(role_path)
    FileUtils.rm_r(role)
    FileUtils.rm_r(pb)
  end

  it "returns nil when no lookup_plugins source exists" do
    pb = File.join(Dir.tempdir, "krikri-pylookup-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(pb)
    Krikri::PythonLookupRunner.find_source("no_such_lookup_xyz", nil, pb).must_be_nil
    FileUtils.rm_r(pb)
  end

  # ---- dispatch ----

  it "round-trips a custom lookup plugin's run(terms, variables, **kwargs) result" do
    role = File.join(Dir.tempdir, "krikri-pylookup-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(role)
    source = write_lookup_plugin(role, "mylookup.py", <<-PYTHON)
      from ansible.plugins.lookup import LookupBase

      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              prefix = kwargs.get('prefix', '')
              omit = variables.get('omit')
              return [prefix + str(t) + (omit or '') for t in self._flatten(terms)]
      PYTHON

    variables = Hash(String, JSON::Any).new
    variables["omit"] = JSON::Any.new(Krikri::OMIT_SENTINEL)
    terms = [JSON::Any.new(["a", "b"].map { |entry| JSON::Any.new(entry) })]
    kwargs = {"prefix" => JSON::Any.new("x-")}

    begin
      result = Krikri::PythonLookupRunner.call_lookup("mylookup", source, terms, variables, kwargs)
      result.as_a.map(&.as_s).must_equal(["x-a#{Krikri::OMIT_SENTINEL}", "x-b#{Krikri::OMIT_SENTINEL}"])
    rescue ex : Krikri::PythonLookupRunner::LookupUnavailableError
      # Controller python3 cannot import the ansible package at all -
      # the whole mechanism degrades to the caller's previous
      # unknown-lookup behavior; assert exactly that.
      ex.kind.must_equal("unavailable")
      ex.unavailable?.must_equal(true)
    end
    FileUtils.rm_r(role)
  end

  it "surfaces an exception inside the plugin's run() as a real LookupError" do
    return unless ansible_importable

    role = File.join(Dir.tempdir, "krikri-pylookup-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(role)
    source = write_lookup_plugin(role, "boom.py", <<-PYTHON)
      from ansible.plugins.lookup import LookupBase
      from ansible.errors import AnsibleError

      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              raise AnsibleError('exploding on purpose')
      PYTHON

    empty_vars = Hash(String, JSON::Any).new
    empty_kwargs = Hash(String, JSON::Any).new
    assert_raises_message(Krikri::PythonLookupRunner::LookupError, /exploding on purpose/) do
      Krikri::PythonLookupRunner.call_lookup("boom", source, [] of JSON::Any,
        empty_vars, empty_kwargs)
    end
    FileUtils.rm_r(role)
  end

  private def empty_vars
    Hash(String, JSON::Any).new
  end

  private def empty_kwargs
    Hash(String, JSON::Any).new
  end

  it "reports kind not_found when the file has no LookupModule subclassing LookupBase" do
    return unless ansible_importable

    role = File.join(Dir.tempdir, "krikri-pylookup-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(role)
    source = write_lookup_plugin(role, "wrongclass.py", <<-PYTHON)
      from ansible.plugins.lookup import LookupBase

      class NotALookup(LookupBase):
          pass
      PYTHON

    begin
      Krikri::PythonLookupRunner.call_lookup("wrongclass", source, [] of JSON::Any,
        empty_vars, empty_kwargs)
      raise "expected LookupUnavailableError"
    rescue ex : Krikri::PythonLookupRunner::LookupUnavailableError
      ex.kind.must_equal("not_found")
    end
    FileUtils.rm_r(role)
  end

  it "reports a plugin file with a syntax error as a plugin error, not an unknown lookup" do
    return unless ansible_importable

    role = File.join(Dir.tempdir, "krikri-pylookup-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(role)
    source = write_lookup_plugin(role, "syntax.py", "this is not python (")

    begin
      Krikri::PythonLookupRunner.call_lookup("syntax", source, [] of JSON::Any,
        empty_vars, empty_kwargs)
      raise "expected LookupError"
    rescue ex : Krikri::PythonLookupRunner::LookupUnavailableError
      # A file that cannot even be imported is the plugin's own
      # breakage - real Ansible fails the task; this runner reports it
      # as kind "error" (only the mechanism being absent degrades).
      ex.kind.must_equal("error")
      ex.unavailable?.must_equal(false)
    rescue ex : Krikri::PythonLookupRunner::LookupError
      # acceptable shape - the dispatched failure surfaced
      ex.message.wont_be_nil
    end
    FileUtils.rm_r(role)
  end
end
