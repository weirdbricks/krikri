require "../minitest_helper"
require "file_utils"

# Issue #1755 - a module plugin built outside the krikri tree, loaded from a
# plugin directory instead of being compiled in and registered in
# AVAILABLE_PLUGINS. The fixture is a POSIX sh script, so this also proves
# the language-agnostic claim: the module boundary is the existing process
# boundary (JSON config on stdin, JSON result on stdout).
#
# The per-platform (plugins-<key>/) selection and the registry's own
# validation live in test/unit/runtime_plugin_registry_test.cr - they are
# decisions about paths, not about running a playbook, and the arm64
# controller case cannot be reproduced on this host.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")
private FIXTURE      = File.join(PROJECT_ROOT, "test", "fixtures", "external_plugins", "mycompany.internal.foo")

private PLAYBOOK = <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: external plugin
        mycompany.internal.foo:
          name: world
        register: r
      - name: verify
        ansible.builtin.assert:
          that:
            - r.invoked_name == "world"
            - r.msg == "hello from world"
      - ansible.builtin.debug:
          msg: "EXT {{ r.msg }}"
  YAML

# A plugin directory the registry will accept: mode 0755, no group/other
# write (the registry refuses a writable plugin root - it is a trust
# boundary, see its own comment), holding one executable plugin unless
# *empty* is set. *arch_key* puts it under plugins-<key>/ instead of flat.
private def make_plugin_dir(name : String, empty : Bool = false, arch_key : String? = nil) : String
  dir = PluginSpecHelper.tmp_path("#{name}-#{Random::Secure.hex(4)}")
  target = arch_key ? File.join(dir, "plugins-#{arch_key}") : dir
  Dir.mkdir_p(target)
  File.chmod(dir, 0o755)
  File.chmod(target, 0o755)
  unless empty
    FileUtils.cp(FIXTURE, File.join(target, "mycompany.internal.foo"))
    File.chmod(File.join(target, "mycompany.internal.foo"), 0o755)
  end
  dir
end

