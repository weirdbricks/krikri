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
# `Ansible` package (the plugin file itself imports LookupBase at
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
  it "fails hashi_vault with ansible's load error when the controller python lacks hvac" do
    dir = File.join(Dir.tempdir, "krikri-hvac-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(dir)
    fake = File.join(dir, "python3")
    File.write(fake, "#!/bin/sh\nexit 1\n")
    File.chmod(fake, 0o755)
    message = Krikri::PythonLookupRunner.hashi_vault_load_failure("hashi_vault", fake)
    message.to_s.must_match(/\AThe lookup plugin 'hashi_vault' failed to load: Failed to import the required Python library \(hvac\) on .+'s Python #{Regex.escape(fake)}\./)
    Krikri::PythonLookupRunner.hashi_vault_load_failure("file", fake).must_be_nil
    FileUtils.rm_r(dir)
  end

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

  it "finds a lookup plugin in a loaded dependency role's registered lookup_plugins/ root" do
    # Ansible's add_all_plugin_dirs puts a meta dependency's
    # lookup_plugins/ on the search path for the rest of the run
    # (gzm55.local_id_plugin's `id` serving
    # gzm55.local_ssh_known_hosts, issue #519), so find_source consults
    # the loaded-role registry when neither the current role nor the
    # playbook dir ships the name.
    root = PluginSpecHelper.tmp_path("pylookup-dependency-root")
    dep_role = File.join(root, "dep_role")
    path = write_lookup_plugin(dep_role, "mylookup.py", "# dependency role plugin")
    Krikri::PythonFilterRunner.register_role_plugin_roots(dep_role)
    begin
      Krikri::PythonLookupRunner.find_source("mylookup", nil, nil).must_equal(path)
      # the current role's own lookup_plugins/ still wins over the
      # registry (nearest-first, like PythonFilterRunner#find_sources)
      own_role = File.join(root, "own_role")
      own_path = write_lookup_plugin(own_role, "mylookup.py", "# own role plugin")
      Krikri::PythonLookupRunner.find_source("mylookup", own_role, nil).must_equal(own_path)
    ensure
      Krikri::PythonFilterRunner.unregister_role_plugin_roots_under(root)
    end
    FileUtils.rm_r(root)
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
      # breakage - Ansible fails the task; this runner reports it
      # as kind "error" (only the mechanism being absent degrades).
      ex.kind.must_equal("error")
      ex.unavailable?.must_equal(false)
    rescue ex : Krikri::PythonLookupRunner::LookupError
      # acceptable shape - the dispatched failure surfaced
      ex.message.wont_be_nil
    end
    FileUtils.rm_r(role)
  end

  # Integers wider than Int64 (issue #695): the wrapper's stdout is
  # parsed bigint-aware, so a lookup returning Python ints that do not
  # fit Int64 arrives as BIGINT_SENTINEL_PREFIX-marked strings (the same
  # carrier every renderer already prints unquoted) instead of the whole
  # result silently becoming nil on JSON.parse's "Invalid Int64".
  it "carries wide integers a lookup returns as marked bigints" do
    return unless ansible_importable

    role = File.join(Dir.tempdir, "krikri-pylookup-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(role)
    source = write_lookup_plugin(role, "bigint.py", <<-PYTHON)
      from ansible.plugins.lookup import LookupBase

      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              return [2 ** 200, {"neg": -(2 ** 70)}, "1606938044258990275541962092341162602522202993782792835301376"]
      PYTHON

    begin
      result = Krikri::PythonLookupRunner.call_lookup("bigint", source, [] of JSON::Any,
        empty_vars, empty_kwargs)
      # The int: a marked string carrying the exact bare digits.
      Krikri.bigint_digits(result.as_a[0]).must_equal((BigInt.new(2) ** 200).to_s)
      # Nested inside a dict too.
      Krikri.bigint_digits(result.as_a[1].as_h["neg"]).must_equal((-(BigInt.new(2) ** 70)).to_s)
      # A genuine STRING that merely looks like digits stays a string,
      # never promoted to a bigint.
      result.as_a[2].as_s.must_equal("1606938044258990275541962092341162602522202993782792835301376")
      Krikri.bigint_digits(result.as_a[2]).must_be_nil
    rescue ex : Krikri::PythonLookupRunner::LookupUnavailableError
      ex.unavailable?.must_equal(true)
    end
    FileUtils.rm_r(role)
  end

  # Round-trip: a marked wide int passed back as a lookup TERM must
  # reach the plugin's run() as a real Python int - under ansible the
  # term IS an int, and `terms[0] + 1` on a string would raise.
  it "hands a marked wide integer term to the lookup as a real Python int" do
    return unless ansible_importable

    role = File.join(Dir.tempdir, "krikri-pylookup-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(role)
    source = write_lookup_plugin(role, "plusone.py", <<-PYTHON)
      from ansible.plugins.lookup import LookupBase

      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              return [terms[0] + 1, type(terms[0]).__name__]
      PYTHON

    begin
      terms = [JSON::Any.new(Krikri.bigint_sentinel((BigInt.new(2) ** 200).to_s))]
      result = Krikri::PythonLookupRunner.call_lookup("plusone", source, terms,
        empty_vars, empty_kwargs)
      Krikri.bigint_digits(result.as_a[0]).must_equal(((BigInt.new(2) ** 200) + 1).to_s)
      result.as_a[1].as_s.must_equal("int")
    rescue ex : Krikri::PythonLookupRunner::LookupUnavailableError
      ex.unavailable?.must_equal(true)
    end
    FileUtils.rm_r(role)
  end
end

# Issue #705: a spawn failure (fork/exec hiccup, fd exhaustion) is
# distinguishable since #704 - the runner must carry its text into the
# eventual failure instead of the bare-rescue nil that surfaced only as
# "is python3 available?". The KRIKRI_TEST_FORCE_PYTHON_SPAWN_FAILURE
# hook names a counter file: while it holds a positive integer, each
# python3 spawn attempt consumes one count and fails with a simulated
# environment-level spawn error.
describe "PythonLookupRunner spawn failure reporting (#705)" do
  exclusive! # ENV hook + warning-sink swap are process-wide

  it "surfaces a wrapper spawn failure as an unavailable lookup carrying the spawn text" do
    role = File.join(Dir.tempdir, "krikri-pylookup-spec-#{Random.rand(1_000_000)}")
    path = write_lookup_plugin(role, "mylookup.py", "# test plugin")
    counter = File.join(role, "spawn-counter")
    File.write(counter, "999")

    ENV["KRIKRI_TEST_FORCE_PYTHON_SPAWN_FAILURE"] = counter
    empty_vars = Hash(String, JSON::Any).new
    begin
      ex = assert_raises(Krikri::PythonLookupRunner::LookupUnavailableError) do
        Krikri::PythonLookupRunner.call_lookup("mylookup", path, [] of JSON::Any,
          empty_vars, empty_vars)
      end
      # same unavailable-mechanism verdict as before - the caller keeps
      # its unknown-lookup fallback - only the text is now diagnosable
      ex.kind.must_equal("unavailable")
      ex.unavailable?.must_equal(true)
      ex.message.to_s.must_match(/Failed to spawn process/)
      ex.message.to_s.must_match(/simulated spawn failure/)
    ensure
      ENV["KRIKRI_TEST_FORCE_PYTHON_SPAWN_FAILURE"] = nil
      FileUtils.rm_r(role)
    end
  end

  it "puts the hvac probe's spawn failure on stderr and keeps its nil verdict" do
    counter = File.join(Dir.tempdir, "krikri-hvac-probe-counter-#{Random.rand(1_000_000)}")
    File.write(counter, "1")
    captured = IO::Memory.new
    previous = Krikri::PythonLookupRunner.warning_sink
    begin
      Krikri::PythonLookupRunner.warning_sink = captured
      ENV["KRIKRI_TEST_FORCE_PYTHON_SPAWN_FAILURE"] = counter
      Krikri::PythonLookupRunner.hashi_vault_load_failure("hashi_vault").must_be_nil
    ensure
      ENV["KRIKRI_TEST_FORCE_PYTHON_SPAWN_FAILURE"] = nil
      Krikri::PythonLookupRunner.warning_sink = previous
      File.delete(counter) if File.exists?(counter)
    end

    captured.to_s.must_match(/\[WARNING\]: Lookup plugin 'hashi_vault' availability probe failed/)
    captured.to_s.must_match(/simulated spawn failure/)
  end
end

# Issue #778: the search trees Ansible's own PluginLoader consults after
# the role/playbook directories - `ANSIBLE_LOOKUP_PLUGINS` (which
# REPLACES the defaults, live-verified vs ansible-playbook 2.19.11) and
# the default `~/.ansible/plugins/lookup` + `/usr/share/ansible/plugins/
# lookup` pair. Ignoring them made real ansible find a plugin krikri
# reported as "The lookup plugin 'X' was not found.".
describe "PythonLookupRunner configured lookup plugin roots (#778)" do
  serial! # ENV["ANSIBLE_LOOKUP_PLUGINS"]/["HOME"] are process-wide

  it "finds a plugin under a directory named by ANSIBLE_LOOKUP_PLUGINS" do
    root = PluginSpecHelper.tmp_path("pylookup-env-root")
    path = write_lookup_plugin(File.join(root, "custom_lookups"), "envlookup.py",
      "# env-configured plugin")
    plugin_dir = File.dirname(path)
    previous = ENV["ANSIBLE_LOOKUP_PLUGINS"]?
    begin
      ENV["ANSIBLE_LOOKUP_PLUGINS"] = plugin_dir
      Krikri::PythonLookupRunner.find_source("envlookup", nil, nil).must_equal(path)
    ensure
      previous ? (ENV["ANSIBLE_LOOKUP_PLUGINS"] = previous) : ENV.delete("ANSIBLE_LOOKUP_PLUGINS")
      FileUtils.rm_r(root)
    end
  end

  it "treats ANSIBLE_LOOKUP_PLUGINS as a PATH-style list and replaces the defaults" do
    root = PluginSpecHelper.tmp_path("pylookup-env-list")
    first = File.join(root, "one")
    second_path = write_lookup_plugin(File.join(root, "two"), "secondlookup.py",
      "# second entry")
    second = File.dirname(second_path)
    home = File.join(root, "home")
    write_lookup_plugin(File.join(home, ".ansible", "plugins", "lookup"),
      "homelookup.py", "# user dir plugin")
    previous_env = ENV["ANSIBLE_LOOKUP_PLUGINS"]?
    previous_home = ENV["HOME"]?
    begin
      ENV["ANSIBLE_LOOKUP_PLUGINS"] = "#{first}:#{second}"
      ENV["HOME"] = home
      # both list entries are searched...
      Krikri::PythonLookupRunner.find_source("secondlookup", nil, nil).must_equal(second_path)
      # ...and the env var REPLACES ~/.ansible/plugins/lookup, as in ansible
      Krikri::PythonLookupRunner.find_source("homelookup", nil, nil).must_be_nil
    ensure
      previous_env ? (ENV["ANSIBLE_LOOKUP_PLUGINS"] = previous_env) : ENV.delete("ANSIBLE_LOOKUP_PLUGINS")
      previous_home ? (ENV["HOME"] = previous_home) : ENV.delete("HOME")
      FileUtils.rm_r(root)
    end
  end

  it "expands a ~ entry in ANSIBLE_LOOKUP_PLUGINS like ansible's pathlist settings" do
    root = PluginSpecHelper.tmp_path("pylookup-env-tilde")
    home = File.join(root, "home")
    path = write_lookup_plugin(File.join(home, "mylookups"), "tildelookup.py", "# tilde entry")
    previous_env = ENV["ANSIBLE_LOOKUP_PLUGINS"]?
    previous_home = ENV["HOME"]?
    begin
      ENV["HOME"] = home
      ENV["ANSIBLE_LOOKUP_PLUGINS"] = "~/mylookups/#{File.basename(File.dirname(path))}"
      Krikri::PythonLookupRunner.find_source("tildelookup", nil, nil).must_equal(path)
    ensure
      previous_env ? (ENV["ANSIBLE_LOOKUP_PLUGINS"] = previous_env) : ENV.delete("ANSIBLE_LOOKUP_PLUGINS")
      previous_home ? (ENV["HOME"] = previous_home) : ENV.delete("HOME")
      FileUtils.rm_r(root)
    end
  end

  it "falls back to ~/.ansible/plugins/lookup and the system dir when unset" do
    previous = ENV["ANSIBLE_LOOKUP_PLUGINS"]?
    begin
      ENV.delete("ANSIBLE_LOOKUP_PLUGINS")
      roots = Krikri::PythonLookupRunner.configured_roots
      home = ENV["HOME"]? || ENV["USERPROFILE"]?
      roots.includes?(File.join(home, ".ansible", "plugins", "lookup")).must_equal(true) if home
      roots.includes?("/usr/share/ansible/plugins/lookup").must_equal(true)
    ensure
      ENV["ANSIBLE_LOOKUP_PLUGINS"] = previous if previous
    end
  end
end

# Ansible's own plugin loader registers a plugin's DOCUMENTATION options
# with its config manager and sets `_load_name`, and hands the plugin a
# real DataLoader. Custom lookups use both (`self.set_options(...)` /
# `self.get_option(...)` is the standard way to read a plugin option;
# `self._loader.path_dwim_relative` backs find_file_in_search_path), so
# the wrapper reproduces them - without it a perfectly ordinary custom
# lookup failed with `KeyError: ` (issue #778's follow-up sweep).
describe "PythonLookupRunner plugin loader fidelity (#778)" do
  it "supports set_options()/get_option() driven by the plugin's DOCUMENTATION" do
    return unless ansible_importable

    root = PluginSpecHelper.tmp_path("pylookup-set-options")
    source = write_lookup_plugin(root, "opts.py", <<-PYTHON)
      from ansible.plugins.lookup import LookupBase

      DOCUMENTATION = """
      name: opts
      short_description: reads an option through ansible's config manager
      options:
        prefix:
          description: prefix
          default: "P-"
      """

      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              self.set_options(var_options=variables, direct=kwargs)
              prefix = self.get_option("prefix")
              return [prefix + str(t) for t in terms]
      PYTHON

    empty = {} of String => JSON::Any
    result = Krikri::PythonLookupRunner.call_lookup("opts", source,
      [JSON::Any.new("a"), JSON::Any.new("b")], empty, empty)
    result.as_a.map(&.as_s).must_equal(["P-a", "P-b"])

    # a `direct=` override still wins, exactly like ansible's precedence
    result = Krikri::PythonLookupRunner.call_lookup("opts", source,
      [JSON::Any.new("a")], empty, {"prefix" => JSON::Any.new("x-")})
    result.as_a.map(&.as_s).must_equal(["x-a"])
    FileUtils.rm_r(root)
  end

  it "hands the plugin a real DataLoader for self._loader" do
    return unless ansible_importable

    root = PluginSpecHelper.tmp_path("pylookup-dataloader")
    source = write_lookup_plugin(root, "ldr.py", <<-PYTHON)
      from ansible.plugins.lookup import LookupBase

      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              return [type(self._loader).__name__]
      PYTHON

    empty = {} of String => JSON::Any
    result = Krikri::PythonLookupRunner.call_lookup("ldr", source,
      [] of JSON::Any, empty, empty)
    result.as_a.map(&.as_s).must_equal(["DataLoader"])
    FileUtils.rm_r(root)
  end
end
