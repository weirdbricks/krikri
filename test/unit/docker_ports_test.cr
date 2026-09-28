require "../minitest_helper"
require "../../src/krikri/plugin_helpers/docker_ports"

describe Krikri::PluginHelpers::DockerPorts do
  include RaisesAssertion
  describe ".parse" do
    include RaisesAssertion
    it "parses a bare container port" do
      m = Krikri::PluginHelpers::DockerPorts.parse("80")
      m.host_ip.must_be_nil
      m.host_port.must_equal("80")
      m.container_port.must_equal("80")
      m.proto.must_equal("tcp")
    end

    it "parses host_port:container_port" do
      m = Krikri::PluginHelpers::DockerPorts.parse("8080:80")
      m.host_ip.must_be_nil
      m.host_port.must_equal("8080")
      m.container_port.must_equal("80")
      m.proto.must_equal("tcp")
    end

    it "parses host_ip:host_port:container_port" do
      m = Krikri::PluginHelpers::DockerPorts.parse("127.0.0.1:8080:80")
      m.host_ip.must_equal("127.0.0.1")
      m.host_port.must_equal("8080")
      m.container_port.must_equal("80")
    end

    it "parses a /udp protocol suffix" do
      m = Krikri::PluginHelpers::DockerPorts.parse("8080:80/udp")
      m.host_port.must_equal("8080")
      m.container_port.must_equal("80")
      m.proto.must_equal("udp")
    end

    it "raises on a malformed entry" do
      assert_raises_message(Exception, /invalid port mapping/) do
        Krikri::PluginHelpers::DockerPorts.parse("1:2:3:4")
      end
    end
  end
end