private def run_playbook(yaml : String, args : Array(String), env : Hash(String, String)? = nil, chdir : String? = nil) : {Process::Status, String}
  playbook = PluginSpecHelper.tmp_path("external-pb-#{Random::Secure.hex(4)}.yml")
  File.write(playbook, yaml)
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY] + args + [playbook],
    output: captured, error: captured, env: env, chdir: chdir)
  {status, captured.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

private def run_external(args : Array(String), env : Hash(String, String)? = nil) : {Process::Status, String}
  run_playbook(PLAYBOOK, args, env)
end

private ASYNC_PLAYBOOK = <<-YAML
  - hosts: localhost
    connection: local
    gather_facts: false
    tasks:
      - name: external plugin async
        mycompany.internal.foo:
          name: async
        async: 30
        poll: 1
        register: r
      - ansible.builtin.assert:
          that: r.invoked_name == "async"
      - ansible.builtin.debug:
          msg: "EXT {{ r.msg }}"
  YAML

describe "external module plugins (issue #1755)" do
  it "runs a shell-script plugin supplied with --plugin-path" do
    dir = make_plugin_dir("ext-flag")
    status, output = run_external(["--plugin-path", dir])
    status.success?.must_equal(true, output)
    output.includes?("EXT hello from world").must_equal(true, output)
    output.includes?("unimplemented plugin").must_equal(false, output)
    output.includes?("failed=0").must_equal(true, output)
  end

  it "runs it from KRIKRI_PLUGIN_PATH too" do
    dir = make_plugin_dir("ext-env")
    status, output = run_external([] of String, env: {"KRIKRI_PLUGIN_PATH" => dir})
    status.success?.must_equal(true, output)
    output.includes?("EXT hello from world").must_equal(true, output)
    output.includes?("unimplemented plugin").must_equal(false, output)
  end

  it "combines --plugin-path and KRIKRI_PLUGIN_PATH instead of one shadowing the other" do
    empty = make_plugin_dir("ext-empty", empty: true)
    populated = make_plugin_dir("ext-populated")
    status, output = run_external(["--plugin-path", empty], env: {"KRIKRI_PLUGIN_PATH" => populated})
    status.success?.must_equal(true, output)
    output.includes?("EXT hello from world").must_equal(true, output)
  end

  # The local `__async_run` re-invocation re-enters this binary before CLI
  # parsing, so --plugin-path only reaches it through the environment the
  # parent sets (issue #1755's own forwarding requirement).
  it "runs under async: with --plugin-path" do
    dir = make_plugin_dir("ext-async-flag")
    status, output = run_playbook(ASYNC_PLAYBOOK, ["--plugin-path", dir])
    status.success?.must_equal(true, output)
    output.includes?("ASYNC OK on localhost").must_equal(true, output)
    output.includes?("EXT hello from async").must_equal(true, output)
  end

  it "runs under async: with KRIKRI_PLUGIN_PATH" do
    dir = make_plugin_dir("ext-async-env")
    status, output = run_playbook(ASYNC_PLAYBOOK, [] of String, env: {"KRIKRI_PLUGIN_PATH" => dir})
    status.success?.must_equal(true, output)
    output.includes?("ASYNC OK on localhost").must_equal(true, output)
    output.includes?("EXT hello from async").must_equal(true, output)
  end

  # The local daemon can only run the fat plugin binary (its dispatch table
  # is compiled in), so an external plugin must fall back to the one-shot
  # fork - and produce the same result as --no-persistent-daemon.
  it "falls back cleanly under the default persistent daemon" do
    dir = make_plugin_dir("ext-daemon")
    status, daemon_output = run_external(["--plugin-path", dir, "--persistent-daemon"])
    status.success?.must_equal(true, daemon_output)
    fork_status, fork_output = run_external(["--plugin-path", dir, "--no-persistent-daemon"])
    fork_status.success?.must_equal(true, fork_output)
    daemon_output.includes?("EXT hello from world").must_equal(true, daemon_output)
    daemon_output.includes?("failed=0").must_equal(true, daemon_output)
    fork_output.includes?("EXT hello from world").must_equal(true, fork_output)
  end

  # A relative --plugin-path resolves against the INVOCATION directory,
  # not the playbook's: krikri chdirs to the playbook's directory, and the
  # local `__async_run` child is spawned from there - so the root has to be
  # absolutized (and forwarded through KRIKRI_PLUGIN_PATH) before the chdir.
  it "resolves a relative --plugin-path against the invocation directory" do
    dir = make_plugin_dir("ext-relative")
    parent = File.dirname(dir)
    status, output = run_playbook(ASYNC_PLAYBOOK,
      ["--plugin-path", "./#{File.basename(dir)}"], chdir: parent)
    status.success?.must_equal(true, output)
    output.includes?("EXT hello from async").must_equal(true, output)
  end

  # A per-platform-only plugin has no controller-native build to run, so a
  # LOCAL task has nothing to exec. That must be one clean failed task with
  # the directories named - never an unhandled crash, and never a silently
  # skipped task.
  it "fails the task cleanly when only a per-platform build exists for a local run" do
    dir = make_plugin_dir("ext-arch-only", arch_key: "linux-x86_64")
    status, output = run_external(["--plugin-path", dir])
    status.success?.must_equal(false, output)
    output.includes?("Plugin binary not found: mycompany.internal.foo").must_equal(true, output)
    output.includes?(File.join(dir, "")).must_equal(true, output)
    output.includes?("Unhandled exception").must_equal(false, output)
    output.includes?("failed=1").must_equal(true, output)
  end

  # Supplying your own implementation of a module ansible-core removed is a
  # reason to build an external plugin at all. A registered name shadows the
  # tombstone exactly like a role's own library/<name> source does.
  it "runs for a name that is a removed-module tombstone" do
    dir = PluginSpecHelper.tmp_path("ext-tombstone-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(dir)
    FileUtils.cp(FIXTURE, File.join(dir, "consul_acl"))
    File.chmod(File.join(dir, "consul_acl"), 0o755)
    File.chmod(dir, 0o755)
    playbook = <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: external replacement for a removed module
            consul_acl:
              name: world
            register: r
          - ansible.builtin.debug:
              msg: "EXT {{ r.msg }}"
      YAML
    status, output = run_playbook(playbook, ["--plugin-path", dir])
    status.success?.must_equal(true, output)
    output.includes?("EXT hello from world").must_equal(true, output)
    output.includes?("couldn't resolve module/action").must_equal(false, output)
  end

  it "does not warn 'unimplemented plugin' in --syntax-check" do
    dir = make_plugin_dir("ext-syntax")
    status, output = run_playbook(PLAYBOOK, ["--syntax-check", "--plugin-path", dir])
    status.success?.must_equal(true, output)
    output.includes?("unimplemented plugin").must_equal(false, output)
  end

  it "reports a bad plugin directory before parsing the playbook" do
    dir = make_plugin_dir("ext-rw")
    File.chmod(dir, 0o775)
    status, output = run_external(["--plugin-path", dir])
    status.success?.must_equal(false, output)
    output.includes?("group- or world-writable").must_equal(true, output)
  end
end
