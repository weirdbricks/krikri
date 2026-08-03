require "../spec_helper"
require "../../src/crystal_play/plugin_helpers/docker_ports"

describe CrystalPlay::PluginHelpers::DockerPorts do
  describe ".parse" do
    it "parses a bare container port" do
      m = CrystalPlay::PluginHelpers::DockerPorts.parse("80")
      m.host_ip.should be_nil
      m.host_port.should eq("80")
      m.container_port.should eq("80")
      m.proto.should eq("tcp")
    end

    it "parses host_port:container_port" do
      m = CrystalPlay::PluginHelpers::DockerPorts.parse("8080:80")
      m.host_ip.should be_nil
      m.host_port.should eq("8080")
      m.container_port.should eq("80")
      m.proto.should eq("tcp")
    end

    it "parses host_ip:host_port:container_port" do
      m = CrystalPlay::PluginHelpers::DockerPorts.parse("127.0.0.1:8080:80")
      m.host_ip.should eq("127.0.0.1")
      m.host_port.should eq("8080")
      m.container_port.should eq("80")
    end

    it "parses a /udp protocol suffix" do
      m = CrystalPlay::PluginHelpers::DockerPorts.parse("8080:80/udp")
      m.host_port.should eq("8080")
      m.container_port.should eq("80")
      m.proto.should eq("udp")
    end

    it "raises on a malformed entry" do
      expect_raises(Exception, /invalid port mapping/) do
        CrystalPlay::PluginHelpers::DockerPorts.parse("1:2:3:4")
      end
    end
  end
end
