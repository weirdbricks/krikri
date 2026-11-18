require "../minitest_helper"
require "file_utils"
require "../../src/krikri/ansible_config"
require "../../src/krikri/connection_settings"
require "../../src/krikri/ssh_manager"
require "../../src/krikri/role_loader"

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
end
