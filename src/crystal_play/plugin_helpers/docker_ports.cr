module CrystalPlay
  module PluginHelpers
    # DockerPorts - pure logic for parsing a docker_container `ports:`
    # entry into its host_ip/host_port/container_port/proto components. No
    # I/O - docker_container.cr does the actual API calls.
    module DockerPorts
      record Mapping, host_ip : String?, host_port : String, container_port : String, proto : String

      # Parses one ports: entry. Supported forms (matching real Ansible's
      # docker_container `ports:` syntax):
      #   "80"                          -> container_port=host_port=80, no host_ip
      #   "8080:80"                     -> host_port=8080, container_port=80
      #   "127.0.0.1:8080:80"           -> host_ip=127.0.0.1, host_port=8080, container_port=80
      #   any of the above + "/udp"     -> proto=udp (default "tcp")
      def self.parse(entry : String) : Mapping
        port_part, _, proto_part = entry.partition('/')
        proto = proto_part.empty? ? "tcp" : proto_part

        segments = port_part.split(':')
        case segments.size
        when 1
          Mapping.new(host_ip: nil, host_port: segments[0], container_port: segments[0], proto: proto)
        when 2
          Mapping.new(host_ip: nil, host_port: segments[0], container_port: segments[1], proto: proto)
        when 3
          Mapping.new(host_ip: segments[0], host_port: segments[1], container_port: segments[2], proto: proto)
        else
          raise "invalid port mapping: #{entry.inspect}"
        end
      end
    end
  end
end
