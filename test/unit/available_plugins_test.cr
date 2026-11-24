require "../minitest_helper"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/plugin_manager"

# Cross-checks the two hand-maintained plugin registries against the
# plugins/ directory they are supposed to describe. These lists drifted
# silently before (AVAILABLE_PLUGINS had no `facts` entry for the one
# module every play runs on every host; build.sh's own PLUGINS array
# once lacked apt_key entirely while a compiled binary existed), and
# nothing failed the build when they did - a miss only surfaced as a
# runtime "Plugin not available" skip, or a never-uploaded binary.
PROJECT_PLUGINS_DIR = File.expand_path("../../plugins", __DIR__)

# Controller-side pseudo-modules: deliberately listed in
# AVAILABLE_PLUGINS with no plugins/*.cr binary (handled entirely by
# TaskExecutor - see the comment at their AVAILABLE_PLUGINS entries).
CONTROLLER_SIDE_MODULES = %w[reboot group_by set_stats add_host]

describe "plugin registry consistency" do
  it "has an AVAILABLE_PLUGINS entry for every plugins/*.cr binary" do
    missing = Dir.glob(File.join(PROJECT_PLUGINS_DIR, "*.cr")).map { |path| File.basename(path, ".cr") }.select do |name|
      next false if CONTROLLER_SIDE_MODULES.includes?(name)
      next false if Krikri::PlaybookParser::AVAILABLE_PLUGINS.any? { |entry| Krikri::PluginManager.simple_plugin_name(entry) == name }
      true
    end
    missing.must_equal([] of String, "plugins/*.cr with no AVAILABLE_PLUGINS entry (task referencing them is silently dropped as 'Plugin not available')")
  end

  it "has a plugins/*.cr binary (or is a documented controller-side module) for every AVAILABLE_PLUGINS entry" do
    stale = Krikri::PlaybookParser::AVAILABLE_PLUGINS.to_a.select do |entry|
      name = Krikri::PluginManager.simple_plugin_name(entry)
      next false if CONTROLLER_SIDE_MODULES.includes?(name)
      !File.exists?(File.join(PROJECT_PLUGINS_DIR, "#{name}.cr"))
    end
    stale.must_equal([] of String, "AVAILABLE_PLUGINS entries with no plugins/*.cr binary and not controller-side")
  end
end

# The counterpart invariant for the EXTERNAL plugin registry (issue #1755):
# fixtures proving an out-of-tree plugin works must obey the same rules
# RuntimePluginRegistry enforces at load, and must not shadow a built-in
# module - a shadowed name would either be rejected at run time or (worse)
# silently run something other than what the task named.
EXTERNAL_FIXTURES_DIR = File.expand_path("../fixtures/external_plugins", __DIR__)

describe "external plugin fixture registry (issue #1755)" do
  it "names every executable fixture with the plugin name charset" do
    bad = [] of String
    Dir.glob(File.join(EXTERNAL_FIXTURES_DIR, "**", "*")).each do |path|
      next unless File.file?(path) && File::Info.executable?(path)
      name = File.basename(path)
      bad << name unless name.matches?(Krikri::RuntimePluginRegistry::NAME_PATTERN)
    end
    bad.must_equal([] of String, "external plugin fixtures whose name is not a valid plugin name")
  end

  it "never shadows a built-in module name" do
    native = Krikri::PlaybookParser::AVAILABLE_PLUGINS.map { |entry| Krikri::PluginManager.simple_plugin_name(entry) }.to_set
    shadowing = [] of String
    Dir.glob(File.join(EXTERNAL_FIXTURES_DIR, "**", "*")).each do |path|
      next unless File.file?(path) && File::Info.executable?(path)
      name = File.basename(path)
      shadowing << name if native.includes?(name)
    end
    shadowing.must_equal([] of String, "external plugin fixtures shadowing a native module")
  end
end
