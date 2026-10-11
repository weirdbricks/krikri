require "../minitest_helper"
require "file_utils"
require "digest/md5"
require "../../src/krikri/plugin_manager"

# Issue #1 (arch awareness) - the controller-side decision logic:
# which local plugin binaries get selected for a remote target once the
# target's `uname -m` is known. The remote SSH side itself (probe, upload,
# exec of the per-arch build) is pinned by the integration spec in
# test/integration/plugin_arch_awareness_ssh_test.cr; everything here runs
# in-process against throwaway directory trees.
describe "plugin arch awareness (issue #1)" do
  serial! # mutates process-global state (build arch, executable path, host state)

  after_each do
    Krikri::PluginManager.clear_cache
    Krikri::PluginManager.executable_path_for_spec = nil
    Krikri::PluginManager.controller_os = {% if flag?(:darwin) %} "darwin" {% else %} "linux" {% end %}
    # Restore the lazy default: recompute from the real controller.
    io = IO::Memory.new
    if Process.run("uname", ["-m"], output: io, error: Process::Redirect::Close).success?
      Krikri::PluginManager.build_arch = io.to_s
    else
      Krikri::PluginManager.build_arch = ""
    end
  end

  describe "normalize_arch" do
    it "folds alias spellings onto one canonical form per machine" do
      Krikri::PluginManager.normalize_arch("x86_64").must_equal("x86_64")
      Krikri::PluginManager.normalize_arch("amd64").must_equal("x86_64")
      Krikri::PluginManager.normalize_arch("aarch64").must_equal("aarch64")
      Krikri::PluginManager.normalize_arch("arm64").must_equal("aarch64")
      # Not a known alias: passes through lowercased, matching uname.
      Krikri::PluginManager.normalize_arch("armv7l").must_equal("armv7l")
      Krikri::PluginManager.normalize_arch(" X86_64 \n").must_equal("x86_64")
    end
  end

  describe "OS-aware lookup (arm64 Mac controller -> aarch64 Linux target)" do
    it "keys a different-OS target as <os>-<arch>, a same-OS or unknown-OS one as the bare arch" do
      Krikri::PluginManager.controller_os = "darwin"
      Krikri::PluginManager.platform_key("aarch64", "Linux\n").must_equal("linux-aarch64")
      Krikri::PluginManager.platform_key("aarch64", "Darwin").must_equal("aarch64")
      Krikri::PluginManager.platform_key("aarch64", "").must_equal("aarch64")
      Krikri::PluginManager.controller_os = "linux"
      Krikri::PluginManager.platform_key("x86_64", "Linux").must_equal("x86_64")
      Krikri::PluginManager.platform_key("x86_64", "Darwin").must_equal("darwin-x86_64")
    end

    it "never hands a Mac controller's own plugins to a same-arch Linux target" do
      dir = PluginSpecHelper.tmp_path("arch-plugins-os-#{Random::Secure.hex(4)}")
      begin
        Dir.mkdir_p(File.join(dir, "plugins-linux-aarch64"))
        binary = File.join(dir, "plugins-linux-aarch64", "command")
        File.write(binary, "elf")
        File.chmod(binary, 0o755)
        Krikri::PluginManager.controller_os = "darwin"
        Krikri::PluginManager.build_arch = "aarch64"
        Krikri::PluginManager.executable_path_for_spec = File.join(dir, "krikri-playbook")
        key = Krikri::PluginManager.platform_key("aarch64", "Linux")
        Krikri::PluginManager.local_plugin_path_for_spec("command", key).must_equal(binary)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "fails early, naming the linux release tarball, when no Linux plugins exist" do
      dir = PluginSpecHelper.tmp_path("arch-plugins-os-none-#{Random::Secure.hex(4)}")
      begin
        Dir.mkdir_p(dir)
        Krikri::PluginManager.controller_os = "darwin"
        Krikri::PluginManager.build_arch = "aarch64"
        Krikri::PluginManager.executable_path_for_spec = File.join(dir, "krikri-playbook")
        error = nil
        begin
          Krikri::PluginManager.local_plugin_path_for_spec("command", "linux-aarch64")
        rescue e : Krikri::PluginArchUnsupportedError
          error = e.message.to_s
        end
        message = error.to_s
        message.includes?("plugins-linux-aarch64").must_equal(true, message)
        message.includes?("-linux-arm64.tar.gz").must_equal(true, message)
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe "per-arch binary selection" do
    it "uses the default plugins path when the target arch matches the build" do
      Krikri::PluginManager.build_arch = "x86_64"
      # No executable-path override here: the default lookup falls through
      # to the checkout's ./bin/plugins/command, which ./build.sh built.
      Krikri::PluginManager.local_plugin_path_for_spec("ansible.builtin.command", "x86_64")
        .must_equal("./bin/plugins/command")
    end

    it "folds the target's arch alias before deciding same-arch" do
      # arm64 target on an aarch64 build is the SAME machine - the alias
      # must not send the lookup into a pointless plugins-arm64/ dir.
      Krikri::PluginManager.build_arch = "aarch64"
      Krikri::PluginManager.local_plugin_path_for_spec("command", "arm64")
        .must_equal("./bin/plugins/command")
    end

    it "selects the per-arch binary for a genuinely different target arch" do
      dir = PluginSpecHelper.tmp_path("arch-plugins-#{Random::Secure.hex(4)}")
      begin
        Dir.mkdir_p(File.join(dir, "plugins-aarch64"))
        binary = File.join(dir, "plugins-aarch64", "command")
        File.write(binary, "fake")
        File.chmod(binary, 0o755)

        Krikri::PluginManager.build_arch = "x86_64"
        Krikri::PluginManager.executable_path_for_spec = File.join(dir, "krikri-playbook")
        Krikri::PluginManager.local_plugin_path_for_spec("ansible.builtin.command", "aarch64")
          .must_equal(binary)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "lets one fat binary in the per-arch dir serve every module name" do
      # build.sh's fat-plugin model: all module names are hardlinks to
      # ONE binary, so a per-arch dir only needs a single file under any
      # plugin name.
      dir = PluginSpecHelper.tmp_path("arch-plugins-fat-#{Random::Secure.hex(4)}")
      begin
        Dir.mkdir_p(File.join(dir, "plugins-aarch64"))
        binary = File.join(dir, "plugins-aarch64", "apt")
        File.write(binary, "fake")
        File.chmod(binary, 0o755)

        Krikri::PluginManager.build_arch = "x86_64"
        Krikri::PluginManager.executable_path_for_spec = File.join(dir, "krikri-playbook")
        Krikri::PluginManager.local_plugin_path_for_spec("ansible.builtin.command", "aarch64")
          .must_equal(binary)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "ignores non-executable strays (.md5 sidecars) in the per-arch dir" do
      dir = PluginSpecHelper.tmp_path("arch-plugins-stray-#{Random::Secure.hex(4)}")
      begin
        Dir.mkdir_p(File.join(dir, "plugins-aarch64"))
        File.write(File.join(dir, "plugins-aarch64", "command.md5"), "abc")
        File.write(File.join(dir, "plugins-aarch64", "README"), "readme")
        File.write(File.join(dir, "plugins-aarch64", ".hidden"), "x")
        File.chmod(File.join(dir, "plugins-aarch64", ".hidden"), 0o755)

        Krikri::PluginManager.build_arch = "x86_64"
        Krikri::PluginManager.executable_path_for_spec = File.join(dir, "krikri-playbook")
        # .md5 and README are not executable; .hidden starts with a dot
        # and is skipped so dotfile junk never gets exec'd remotely.
        raised = false
        begin
          Krikri::PluginManager.local_plugin_path_for_spec("command", "aarch64")
        rescue Krikri::PluginArchUnsupportedError
          raised = true
        end
        raised.must_equal(true)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "fails early with the actionable message when no per-arch build exists" do
      dir = PluginSpecHelper.tmp_path("arch-plugins-none-#{Random::Secure.hex(4)}")
      begin
        Dir.mkdir_p(dir)
        Krikri::PluginManager.build_arch = "x86_64"
        Krikri::PluginManager.executable_path_for_spec = File.join(dir, "krikri-playbook")
        error = nil
        begin
          Krikri::PluginManager.local_plugin_path_for_spec("ansible.builtin.command", "aarch64")
        rescue e : Krikri::PluginArchUnsupportedError
          error = e.message.to_s
        end
        # The message must name the missing arch dir (the remedy) and the
        # target arch - it is the replacement for a confusing
        # exec-format failure after a multi-MB upload.
        error.nil?.must_equal(false)
        message = error.as(String)
        message.includes?("plugins-aarch64").must_equal(true, message)
        message.includes?("aarch64").must_equal(true, message)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "uses the default path for an unprobed (nil) arch even with a build arch set" do
      Krikri::PluginManager.build_arch = "x86_64"
      Krikri::PluginManager.local_plugin_path_for_spec("command", nil)
        .must_equal("./bin/plugins/command")
    end

    it "uses the default path when the controller's own arch is unknown" do
      # An unprobeable controller arch must never flip the lookup into a
      # per-arch dir on a guess - that would regress the working path.
      Krikri::PluginManager.build_arch = ""
      Krikri::PluginManager.local_plugin_path_for_spec("command", "aarch64")
        .must_equal("./bin/plugins/command")
    end
  end

  describe "host-state arch recording" do
    it "persists the probed arch in the host-state entry" do
      Krikri::PluginManager.clear_cache
      Krikri::PluginManager.record_host_state_for_spec("root@pi:22", {"command" => "abc123"}, "aarch64")
      Krikri::PluginManager.target_arch_for_spec("root@pi:22").must_equal("aarch64")
    end

    it "records no arch for a host whose uname could not be probed" do
      Krikri::PluginManager.clear_cache
      Krikri::PluginManager.record_host_state_for_spec("root@odd:22", {"command" => "abc"}, nil)
      Krikri::PluginManager.target_arch_for_spec("root@odd:22").must_equal(nil)
    end

    it "does not trust a cached arch entry whose binaries no longer exist locally" do
      # Safety property: the arch record is only an optimization. If the
      # per-arch build vanished, the cache must NOT claim the remote
      # binaries are verified - the real path raises the actionable
      # error instead of shipping controller-arch binaries.
      Krikri::PluginManager.clear_cache
      Krikri::PluginManager.build_arch = "x86_64"
      Krikri::PluginManager.executable_path_for_spec = "/nonexistent/krikri-playbook"
      Krikri::PluginManager.record_host_state_for_spec("root@pi:22", {"command" => "abc"}, "aarch64")
      Krikri::PluginManager.host_state_satisfies_for_spec?("root@pi:22", ["command"]).must_equal(false)
    end

    it "treats a legacy entry with no recorded arch as the controller-arch default" do
      # Backward compatibility: every cache entry written before arch
      # awareness must keep verifying against the default binaries.
      Krikri::PluginManager.clear_cache
      Krikri::PluginManager.build_arch = "x86_64"
      default_path = Krikri::PluginManager.local_plugin_path_for_spec("command", nil)
      md5 = Digest::MD5.new.file(default_path).hexfinal
      Krikri::PluginManager.record_host_state_for_spec("root@x86:22", {"command" => md5}, nil)
      Krikri::PluginManager.host_state_satisfies_for_spec?("root@x86:22", ["command"]).must_equal(true)
      Krikri::PluginManager.target_arch_for_spec("root@x86:22").must_equal(nil)
    end
  end
end
