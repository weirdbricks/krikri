require "../spec_helper"
require "../../src/crystal_play/host"

describe CrystalPlay::Host do
  describe ".from_json" do
    it "parses a host with a user and port" do
      host = CrystalPlay::Host.from_json(JSON.parse(%({"name": "web1", "user": "deploy", "port": 2222})))

      host.name.should eq("web1")
      host.user.should eq("deploy")
      host.port.should eq(2222)
    end

    it "defaults port to 22 when absent" do
      host = CrystalPlay::Host.from_json(JSON.parse(%({"name": "web1", "user": "deploy"})))
      host.port.should eq(22)
    end

    it "leaves user nil when the key is simply absent" do
      host = CrystalPlay::Host.from_json(JSON.parse(%({"name": "localhost"})))
      host.user.should be_nil
    end

    it "leaves user nil when the key is present but JSON null (regression: .try(&.as_s) used to raise here)" do
      # This is exactly what an inventory host declared without an explicit
      # user (e.g. `localhost ansible_connection=local`, no ansible_user=)
      # serializes as: build_plugin_config always emits the "user" key,
      # and host.user being Crystal nil becomes JSON null, not an absent key.
      host = CrystalPlay::Host.from_json(JSON.parse(%({"name": "localhost", "user": null, "port": 22})))
      host.user.should be_nil
      host.name.should eq("localhost")
    end

    it "defaults port to 22 when the key is present but JSON null" do
      host = CrystalPlay::Host.from_json(JSON.parse(%({"name": "localhost", "port": null})))
      host.port.should eq(22)
    end
  end
end
