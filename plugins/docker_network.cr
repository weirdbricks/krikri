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
  # - connected: comma-separated list of container names/IDs that should
  #   be connected to the network. By default this list is canonical -
  #   containers currently connected but not listed get disconnected too
  #   (matches real Ansible's own default). Pass appends: true to only add
  #   missing connections and never disconnect anything (real Ansible's
  #   own appends:/incremental alias). Uses the same raw
  #   `Docr::Client#call` escape hatch as docker_container.cr's networks:
  #   for `POST /networks/{id}/connect`/`disconnect` - docr's own
  #   Networks#connect/#disconnect are unimplemented stubs.
  # - appends: bool, default false - see connected: above.
  # - state: present (default) / absent
  # - check_mode
  #
  # Idempotency is by name; if a network with that name already exists
  # but its driver differs from the requested one, it's removed and
  # recreated (Docker has no "change a network's driver in place" API) -
  # everything else about an existing network (IPAM, labels, etc.) is left
  # untouched even if it differs from what was requested, a documented
  # simplification versus real Ansible's much more thorough comparison.
  # connected: is checked/applied on every run regardless, including when
  # the network itself needed no change - silently ignoring it after the
  # network already exists would make it useless on every run after the
  # first, the same reasoning docker_container.cr's own networks: uses.
  #
  # Not implemented: `force:` (real Ansible's "disconnect everyone, delete
  # and recreate the network" override, distinct from the driver-mismatch
  # auto-recreate above), ipam_config:, enable_ipv6:, custom driver
  # options:.
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
      connected = @params["connected"]?.try(&.split(',').map(&.strip).reject(&.empty?)) || [] of String
      appends = is_true?(@params["appends"]?)
      state = @params["state"]? || "present"
      check_mode = is_true?(@params["check_mode"]?)

      client = Docr::Client.new
      api = Docr::API.new(client)

      existing = find_network(api, name)

      case state
      when "present"
        ensure_present(api, name, driver, internal, attachable, labels, connected, appends, existing, check_mode)
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
      connected : Array(String),
      appends : Bool,
      existing : Docr::Types::Network?,
      check_mode : Bool,
    ) : PluginResult
      if existing && existing.driver == driver
        return sync_connected_result(api, existing, connected, appends, check_mode, "Network #{name} already present")
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
      created = api.networks.create(config)
      net_changes = sync_connected!(api, created.id, connected, appends)

      verb = existing ? "Recreated (driver changed)" : "Created"
      PluginResult.new(changed: true, failed: false, msg: "#{verb} network #{name}#{connected_suffix(net_changes)}")
    end

    # Shared tail for "the network itself needs no change" - still syncs
    # connected: (see the class doc comment) and folds that into
    # changed:/msg: if it did anything.
    private def sync_connected_result(
      api : Docr::API, existing : Docr::Types::Network,
      connected : Array(String), appends : Bool, check_mode : Bool, base_msg : String,
    ) : PluginResult
      unless check_mode
        net_changes = sync_connected!(api, existing.id, connected, appends)
        return PluginResult.new(changed: true, failed: false, msg: "#{base_msg}#{connected_suffix(net_changes)}") unless net_changes.empty?
      end

      PluginResult.new(changed: false, failed: false, msg: base_msg)
    end

    # Connects any requested containers not yet connected; when appends:
    # is false (the default, matching real Ansible), also disconnects any
    # currently-connected container not in the requested list. Returns a
    # list of human-readable change descriptions ("connected foo",
    # "disconnected bar") for the result message.
    private def sync_connected!(api : Docr::API, network_id : String, connected : Array(String), appends : Bool) : Array(String)
      return [] of String if connected.empty? && appends

      current = api.networks.inspect(network_id).containers || Hash(String, Docr::Types::NetworkContainer).new
      current_names = current.values.map(&.name)
      changes = [] of String

      connected.each do |container|
        next if current_names.includes?(container)
        docker_raw_call(api.client, "POST", "/networks/#{network_id}/connect", {"Container" => container})
        changes << "connected #{container}"
      end

      unless appends
        current_names.each do |container|
          next if connected.includes?(container)
          docker_raw_call(api.client, "POST", "/networks/#{network_id}/disconnect", {"Container" => container})
          changes << "disconnected #{container}"
        end
      end

      changes
    end

    private def docker_raw_call(client : Docr::Client, method : String, path : String, body)
      headers = HTTP::Headers{"Content-Type" => "application/json"}
      client.call(method, path, headers, body.to_json) { |response| response.consume_body_io }
    end

    private def connected_suffix(changes : Array(String)) : String
      changes.empty? ? "" : " (#{changes.join(", ")})"
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
