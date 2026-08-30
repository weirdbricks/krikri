require "../spec_helper"
require "../../src/krikri/plugin_manager"
require "../../src/krikri/host"

# Round 195: delegate_to: localhost must be a LOCAL execution even when
# the passed vars context belongs to a non-local origin host.
#
# Found via cloudalchemy.node_exporter on a fresh Ubuntu pair: the role's
# get_url tasks use `delegate_to: localhost`; build_vars_context injects
# ansible_connection="ssh" into the ORIGIN host's vars context, the old
# vars-first local_connection? saw that "ssh" and classified the
# delegated localhost task as remote - the engine then died with an
# unhandled exception ("ssh: connect to host localhost port 22:
# Connection refused") trying to upload the get_url plugin binary to the
# controller over SSH. Real ansible runs delegated localhost tasks
# locally and rc=0s the play.
describe Krikri::PluginManager do
  it "delegated localhost is local even when the origin host's vars say ssh" do
    origin_vars = {"ansible_connection" => JSON::Any.new("ssh")} # build_vars_context's injected default
    localhost = Krikri::Host.new("localhost", "root", 22)        # implicit/delegate fallback, no own connection var
    Krikri::PluginManager.local_connection?(localhost, origin_vars).should be_true
  end

  it "delegated 127.0.0.1 is local regardless of origin vars" do
    origin_vars = {"ansible_connection" => JSON::Any.new("ssh")}
    loopback = Krikri::Host.new("127.0.0.1", "root", 22)
    Krikri::PluginManager.local_connection?(loopback, origin_vars).should be_true
  end

  it "the delegated host's OWN inventory ansible_connection wins" do
    origin_vars = {"ansible_connection" => JSON::Any.new("ssh")}
    # an inventory-defined localhost that really does want SSH (real
    # ansible honors an explicit host-level ansible_connection=ssh)
    remote_localhost = Krikri::Host.new("localhost", "root", 22)
    remote_localhost.vars["ansible_connection"] = JSON::Any.new("ssh")
    Krikri::PluginManager.local_connection?(remote_localhost, origin_vars).should be_false
  end

  it "a remote-target host with local connection in ITS OWN vars is local (old bug class)" do
    origin_vars = {"ansible_connection" => JSON::Any.new("ssh")}
    delegated_local = Krikri::Host.new("box1", "root", 22)
    delegated_local.vars["ansible_connection"] = JSON::Any.new("local")
    Krikri::PluginManager.local_connection?(delegated_local, origin_vars).should be_true
  end

  it "a plain remote host with origin vars saying ssh stays remote" do
    origin_vars = {"ansible_connection" => JSON::Any.new("ssh")}
    remote = Krikri::Host.new("203.0.113.10", "root", 22)
    Krikri::PluginManager.local_connection?(remote, origin_vars).should be_false
  end

  it "same-host call with no ansible_connection anywhere is remote" do
    remote = Krikri::Host.new("203.0.113.10", "root", 22)
    Krikri::PluginManager.local_connection?(remote, {} of String => JSON::Any).should be_false
  end
end
