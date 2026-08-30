require "../spec_helper"
require "../../src/krikri/host"

describe Krikri::Host do
  describe ".from_json" do
    it "parses a host with a user and port" do
      host = Krikri::Host.from_json(JSON.parse(%({"name": "web1", "user": "deploy", "port": 2222})))

      host.name.should eq("web1")
      host.user.should eq("deploy")
      host.port.should eq(2222)
    end

    it "defaults port to 22 when absent" do
      host = Krikri::Host.from_json(JSON.parse(%({"name": "web1", "user": "deploy"})))
      host.port.should eq(22)
    end

    it "leaves user nil when the key is simply absent" do
      host = Krikri::Host.from_json(JSON.parse(%({"name": "localhost"})))
      host.user.should be_nil
    end

    it "leaves user nil when the key is present but JSON null (regression: .try(&.as_s) used to raise here)" do
      # This is exactly what an inventory host declared without an explicit
      # user (e.g. `localhost ansible_connection=local`, no ansible_user=)
      # serializes as: build_plugin_config always emits the "user" key,
      # and host.user being Crystal nil becomes JSON null, not an absent key.
      host = Krikri::Host.from_json(JSON.parse(%({"name": "localhost", "user": null, "port": 22})))
      host.user.should be_nil
      host.name.should eq("localhost")
    end

    it "defaults port to 22 when the key is present but JSON null" do
      host = Krikri::Host.from_json(JSON.parse(%({"name": "localhost", "port": null})))
      host.port.should eq(22)
    end
  end

  describe "#connection_host" do
    it "returns the inventory hostname when no ansible_host is set" do
      host = Krikri::Host.new("web1")
      host.connection_host.should eq("web1")
    end

    it "returns ansible_host when set in vars" do
      host = Krikri::Host.new("web1")
      host.vars["ansible_host"] = JSON::Any.new("10.0.0.1")
      host.connection_host.should eq("10.0.0.1")
    end

    it "returns ansible_host even when it matches the inventory name" do
      host = Krikri::Host.new("web1")
      host.vars["ansible_host"] = JSON::Any.new("web1")
      host.connection_host.should eq("web1")
    end

    it "prefers ansible_host over the inventory name when both exist" do
      host = Krikri::Host.new("db.internal")
      host.vars["ansible_host"] = JSON::Any.new("192.168.1.50")
      host.connection_host.should eq("192.168.1.50")
    end

    it "handles an ansible_host that is set but null gracefully" do
      host = Krikri::Host.new("web1")
      host.vars["ansible_host"] = JSON::Any.new(nil)
      host.connection_host.should eq("web1")
    end
  end
end
