require "../minitest_helper"
require "file_utils"
require "../../src/krikri/plugin_manager"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/runtime_plugin_registry"

# Issue #1755 - the controller-side decisions for externally built module
# plugins: which root/name is legal, and which of a plugin's binaries a
# given target platform gets. The execution side (dispatch, upload, async)
# is pinned by test/integration/runtime_plugin_test.cr; the per-platform
# branch is proved here through the existing build_arch=/controller_os=
# seams rather than by having a real arm64 Mac.
describe "external module plugin registry (issue #1755)" do
  serial! # process-global registry + PluginManager arch/executable seams

  after_each do
    Krikri::RuntimePluginRegistry.reset
    Krikri::PluginManager.clear_cache
    Krikri::PluginManager.executable_path_for_spec = nil
    Krikri::PluginManager.controller_os = {% if flag?(:darwin) %} "darwin" {% else %} "linux" {% end %}
    io = IO::Memory.new
    if Process.run("uname", ["-m"], output: io, error: Process::Redirect::Close).success?
      Krikri::PluginManager.build_arch = io.to_s
    else
      Krikri::PluginManager.build_arch = ""
    end
  end

  # A root the registry accepts: a plain 0755 directory owned by us.
  def make_root(name : String) : String
    dir = PluginSpecHelper.tmp_path("#{name}-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(dir)
    File.chmod(dir, 0o755)
    dir
  end

  def write_plugin(dir : String, name : String, content : String = "#!/bin/sh\nexit 0\n") : String
    Dir.mkdir_p(dir)
    path = File.join(dir, name)
    File.write(path, content)
    File.chmod(path, 0o755)
    path
  end

  describe "registration" do
    it "indexes a flat plugin and resolves it for a local connection and a same-platform target" do
      root = make_root("registry-flat")
      path = write_plugin(root, "mycompany.internal.foo")
      Krikri::RuntimePluginRegistry.configure([root])

      Krikri::RuntimePluginRegistry.registered?("mycompany.internal.foo").must_equal(true)
      Krikri::RuntimePluginRegistry.flat_path("mycompany.internal.foo").must_equal(path)
      # Local connections resolve the flat file and probe no arch...
      Krikri::PluginManager.local_plugin_path_for_spec("mycompany.internal.foo", nil).must_equal(path)
      # ...as does a remote target whose platform key is this build's own.
      Krikri::PluginManager.build_arch = "x86_64"
      Krikri::PluginManager.local_plugin_path_for_spec("mycompany.internal.foo", "x86_64").must_equal(path)
    end

    it "keeps a plugin's arch builds out of the flat lookup, and vice versa" do
      root = make_root("registry-arch-only")
      arch_path = write_plugin(File.join(root, "plugins-linux-x86_64"), "mycompany.internal.foo")
      Krikri::RuntimePluginRegistry.configure([root])
      Krikri::PluginManager.build_arch = "aarch64"

      Krikri::RuntimePluginRegistry.arch_path("mycompany.internal.foo", "linux-x86_64").must_equal(arch_path)
      Krikri::RuntimePluginRegistry.flat_path("mycompany.internal.foo").must_equal(nil)

      # A local connection has no arch to probe: only the flat file counts.
      error = nil
      begin
        Krikri::PluginManager.local_plugin_path_for_spec("mycompany.internal.foo", nil)
      rescue e : Krikri::PluginUnavailableError
        error = e.message.to_s
      end
      message = error.to_s
      message.includes?("Plugin binary not found: mycompany.internal.foo").must_equal(true, message)
      message.includes?(File.join(root, "")).must_equal(true, message)
    end

    it "skips non-executable and hidden files instead of registering them" do
      root = make_root("registry-skip")
      write_plugin(root, "not-executable").tap { |path| File.chmod(path, 0o644) }
      write_plugin(root, ".hidden")
      File.write(File.join(root, "README.md"), "docs")
      Krikri::RuntimePluginRegistry.configure([root])
      Krikri::RuntimePluginRegistry.registered_names.must_equal([] of String)
    end

    it "refuses a symlinked plugin file" do
      root = make_root("registry-symlink")
      real = write_plugin(root, "real-plugin")
      File.symlink(real, File.join(root, "mycompany.internal.foo"))
      ex = assert_raises(Krikri::RuntimePluginRegistry::ConfigError) do
        Krikri::RuntimePluginRegistry.configure([root])
      end
      ex.message.to_s.includes?("symlink").must_equal(true, ex.message.to_s)
    end

    it "refuses a name in a namespace simple_plugin_name strips" do
      root = make_root("registry-reserved")
      write_plugin(root, "community.general.foo")
      ex = assert_raises(Krikri::RuntimePluginRegistry::ConfigError) do
        Krikri::RuntimePluginRegistry.configure([root])
      end
      ex.message.to_s.includes?("reserves").must_equal(true, ex.message.to_s)
    end

    it "refuses an executable whose name is not a valid plugin name" do
      root = make_root("registry-badname")
      write_plugin(root, "my company foo")
      ex = assert_raises(Krikri::RuntimePluginRegistry::ConfigError) do
        Krikri::RuntimePluginRegistry.configure([root])
      end
      ex.message.to_s.includes?("not a valid plugin name").must_equal(true, ex.message.to_s)
    end

    it "refuses one plugin name provided by two roots" do
      first = make_root("registry-dup-a")
      second = make_root("registry-dup-b")
      write_plugin(first, "mycompany.internal.foo")
      write_plugin(second, "mycompany.internal.foo")
      ex = assert_raises(Krikri::RuntimePluginRegistry::ConfigError) do
        Krikri::RuntimePluginRegistry.configure([first, second])
      end
      ex.message.to_s.includes?("provided twice").must_equal(true, ex.message.to_s)
    end

    it "refuses a plugin name that shadows a built-in module" do
      root = make_root("registry-native")
      write_plugin(root, "command")
      ex = assert_raises(Krikri::RuntimePluginRegistry::ConfigError) do
        Krikri::RuntimePluginRegistry.configure([root])
      end
      ex.message.to_s.includes?("shadows a module").must_equal(true, ex.message.to_s)
    end

    # `raw` is a MODULE_ALIASES key, not an AVAILABLE_PLUGINS entry:
    # resolve_module_name answers it before ever consulting this registry,
    # so accepting it would silently run the alias target instead.
    it "refuses a name krikri only knows as an alias" do
      root = make_root("registry-alias")
      write_plugin(root, "raw")
      ex = assert_raises(Krikri::RuntimePluginRegistry::ConfigError) do
        Krikri::RuntimePluginRegistry.configure([root])
      end
      ex.message.to_s.includes?("shadows a module").must_equal(true, ex.message.to_s)
    end

    # A silently-ignored platform directory means every task that needed that
    # platform is skipped as an "unimplemented plugin" - so a symlinked one is
    # refused loudly, like a symlinked plugin file.
    it "refuses a symlinked plugins-<key>/ directory" do
      root = make_root("registry-symlink-arch")
      real = make_root("registry-symlink-arch-target")
      write_plugin(real, "mycompany.internal.foo")
      File.symlink(real, File.join(root, "plugins-x86_64"))
      ex = assert_raises(Krikri::RuntimePluginRegistry::ConfigError) do
        Krikri::RuntimePluginRegistry.configure([root])
      end
      ex.message.to_s.includes?("is a symlink").must_equal(true, ex.message.to_s)
    end

    it "refuses a flat plugin named with the reserved plugins- prefix" do
      root = make_root("registry-prefix")
      write_plugin(root, "plugins-foo")
      ex = assert_raises(Krikri::RuntimePluginRegistry::ConfigError) do
        Krikri::RuntimePluginRegistry.configure([root])
      end
      ex.message.to_s.includes?("plugins-<key>").must_equal(true, ex.message.to_s)
    end

    it "refuses a missing or group-writable root" do
      missing = PluginSpecHelper.tmp_path("registry-missing-#{Random::Secure.hex(4)}")
      assert_raises(Krikri::RuntimePluginRegistry::ConfigError) do
        Krikri::RuntimePluginRegistry.configure([missing])
      end

      writable = make_root("registry-writable")
      File.chmod(writable, 0o775)
      ex = assert_raises(Krikri::RuntimePluginRegistry::ConfigError) do
        Krikri::RuntimePluginRegistry.configure([writable])
      end
      ex.message.to_s.includes?("group- or world-writable").must_equal(true, ex.message.to_s)
    end
  end

  describe "per-platform selection" do
    it "selects plugins-<key>/ for a different platform and never falls back to flat" do
      root = make_root("registry-arch")
      flat = write_plugin(root, "mycompany.internal.foo")
      arch = write_plugin(File.join(root, "plugins-linux-x86_64"), "mycompany.internal.foo")
      Krikri::RuntimePluginRegistry.configure([root])
      Krikri::PluginManager.controller_os = "darwin"
      Krikri::PluginManager.build_arch = "aarch64"

      Krikri::PluginManager.local_plugin_path_for_spec("mycompany.internal.foo", "linux-x86_64").must_equal(arch)
      # The controller's own (Mach-O) build must never be handed to the
      # Linux target even though it is right there.
      Krikri::PluginManager.local_plugin_path_for_spec("mycompany.internal.foo", "aarch64").must_equal(flat)
    end

    it "raises PluginArchUnsupportedError naming the directories searched, not an exec-format failure" do
      root = make_root("registry-arch-miss")
      write_plugin(root, "mycompany.internal.foo")
      Krikri::RuntimePluginRegistry.configure([root])
      Krikri::PluginManager.controller_os = "darwin"
      Krikri::PluginManager.build_arch = "aarch64"

      ex = assert_raises(Krikri::PluginArchUnsupportedError) do
        Krikri::PluginManager.local_plugin_path_for_spec("mycompany.internal.foo", "linux-x86_64")
      end
      message = ex.message.to_s
      message.includes?("no linux-x86_64 binary for external plugin mycompany.internal.foo").must_equal(true, message)
      message.includes?(File.join(root, "plugins-linux-x86_64", "")).must_equal(true, message)
      # The krikri-release remedy would be the wrong advice for an external
      # plugin - it names the operator's own directories instead.
      message.includes?("krikri-<version>").must_equal(false, message)
    end

    it "resolves by exact filename only, never by another executable in the directory" do
      root = make_root("registry-exact")
      write_plugin(root, "mycompany.internal.foo")
      Krikri::RuntimePluginRegistry.configure([root])
      # A different (unregistered) name gets krikri's own not-found error
      # naming plugins/, never the other external plugin in the root.
      ex = assert_raises(Exception) do
        Krikri::PluginManager.local_plugin_path_for_spec("mycompany.internal.bar", nil)
      end
      ex.message.to_s.includes?("mycompany.internal.foo").must_equal(false, ex.message.to_s)
    end
  end

  describe "registration side effects" do
    it "resolves a registered name in the parser and keeps validate() quiet" do
      root = make_root("registry-parser")
      write_plugin(root, "mycompany.internal.foo")
      Krikri::RuntimePluginRegistry.configure([root])

      Krikri::PlaybookParser.resolve_module_name("mycompany.internal.foo").must_equal("mycompany.internal.foo")

      dir = PluginSpecHelper.tmp_path("registry-pb-#{Random::Secure.hex(4)}")
      Dir.mkdir_p(dir)
      path = File.join(dir, "site.yml")
      File.write(path, <<-YAML)
        - hosts: localhost
          gather_facts: false
          tasks:
            - name: external
              mycompany.internal.foo:
                name: hi
        YAML
      playbook = Krikri::PlaybookParser.parse(path)
      Krikri::PlaybookParser.validate(playbook).must_equal([] of String)
    end

    it "makes a registered name daemon-ineligible while native modules stay eligible" do
      root = make_root("registry-daemon")
      write_plugin(root, "mycompany.internal.foo")
      Krikri::RuntimePluginRegistry.configure([root])

      Krikri::PluginManager.runtime_plugin?("mycompany.internal.foo").must_equal(true)
      Krikri::PluginManager.daemon_eligible?("mycompany.internal.foo", false).must_equal(false)
      Krikri::PluginManager.daemon_eligible?("ansible.builtin.command", false).must_equal(true)
      Krikri::PluginManager.runtime_plugin?("ansible.builtin.command").must_equal(false)
    end

    it "fixes simple_plugin_name's unescaped dots" do
      # A bare `community.` used to match `communityXgeneral.` too.
      Krikri::PluginManager.simple_plugin_name("communityXgeneral.foo").must_equal("communityXgeneral.foo")
      Krikri::PluginManager.simple_plugin_name("community.general.foo").must_equal("foo")
      Krikri::PluginManager.simple_plugin_name("ansible.builtin.command").must_equal("command")
    end
  end
end
