require "../minitest_helper"
require "file_utils"
require "../../src/krikri/ansible_config"
require "../../src/krikri/connection_settings"
require "../../src/krikri/ssh_manager"
require "../../src/krikri/role_loader"

private FORKS_BINARY = File.expand_path("../../bin/krikri-playbook", __DIR__)

# The ansible.cfg reader behind issue #1478: search order, env > ini
# precedence, the path-expansion rules ansible's ConfigManager applies
# (relative paths resolve against the CONFIG FILE's directory, `~` and
# `{{CWD}}` are unfracked, pathspec splits on ':', pathlist on ','), and
# the two connection settings that used to come from env only.
#
# Processes in this suite share one AnsibleConfig cache and one ENV, and
# other workers read the same settings through RoleLoader/CollectionIndex,
# so these cases opt into the exclusive window.
private ANSIBLE_ENV_KEYS = %w[
  ANSIBLE_CONFIG
  ANSIBLE_INVENTORY
  ANSIBLE_ROLES_PATH
  ANSIBLE_LIBRARY
  ANSIBLE_REMOTE_USER
  ANSIBLE_SSH_ARGS
  ANSIBLE_FORKS
]

private def with_ansible_cfg(content : String, & : String ->)
  dir = PluginSpecHelper.tmp_path("ansible-cfg-unit-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "ansible.cfg"), content)

  saved = {} of String => String
  ANSIBLE_ENV_KEYS.each do |key|
    saved[key] = ENV[key] if ENV.has_key?(key)
    ENV.delete(key)
  end
  ENV["ANSIBLE_CONFIG"] = File.join(dir, "ansible.cfg")

  begin
    Krikri::AnsibleConfig.base_dir = dir
    yield dir
  ensure
    Krikri::AnsibleConfig.base_dir = Dir.current
    ANSIBLE_ENV_KEYS.each do |key|
      if value = saved[key]?
        ENV[key] = value
      else
        ENV.delete(key)
      end
    end
  end
end

private def ssh_arg_pair?(argv : Array(String), option : String, value : String) : Bool
  argv.each_cons(2).any? { |pair| pair[0] == option && pair[1] == value }
end

describe "ansible.cfg reading" do
  exclusive!

  it "resolves [defaults] inventory against the config file's directory" do
    with_ansible_cfg("[defaults]\ninventory = ./inv.ini\n") do |dir|
      Krikri::AnsibleConfig.inventory_sources.must_equal([File.join(dir, "inv.ini")])
    end
  end

  it "splits roles_path and library as colon-separated pathspecs" do
    with_ansible_cfg("[defaults]\nroles_path = ./myroles:~/galaxy-roles\nlibrary = ./library\n") do |dir|
      Krikri::AnsibleConfig.roles_paths.must_equal([
        File.join(dir, "myroles"),
        File.join(ENV["HOME"]? || Path.home.to_s, "galaxy-roles"),
      ])
      Krikri::AnsibleConfig.library_paths.must_equal([File.join(dir, "library")])
    end
  end

  it "lets an env var replace the ini value" do
    with_ansible_cfg("[defaults]\nroles_path = ./myroles\n") do |dir|
      ENV["ANSIBLE_ROLES_PATH"] = "./envroles"
      Krikri::AnsibleConfig.roles_paths.must_equal([File.join(dir, "envroles")])
    end
  end

  it "reads [defaults] remote_user, below ANSIBLE_REMOTE_USER" do
    with_ansible_cfg("[defaults]\nremote_user = nosuchuser\n") do
      Krikri::ConnectionSettings.configured_remote_user.must_equal("nosuchuser")
      ENV["ANSIBLE_REMOTE_USER"] = "envuser"
      Krikri::ConnectionSettings.configured_remote_user.must_equal("envuser")
    end
  end

  it "adds [ssh_connection] ssh_args to the ssh argv and drops an inline comment" do
    with_ansible_cfg("[ssh_connection]\nssh_args = -o ProxyCommand=false ; inline\n") do
      Krikri::AnsibleConfig.ssh_args.must_equal("-o ProxyCommand=false")

      argv = Krikri::SSHManager.ssh_argv("/tmp/control", nil, nil, "nosuchuser", "example.test", ["true"])
      argv.first.must_equal("ssh")
      ssh_arg_pair?(argv, "-o", "ProxyCommand=false").must_equal(true, argv.join(" "))
      argv.last.must_equal("true")
    end
  end

  # Issue #1543: ssh_args decides how the client dials, so a warm
  # ControlMaster must not answer for a run whose args differ. krikri's
  # sockets outlive the process on purpose (a second run rides the first
  # one's master), and ansible hashes its own ssh options into the
  # ControlPath for exactly this reason: live, a host reached with no
  # ssh_args and then re-run under `ssh_args = -o ProxyCommand=false` is
  # UNREACHABLE for ansible-playbook but was `ok=1` here, the mux reusing
  # the earlier master instead of dialing the broken transport.
  it "keys the connection signature on the configured ssh args" do
    proxy_off = ""
    with_ansible_cfg("[ssh_connection]\nssh_args = -o ProxyCommand=false\n") do
      proxy_off = Krikri::SSHManager.connection_sig(nil, [] of String, nil)
      proxy_off.wont_equal("")
      # Same options twice: the same socket, no gratuitous reconnects.
      Krikri::SSHManager.connection_sig(nil, [] of String, nil).must_equal(proxy_off)

      # The env form of the same setting is part of the fingerprint too.
      ENV["ANSIBLE_SSH_ARGS"] = "-o ConnectTimeout=9"
      Krikri::SSHManager.connection_sig(nil, [] of String, nil).wont_equal(proxy_off)
    end

    with_ansible_cfg("[ssh_connection]\nssh_args = -o ConnectTimeout=7\n") do
      Krikri::SSHManager.connection_sig(nil, [] of String, nil).wont_equal(proxy_off)
    end
  end

  # DEFAULT_FORKS is the setting behind the fork count: the ini spelling
  # is what ansible reads by default and ANSIBLE_FORKS outranks it.
  it "reads [defaults] forks as DEFAULT_FORKS, below a non-empty ANSIBLE_FORKS" do
    with_ansible_cfg("[defaults]\nforks = 7\n") do
      Krikri::AnsibleConfig.forks_setting.must_equal(7)
      Krikri::AnsibleConfig.invalid_forks_setting.must_be_nil

      ENV["ANSIBLE_FORKS"] = "2"
      Krikri::AnsibleConfig.forks_setting.must_equal(2)

      # An EMPTY variable still outranks the file in ansible's config
      # manager; it lands on the built-in default instead of the ini's
      # value (verified vs 2.21.6: `forks = 7` plus ANSIBLE_FORKS=""
      # reports ansible_forks=5).
      ENV["ANSIBLE_FORKS"] = ""
      Krikri::AnsibleConfig.forks_setting.must_be_nil
    end
  end

  # An empty ini value is not the empty-env case: ansible only falls back
  # to the built-in default for an empty ENVIRONMENT variable, so a bare
  # `forks =` in the file is a refused value (verified vs 2.21.6).
  it "refuses an empty [defaults] forks value" do
    with_ansible_cfg("[defaults]\nforks =\n") do |dir|
      Krikri::AnsibleConfig.invalid_forks_setting.must_equal({"", File.join(dir, "ansible.cfg")})
    end
  end

  # ensure_type's `integer` branch parses with Python's decimal.Decimal
  # and keeps the value only when it equals its own integer part, so a
  # zero-mantissa float/exponent counts and underscores are allowed,
  # while int()'s own literal forms (0x10) are not part of that grammar.
  it "accepts and refuses the DEFAULT_FORKS values ansible's integer type does" do
    with_ansible_cfg("") do
      {"5" => 5, "5.0" => 5, " 3 " => 3, "1e2" => 100, "+3" => 3, "3_0" => 30}.each do |raw, expected|
        ENV["ANSIBLE_FORKS"] = raw
        Krikri::AnsibleConfig.forks_setting.must_equal(expected, raw)
        Krikri::AnsibleConfig.invalid_forks_setting.must_be_nil(raw)
      end
      {"kpg-many", "3.5", "0x10", ".5"}.each do |raw|
        ENV["ANSIBLE_FORKS"] = raw
        Krikri::AnsibleConfig.invalid_forks_setting.must_equal({raw, "env: ANSIBLE_FORKS"}, raw)
      end
    end
  end
end

# Real ansible-playbook resolves DEFAULT_FORKS while importing its
# constants module, so a value the `integer` coercion refuses kills the
# process before argument parsing: nothing on stdout, the ERROR line plus
# BOTH chained Python tracebacks on stderr, rc=5 - the playbook never
# starts. krikri used to ignore the variable and play the whole book
# (issue #1501).
describe "DEFAULT_FORKS validation" do
  private def with_forks_playbook(& : String ->)
    dir = PluginSpecHelper.tmp_path("default-forks-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "inv.ini"), "[g]\nlocalhost ansible_connection=local\n")
    File.write(File.join(dir, "pb.yml"), <<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - name: fork probe
            ansible.builtin.debug:
              msg: 'forks={{ ansible_forks }}'
      YAML
    yield dir
  ensure
    FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
  end

  it "refuses a non-integer ANSIBLE_FORKS before running anything" do
    with_forks_playbook do |dir|
      out_io = IO::Memory.new
      err_io = IO::Memory.new
      status = Process.run(FORKS_BINARY, ["-i", "inv.ini", "pb.yml"],
        output: out_io, error: err_io, chdir: dir, env: {"ANSIBLE_FORKS" => "kpg-many"})
      status.exit_code.must_equal(5)
      out_io.to_s.must_equal("")

      message = "Config 'DEFAULT_FORKS' from 'env: ANSIBLE_FORKS' has an invalid value: " \
                "Invalid value provided for 'integer': 'kpg-many'"
      err = err_io.to_s
      err.lines[0].must_equal("ERROR: #{message}")
      err.scan("Traceback (most recent call last):").size.must_equal(2)
      err.must_include("ValueError: Invalid value provided for 'integer': 'kpg-many'")
      err.must_include("ansible.errors.AnsibleOptionsError: #{message}")
      err.ends_with?("\n\n").must_equal(true)
      err.includes?("PLAY RECAP").must_equal(false)
    end
  end

  # The accepted spelling still has to reach the run: DEFAULT_FORKS is
  # what ansible_forks reports when no -f/--forks is given.
  it "takes the fork count from a valid ANSIBLE_FORKS" do
    with_forks_playbook do |dir|
      out_io = IO::Memory.new
      status = Process.run(FORKS_BINARY, ["-i", "inv.ini", "pb.yml"],
        output: out_io, error: out_io, chdir: dir, env: {"ANSIBLE_FORKS" => "3"})
      status.exit_code.must_equal(0)
      out_io.to_s.must_include("forks=3")
    end
  end
end
