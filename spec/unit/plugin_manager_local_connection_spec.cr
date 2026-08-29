require "../spec_helper"
require "../../src/crystal_play/plugin_manager"
require "../../src/crystal_play/host"

describe CrystalPlay::PluginManager do
  describe ".local_connection?" do
    it "treats a host named 127.0.0.1 the same as localhost" do
      # Real bug found benchmarking ansible-community.ansible-vault's own
      # local package download/unarchive tasks, all written as
      # `delegate_to: 127.0.0.1` (a common Ansible idiom, treated
      # identically to "localhost" by real Ansible) - previously only
      # "localhost" was recognized, so a delegated task tried to SSH-
      # upload plugin binaries to "127.0.0.1" as if it were a genuine
      # remote target.
      host = CrystalPlay::Host.new("127.0.0.1")
      CrystalPlay::PluginManager.local_connection?(host, host.vars).should be_true
    end

    it "still treats a host named localhost as local" do
      host = CrystalPlay::Host.new("localhost")
      CrystalPlay::PluginManager.local_connection?(host, host.vars).should be_true
    end

    it "does not treat an ordinary remote host as local" do
      host = CrystalPlay::Host.new("web1.example.com")
      CrystalPlay::PluginManager.local_connection?(host, host.vars).should be_false
    end

    it "still honors ansible_connection: local for any host name" do
      host = CrystalPlay::Host.new("web1.example.com")
      host.vars["ansible_connection"] = JSON::Any.new("local")
      CrystalPlay::PluginManager.local_connection?(host, host.vars).should be_true
    end
  end
end
