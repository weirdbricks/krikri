#!/usr/bin/env crystal

require "json"
require "docr"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/docker_ref"
require "../src/crystal_play/plugin_helpers/docker_ports"
require "../src/crystal_play/plugin_helpers/docker_client"

module CrystalPlay
  # Docker container plugin - creates/starts/stops/removes a container.
  # Compatible with Ansible's community.docker.docker_container module.
  #
  # See plugins/docker_image.cr's module comment for the shared
  # architecture note (talks to the Docker Engine API directly, local
  # UNIX socket by default or a remote daemon over TCP(+TLS) via
  # docker_host:/TLS params below, via the weirdbricks/docr fork).
  #
  # Supported parameters:
  # - name: container name (required)
  # - image: image reference - required only when a container actually
  #   needs to be created or recreated (verified against real
  #   ansible-playbook: state: stopped/absent on an already-existing
  #   container needs no image: at all, same as here)
  # - state: started (default) / stopped / present / absent
  # - command: shell command to run (plain string, naively whitespace-split -
  #   same documented limitation as ansible.builtin.command's own cmd:)
  # - entrypoint: same treatment as command:
  # - env: dict of environment variables
  # - labels: dict of labels
  # - ports: comma-separated list of docker_ports.cr-syntax mappings
  #   ("8080:80", "127.0.0.1:8080:80/udp", ...)
  # - volumes: comma-separated list of "host_path:container_path[:mode]"
  #   bind mounts (passed straight through as Docker's own Binds: syntax)
  # - restart_policy: "no" (default)/"always"/"on-failure"/"unless-stopped"
  # - network_mode: string
  # - privileged / auto_remove: bool
  # - pull: bool, default true - pull image: if not already present locally
  # - recreate: bool, default false - force recreate even if image/command
  #   already match
  # - networks: JSON array of `{"name": ..., "aliases": [...], "links":
  #   [...], "ipv4_address": ..., "ipv6_address": ...}` - additional
  #   networks to connect the container to, beyond whatever
  #   network_mode:/the default bridge network already attaches it to.
  #   docr itself only stubs NetworkConnect/NetworkDisconnect (TODO, no
  #   body), so this talks to `POST /networks/{id}/connect` directly via
  #   `Docr::Client#call`, the same raw-HTTP-escape-hatch pattern already
  #   used by image_exists? below - not a docr modification. Checked (and
  #   connected to, if missing) on every run, including when the container
  #   already matches on image/command and nothing else would change.
  # - docker_host: / tls: / validate_certs: (alias tls_verify:) / cacert_path: /
  #   cert_path: / key_path: - connect to a remote Docker daemon over
  #   TCP(+TLS) instead of the local UNIX socket - see
  #   PluginHelpers::DockerClient's own doc comment for exact behavior
  #   (including tls_hostname:/DOCKER_TLS*/DOCKER_CERT_PATH support).
  # - check_mode
  #
  # Idempotency compares only image (leniently, see DockerRef.same?) and
  # command against the existing container found by exact name match - and
  # only for whichever of those two params was actually given, matching
  # real Ansible's own "only compare what you told me about" behavior; any
  # other drifted setting (env, ports, volumes, restart_policy, ...) is
  # NOT detected and won't trigger a recreate on its own unless recreate:
  # true is passed - real Ansible's docker_container does a much deeper
  # ~40-field comparison. A documented, deliberate scope cut given the
  # size of that surface, not an oversight. networks: is the one exception -
  # it's diffed and applied even when nothing else changed, since silently
  # ignoring it after the container already exists would make it useless
  # on every run after the first.
  #
  # Not implemented: `comparisons: strict`/`networks: strict` (Ansible's
  # own per-field idempotency override system) - so an existing container
  # attached to networks NOT listed in networks: is never disconnected
  # from them here, matching real Ansible's own default (non-strict)
  # behavior, but there's no way to opt into the stricter purge behavior;
  # `networks_cli_compatible:` (real Ansible's "don't attach the default
  # network when networks: is given" toggle - this plugin always leaves
  # whatever network_mode:/Docker's own default produced alone and only
  # ever *adds* the requested networks on top); `mac_address:` on a
  # per-network endpoint (only ipv4_address:/ipv6_address:/aliases:/
  # links: per network); healthcheck:, resource limits (memory/cpu),
  # device_requests:, container_default_behavior:, `api_version:` (see
  # PluginHelpers::DockerClient).
  class DockerContainerPlugin < BasePlugin
    record RequestedNetwork,
      name : String,
      aliases : Array(String)?,
      links : Array(String)?,
      ipv4_address : String?,
      ipv6_address : String? do
      def self.from_json(json : JSON::Any) : RequestedNetwork
        new(
          name: json["name"].as_s,
          aliases: json["aliases"]?.try(&.as_a.map(&.as_s)),
          links: json["links"]?.try(&.as_a.map(&.as_s)),
          ipv4_address: json["ipv4_address"]?.try(&.as_s?),
          ipv6_address: json["ipv6_address"]?.try(&.as_s?),
        )
      end
    end

    def execute : PluginResult
      name = @params["name"]?
      unless name
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end

      state = @params["state"]? || "started"
      check_mode = is_true?(@params["check_mode"]?)

      client, docker_host_description = PluginHelpers::DockerClient.build(@params)
      api = Docr::API.new(client)
      existing = find_container(api, name)

      return ensure_absent(api, existing, check_mode) if state == "absent"

      image_ref = @params["image"]?
      command = @params["command"]?.try(&.split(/\s+/).reject(&.empty?))
      pull = is_true?(@params["pull"]?, default: true)
      recreate_requested = is_true?(@params["recreate"]?)

      needs_create = !existing
      needs_recreate = !!existing && (recreate_requested || !matches?(existing.not_nil!, image_ref, command))

      if (needs_create || needs_recreate) && !image_ref
        return PluginResult.new(changed: false, failed: true, msg: "image is required to create a new container")
      end

      requested_networks = parsed_networks

      case state
      when "started"
        ensure_present(api, name, existing, image_ref, pull, needs_create, needs_recreate, requested_networks, start: true, check_mode: check_mode)
      when "present"
        ensure_present(api, name, existing, image_ref, pull, needs_create, needs_recreate, requested_networks, start: false, check_mode: check_mode)
      when "stopped"
        ensure_stopped(api, name, existing, image_ref, pull, needs_create, needs_recreate, requested_networks, check_mode)
      else
        PluginResult.new(changed: false, failed: true, msg: "state must be one of: started, stopped, present, absent - got '#{state}'")
      end
    rescue ex : Docr::Errors::DockerAPIError
      PluginResult.new(changed: false, failed: true, msg: "Docker API error: #{ex.message}")
    rescue ex : Socket::ConnectError
      PluginResult.new(changed: false, failed: true, msg: "Could not connect to the Docker daemon (#{docker_host_description}): #{ex.message}")
    end

    private def ensure_present(
      api : Docr::API, name : String, existing : Docr::Types::ContainerSummary?,
      image_ref : String?, pull : Bool, needs_create : Bool, needs_recreate : Bool,
      requested_networks : Array(RequestedNetwork), start : Bool, check_mode : Bool,
    ) : PluginResult
      if needs_create
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be created#{start ? " and started" : ""}") if check_mode

        config = build_container_config(image_ref.not_nil!)
        ensure_image_pulled(api, image_ref.not_nil!) if pull
        resp = api.containers.create(name, config)
        api.containers.start(resp.id) if start
        connected = sync_networks!(api, resp.id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "Created#{start ? " and started" : ""} container #{name}#{network_suffix(connected)}")
      end

      existing = existing.not_nil!

      if needs_recreate
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be recreated") if check_mode

        config = build_container_config(image_ref.not_nil!)
        api.containers.stop(existing.id) if existing.state == "running"
        api.containers.delete(existing.id, force: true)
        ensure_image_pulled(api, image_ref.not_nil!) if pull
        resp = api.containers.create(name, config)
        api.containers.start(resp.id) if start
        connected = sync_networks!(api, resp.id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "Recreated container #{name}#{network_suffix(connected)}")
      end

      if start && existing.state != "running"
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be started") if check_mode

        api.containers.start(existing.id)
        connected = sync_networks!(api, existing.id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "Started container #{name}#{network_suffix(connected)}")
      end

      no_op_networks_result(api, existing.id, requested_networks, check_mode, "Container #{name} already #{start ? "started" : "present"}")
    end

    private def ensure_stopped(
      api : Docr::API, name : String, existing : Docr::Types::ContainerSummary?,
      image_ref : String?, pull : Bool, needs_create : Bool, needs_recreate : Bool,
      requested_networks : Array(RequestedNetwork), check_mode : Bool,
    ) : PluginResult
      if needs_create
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be created (stopped)") if check_mode

        config = build_container_config(image_ref.not_nil!)
        ensure_image_pulled(api, image_ref.not_nil!) if pull
        resp = api.containers.create(name, config)
        connected = sync_networks!(api, resp.id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "Created container #{name} (stopped)#{network_suffix(connected)}")
      end

      existing = existing.not_nil!

      if needs_recreate
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be recreated (stopped)") if check_mode

        config = build_container_config(image_ref.not_nil!)
        api.containers.stop(existing.id) if existing.state == "running"
        api.containers.delete(existing.id, force: true)
        ensure_image_pulled(api, image_ref.not_nil!) if pull
        resp = api.containers.create(name, config)
        connected = sync_networks!(api, resp.id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "Recreated container #{name} (stopped)#{network_suffix(connected)}")
      end

      if existing.state == "running"
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be stopped") if check_mode

        api.containers.stop(existing.id)
        connected = sync_networks!(api, existing.id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "Stopped container #{name}#{network_suffix(connected)}")
      end

      no_op_networks_result(api, existing.id, requested_networks, check_mode, "Container #{name} already stopped")
    end

    # Shared tail for the "nothing about image/command/run-state needs to
    # change" branch of both ensure_present and ensure_stopped - still
    # connects any missing requested networks (see the class doc comment)
    # and folds that into changed:/msg: if it did anything.
    private def no_op_networks_result(
      api : Docr::API, container_id : String,
      requested_networks : Array(RequestedNetwork), check_mode : Bool, base_msg : String,
    ) : PluginResult
      unless check_mode
        connected = sync_networks!(api, container_id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "#{base_msg}#{network_suffix(connected)}") unless connected.empty?
      end

      PluginResult.new(changed: false, failed: false, msg: base_msg)
    end

    private def ensure_absent(api : Docr::API, existing : Docr::Types::ContainerSummary?, check_mode : Bool) : PluginResult
      unless existing
        return PluginResult.new(changed: false, failed: false, msg: "Container already absent")
      end

      display_name = existing.names.first?.try(&.lchop('/')) || existing.id
      return PluginResult.new(changed: true, failed: false, msg: "Container #{display_name} would be removed") if check_mode

      api.containers.stop(existing.id) if existing.state == "running"
      api.containers.delete(existing.id, force: true)
      PluginResult.new(changed: true, failed: false, msg: "Removed container #{display_name}")
    end

    # Idempotency scope cut - see the class doc comment. Only compares
    # whichever of image_ref/command was actually given; with neither
    # given, an existing container is always considered a match (nothing
    # to compare it against).
    private def matches?(existing : Docr::Types::ContainerSummary, image_ref : String?, command : Array(String)?) : Bool
      if image_ref && !PluginHelpers::DockerRef.same?(existing.image, image_ref)
        return false
      end

      if command
        return false unless existing.command == command.join(" ")
      end

      true
    end

    private def find_container(api : Docr::API, name : String) : Docr::Types::ContainerSummary?
      api.containers.list(all: true).find { |c| c.names.map(&.lchop('/')).includes?(name) }
    end

    private def parsed_networks : Array(RequestedNetwork)
      json = @params["networks"]?
      return [] of RequestedNetwork unless json

      JSON.parse(json).as_a.map { |entry| RequestedNetwork.from_json(entry) }
    end

    # Connects the container to whichever requested networks it isn't
    # already a member of; never disconnects it from anything (see the
    # class doc comment - no `comparisons: strict` purge support). Returns
    # the names of networks actually connected, for the result message.
    private def sync_networks!(api : Docr::API, container_id : String, requested : Array(RequestedNetwork)) : Array(String)
      return [] of String if requested.empty?

      already_connected = api.containers.inspect(container_id).network_settings.networks.keys
      connected = [] of String

      requested.each do |net|
        next if already_connected.includes?(net.name)
        connect_network(api.client, net, container_id)
        connected << net.name
      end

      connected
    end

    # docr's own Networks#connect/#disconnect are unimplemented stubs
    # (TODO, empty body) - calls the Docker Engine API endpoint directly
    # instead, the same raw-HTTP-escape-hatch pattern image_exists? below
    # already uses for an endpoint docr's typed wrapper doesn't cover.
    private def connect_network(client : Docr::Client, net : RequestedNetwork, container_id : String)
      endpoint_config = {
        "Aliases"    => net.aliases,
        "Links"      => net.links,
        "IPAMConfig" => {
          "IPv4Address" => net.ipv4_address,
          "IPv6Address" => net.ipv6_address,
        },
      }
      body = {"Container" => container_id, "EndpointConfig" => endpoint_config}.to_json
      headers = HTTP::Headers{"Content-Type" => "application/json"}

      client.call("POST", "/networks/#{net.name}/connect", headers, body) { |response| response.consume_body_io }
    end

    private def network_suffix(connected : Array(String)) : String
      connected.empty? ? "" : " (connected to network#{connected.size == 1 ? "" : "s"}: #{connected.join(", ")})"
    end

    private def ensure_image_pulled(api : Docr::API, image_ref : String)
      ref_name, ref_tag = PluginHelpers::DockerRef.split(image_ref)
      full_ref = PluginHelpers::DockerRef.join(ref_name, ref_tag)
      return if image_exists?(api.client, full_ref)

      api.images.create(ref_name, ref_tag)
    end

    # Same reasoning as docker_image.cr's own image_exists? - a raw GET,
    # not Images#inspect, and the body must be drained even though its
    # content is unused (left undrained, it desyncs the shared keep-alive
    # connection's HTTP/1.1 framing for whatever call comes next).
    private def image_exists?(client : Docr::Client, ref : String) : Bool
      client.call("GET", "/images/#{ref}/json") { |response| response.consume_body_io }
      true
    rescue ex : Docr::Errors::DockerAPIError
      return false if ex.status_code == 404
      raise ex
    end

    private def build_container_config(image_ref : String) : Docr::Types::CreateContainerConfig
      command = @params["command"]?.try(&.split(/\s+/).reject(&.empty?))
      entrypoint = @params["entrypoint"]?.try(&.split(/\s+/).reject(&.empty?))
      env = @params["env"]?.try { |json| Hash(String, String).from_json(json).map { |k, v| "#{k}=#{v}" } }
      labels = @params["labels"]?.try { |json| Hash(String, String).from_json(json) }

      exposed_ports, port_bindings = build_ports

      restart_policy_name = @params["restart_policy"]?
      restart_policy = restart_policy_name ? Docr::Types::RestartPolicy.new(name: restart_policy_name) : nil

      volumes = @params["volumes"]?.try(&.split(',').map(&.strip).reject(&.empty?))

      host_config = Docr::Types::HostConfig.new(
        binds: volumes,
        port_bindings: port_bindings.empty? ? nil : port_bindings,
        restart_policy: restart_policy,
        network_mode: @params["network_mode"]?,
        privileged: is_true?(@params["privileged"]?),
        auto_remove: is_true?(@params["auto_remove"]?),
      )

      Docr::Types::CreateContainerConfig.new(
        image: image_ref,
        cmd: command,
        entrypoint: entrypoint,
        env: env,
        labels: labels,
        exposed_ports: exposed_ports.empty? ? nil : exposed_ports,
        host_config: host_config,
      )
    end

    private def build_ports : {Hash(String, Hash(String, String)), Hash(String, Array(Docr::Types::PortBinding))}
      exposed_ports = Hash(String, Hash(String, String)).new
      port_bindings = Hash(String, Array(Docr::Types::PortBinding)).new

      entries = @params["ports"]?.try(&.split(',').map(&.strip).reject(&.empty?)) || [] of String
      entries.each do |entry|
        mapping = PluginHelpers::DockerPorts.parse(entry)
        key = "#{mapping.container_port}/#{mapping.proto}"

        exposed_ports[key] = Hash(String, String).new
        port_bindings[key] ||= [] of Docr::Types::PortBinding
        port_bindings[key] << Docr::Types::PortBinding.new(host_ip: mapping.host_ip, host_port: mapping.host_port)
      end

      {exposed_ports, port_bindings}
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::DockerContainerPlugin.new(config)
plugin.run
