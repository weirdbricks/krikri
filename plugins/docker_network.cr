#!/usr/bin/env crystal

require "json"
require "docr"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Docker network plugin - creates/removes a Docker network.
  # Compatible with Ansible's community.docker.docker_network module.
  #
  # See plugins/docker_image.cr's module comment for the shared
  # architecture note (talks to the Docker Engine API directly over its
  # UNIX socket via the weirdbricks/docr fork, local daemon only).
  #
  # Supported parameters:
  # - name: network name (required)
  # - driver: network driver (default "bridge")
  # - internal: restrict external access (bool, default false)
  # - attachable: allow manual container attach in swarm mode (bool, default false)
  # - labels: dict of labels
  # - state: present (default) / absent
  # - check_mode
  #
  # Idempotency is by name; if a network with that name already exists
  # but its driver differs from the requested one, it's removed and
  # recreated (Docker has no "change a network's driver in place" API) -
  # everything else about an existing network (IPAM, labels, etc.) is left
  # untouched even if it differs from what was requested, a documented
  # simplification versus real Ansible's much more thorough comparison.
  #
  # Not implemented: connecting/disconnecting containers (connected:) -
  # docr itself doesn't implement NetworkConnect/NetworkDisconnect yet;
  # ipam_config:, enable_ipv6:, custom driver options:.
  class DockerNetworkPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      unless name
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end

      driver = @params["driver"]? || "bridge"
      internal = is_true?(@params["internal"]?)
      attachable = is_true?(@params["attachable"]?)
      labels = @params["labels"]?.try { |json| Hash(String, String).from_json(json) }
      state = @params["state"]? || "present"
      check_mode = is_true?(@params["check_mode"]?)

      client = Docr::Client.new
      api = Docr::API.new(client)

      existing = find_network(api, name)

      case state
      when "present"
        ensure_present(api, name, driver, internal, attachable, labels, existing, check_mode)
      when "absent"
        ensure_absent(api, existing, check_mode)
      else
        PluginResult.new(changed: false, failed: true, msg: "state must be 'present' or 'absent', got '#{state}'")
      end
    rescue ex : Docr::Errors::DockerAPIError
      PluginResult.new(changed: false, failed: true, msg: "Docker API error: #{ex.message}")
    rescue ex : Socket::ConnectError
      PluginResult.new(changed: false, failed: true, msg: "Could not connect to the Docker daemon (#{docker_host_description}): #{ex.message}")
    end

    private def ensure_present(
      api : Docr::API,
      name : String,
      driver : String,
      internal : Bool,
      attachable : Bool,
      labels : Hash(String, String)?,
      existing : Docr::Types::Network?,
      check_mode : Bool,
    ) : PluginResult
      if existing && existing.driver == driver
        return PluginResult.new(changed: false, failed: false, msg: "Network #{name} already present")
      end

      if check_mode
        verb = existing ? "recreated (driver changed)" : "created"
        return PluginResult.new(changed: true, failed: false, msg: "Network #{name} would be #{verb}")
      end

      if existing
        api.networks.delete(existing.id)
      end

      config = Docr::Types::NetworkConfig.new(
        name: name,
        driver: driver,
        internal: internal,
        attachable: attachable,
        labels: labels,
      )
      api.networks.create(config)

      verb = existing ? "Recreated (driver changed)" : "Created"
      PluginResult.new(changed: true, failed: false, msg: "#{verb} network #{name}")
    end

    private def ensure_absent(api : Docr::API, existing : Docr::Types::Network?, check_mode : Bool) : PluginResult
      unless existing
        return PluginResult.new(changed: false, failed: false, msg: "Network already absent")
      end

      if check_mode
        return PluginResult.new(changed: true, failed: false, msg: "Network #{existing.name} would be removed")
      end

      api.networks.delete(existing.id)
      PluginResult.new(changed: true, failed: false, msg: "Removed network #{existing.name}")
    end

    private def find_network(api : Docr::API, name : String) : Docr::Types::Network?
      api.networks.list.find { |net| net.name == name }
    end

    private def docker_host_description : String
      ENV["DOCKER_HOST"]? || "default socket #{Docr::Client::DEFAULT_SOCKET_PATH}"
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::DockerNetworkPlugin.new(config)
plugin.run
