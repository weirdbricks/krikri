require "../minitest_helper"
require "../../src/krikri/plugin_manager"
require "../../src/krikri/host"

# Issue #677: the host NAME is never a local-connection vote. Real
# ansible-core (2.19.11, live-verified) runs an inventory-defined
# "localhost"/"127.0.0.1" over plain ssh - `{{ ansible_connection }}`
# renders "ssh" on a bare inventory localhost entry, and one carrying
# connection vars (ansible_port=2299) SSHes to that port. Only the
# IMPLICIT localhost (auto-created when no inventory entry exists) is
# local, and it is local because ansible SETS ansible_connection=local
# on it - this engine mirrors that at both implicit-creation sites
# (InventoryParser's pattern resolver and the unresolvable-delegate
# fallback), so "local localhost" always arrives here through the var.
describe "Krikri::PluginManager (plugin_manager_local_connection_test.cr)" do
  describe ".local_connection?" do
    it "treats an implicit localhost (ansible_connection=local var) as local" do
      # What InventoryParser#single_pattern_hosts and the unresolvable-
      # delegate fallback actually build - `delegate_to: localhost` /
      # `delegate_to: 127.0.0.1` with no inventory entry resolves to one
      # of these (ansible-community.ansible-vault's delegate_to:
      # 127.0.0.1 unarchive idiom).
      implicit = Krikri::Host.new("localhost", "root", 22)
      implicit.vars["ansible_connection"] = JSON::Any.new("local")
      Krikri::PluginManager.local_connection?(implicit, implicit.vars).must_equal(true)

      loopback = Krikri::Host.new("127.0.0.1", "root", 22)
      loopback.vars["ansible_connection"] = JSON::Any.new("local")
      Krikri::PluginManager.local_connection?(loopback, loopback.vars).must_equal(true)
    end

    it "does not treat an inventory-defined bare localhost as local (real: ssh)" do
      # Live-verified vs ansible-playbook 2.19.11: a bare inventory
      # `localhost` line UNREACHABLEs with "ssh: connect to host
      # localhost port 22: Connection refused" - the name alone is not
      # the implicit localhost.
      host = Krikri::Host.new("localhost")
      Krikri::PluginManager.local_connection?(host, host.vars).must_equal(false)
    end

    it "does not treat an inventory localhost with connection vars as local (issue #677)" do
      host = Krikri::Host.new("localhost", "tester", 2299)
      host.vars["ansible_port"] = JSON::Any.new(2299)
      host.vars["ansible_user"] = JSON::Any.new("tester")
      Krikri::PluginManager.local_connection?(host, host.vars).must_equal(false)
    end

    it "does not treat a bare 127.0.0.1 inventory host as local" do
      host = Krikri::Host.new("127.0.0.1")
      Krikri::PluginManager.local_connection?(host, host.vars).must_equal(false)
    end

    it "does not treat an ordinary remote host as local" do
      host = Krikri::Host.new("web1.example.com")
      Krikri::PluginManager.local_connection?(host, host.vars).must_equal(false)
    end

    it "still honors ansible_connection: local for any host name" do
      host = Krikri::Host.new("web1.example.com")
      host.vars["ansible_connection"] = JSON::Any.new("local")
      Krikri::PluginManager.local_connection?(host, host.vars).must_equal(true)
    end

    it "the passed vars decide only when the host's own vars are silent" do
      # Same-host (non-delegate) case: vars is the host's own merged
      # context, so a task-level `connection: local` override lands here.
      host = Krikri::Host.new("web1.example.com")
      vars = {"ansible_connection" => JSON::Any.new("local")}
      Krikri::PluginManager.local_connection?(host, vars).must_equal(true)
    end
  end
end
