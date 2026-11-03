require "../minitest_helper"
require "file_utils"
require "../../src/krikri/python_filter_runner"
require "../../src/krikri/python_test_runner"

# Ansible's configured plugin trees (issue #793): the user/system plugin
# dirs and the ANSIBLE_<TYPE>_PLUGINS path lists its loader consults after
# the role/playbook plugin dirs.
describe "configured plugin paths (issue #793)" do
  serial!

  private def with_env(pairs : Hash(String, String?))
    previous = pairs.keys.to_h { |key| {key, ENV[key]?} }
    begin
      pairs.each do |key, value|
        value ? (ENV[key] = value) : ENV.delete(key)
      end
      yield
    ensure
      previous.each do |key, value|
        value ? (ENV[key] = value) : ENV.delete(key)
      end
    end
  end

  it "treats ANSIBLE_FILTER_PLUGINS as a PATH list that replaces the defaults" do
    with_env({"ANSIBLE_FILTER_PLUGINS" => "/one:~/two::/three", "HOME" => "/home/tester"}) do
      Krikri::PythonFilterRunner.configured_roots("filter", "ANSIBLE_FILTER_PLUGINS")
        .must_equal(["/one", "/home/tester/two", "/three"])
    end
  end

  it "settles each plugin type on its own env var and subdir" do
    with_env({"ANSIBLE_TEST_PLUGINS" => "/tests", "ANSIBLE_ACTION_PLUGINS" => nil,
              "HOME" => "/home/tester", "ANSIBLE_HOME" => nil}) do
      Krikri::PythonFilterRunner.configured_roots("test", "ANSIBLE_TEST_PLUGINS").must_equal(["/tests"])
      Krikri::PythonFilterRunner.configured_roots("filter", "ANSIBLE_FILTER_PLUGINS")
        .must_equal(["/home/tester/.ansible/plugins/filter", "/usr/share/ansible/plugins/filter"])
      Krikri::PythonFilterRunner.configured_roots("action", "ANSIBLE_ACTION_PLUGINS")
        .must_equal(["/home/tester/.ansible/plugins/action", "/usr/share/ansible/plugins/action"])
    end
  end

  it "honours ANSIBLE_HOME for the default plugin home" do
    with_env({"ANSIBLE_FILTER_PLUGINS" => nil, "ANSIBLE_HOME" => "/opt/ansible-home",
              "HOME" => "/home/tester"}) do
      Krikri::PythonFilterRunner.configured_roots("filter", "ANSIBLE_FILTER_PLUGINS")
        .must_equal(["/opt/ansible-home/plugins/filter", "/usr/share/ansible/plugins/filter"])
    end
  end

  it "finds a filter_plugins file in a configured dir, after the extra dirs win" do
    root = PluginSpecHelper.tmp_path("configured-filter-roots")
    configured = File.join(root, "configured")
    playbook = File.join(root, "playbook")
    Dir.mkdir_p(configured)
    Dir.mkdir_p(File.join(playbook, "filter_plugins"))
    File.write(File.join(configured, "cf.py"), "# configured filter")
    File.write(File.join(playbook, "filter_plugins", "pf.py"), "# playbook filter")

    with_env({"ANSIBLE_FILTER_PLUGINS" => configured, "HOME" => File.join(root, "home")}) do
      sources = Krikri::PythonFilterRunner.find_sources(nil, playbook)
      sources.must_include(File.join(configured, "cf.py"))
      # find_sources feeds a last-import-wins name dict, so the playbook's
      # own file must come after the configured one for the playbook's
      # definition to win - as it does in ansible (extra dirs first).
      configured_index = sources.index(File.join(configured, "cf.py")).not_nil!
      playbook_index = sources.index(File.join(playbook, "filter_plugins", "pf.py")).not_nil!
      (configured_index < playbook_index).must_equal(true)

      # no role/playbook dir at all still resolves through the env var
      Krikri::PythonFilterRunner.find_sources(nil, nil)
        .must_equal([File.join(configured, "cf.py")])
    end
  ensure
    FileUtils.rm_r(root) if root
  end

  it "finds a test_plugins file in ANSIBLE_TEST_PLUGINS" do
    root = PluginSpecHelper.tmp_path("configured-test-roots")
    configured = File.join(root, "configured")
    Dir.mkdir_p(configured)
    source = File.join(configured, "ct.py")
    File.write(source, "# configured test")

    with_env({"ANSIBLE_TEST_PLUGINS" => configured, "HOME" => File.join(root, "home")}) do
      Krikri::PythonTestRunner.find_sources(nil, nil).must_equal([source])
    end
  ensure
    FileUtils.rm_r(root) if root
  end

  it "searches the default home filter dir when no env var is set" do
    root = PluginSpecHelper.tmp_path("default-home-filter-roots")
    home = File.join(root, "home")
    Dir.mkdir_p(File.join(home, ".ansible", "plugins", "filter"))
    source = File.join(home, ".ansible", "plugins", "filter", "hf.py")
    File.write(source, "# home filter")

    with_env({"ANSIBLE_FILTER_PLUGINS" => nil, "ANSIBLE_HOME" => nil, "HOME" => home}) do
      Krikri::PythonFilterRunner.find_sources(nil, nil).must_equal([source])
    end
  ensure
    FileUtils.rm_r(root) if root
  end
end
