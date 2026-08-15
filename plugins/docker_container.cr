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
  # Idempotency compares image (leniently, see DockerRef.same?), command,
  # entrypoint, env, labels, volumes, restart_policy, network_mode,
  # privileged, and auto_remove against the existing container - each
  # only for whichever of those params was actually given, matching real
  # Ansible's own "only compare what you told me about" behavior for any
  # option not mentioned at all. ports, healthcheck, resource limits
  # (memory/cpu), and every other field of real Ansible's own ~40-field
  # comparison system remain NOT detected and won't trigger a recreate on
  # their own unless recreate: true is passed - a documented, deliberate
  # scope cut given the size of that remaining surface (ports in
  # particular is genuinely gnarly: Docker's own inspect output fills in
  # HostIp defaults like "0.0.0.0" a request may have left nil), not an
  # oversight. networks: is a separate exception from all of the above -
  # it's diffed and applied even when nothing else changed, since silently
  # ignoring it after the container already exists would make it useless
  # on every run after the first.
  #
  # - comparisons: a dict (e.g. `{"networks": "strict"}`,
  #   `{"env": "ignore"}`) - real Ansible's own default per field is
  #   `strict` (exact-value equality, matching this plugin's own default
  #   behavior above); `ignore` opts a field out of comparison entirely,
  #   for every field this plugin actually tracks/syncs (the list above
  #   plus networks). `allow_more_present` (real Ansible's third mode -
  #   dict/list superset matching rather than exact equality) is NOT
  #   implemented - a further, real scope cut. `comparisons:
  #   {networks: strict}` disconnects the container from any network NOT
  #   in networks: - verified against real Ansible's own documented
  #   behavior ("To remove a container from one or more networks, use
  #   `networks: strict` in the `comparisons` option") - live-verified
  #   against a real Docker daemon.
  #
  # Not implemented: `networks_cli_compatible:` (real Ansible's "don't
  # attach the default
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
      needs_recreate = !!existing && (recreate_requested || !matches?(api, existing.not_nil!, image_ref, command))

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
        connected, disconnected = sync_networks!(api, resp.id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "Created#{start ? " and started" : ""} container #{name}#{network_suffix(connected, disconnected)}")
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
        connected, disconnected = sync_networks!(api, resp.id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "Recreated container #{name}#{network_suffix(connected, disconnected)}")
      end

      if start && existing.state != "running"
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be started") if check_mode

        api.containers.start(existing.id)
        connected, disconnected = sync_networks!(api, existing.id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "Started container #{name}#{network_suffix(connected, disconnected)}")
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
        connected, disconnected = sync_networks!(api, resp.id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "Created container #{name} (stopped)#{network_suffix(connected, disconnected)}")
      end

      existing = existing.not_nil!

      if needs_recreate
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be recreated (stopped)") if check_mode

        config = build_container_config(image_ref.not_nil!)
        api.containers.stop(existing.id) if existing.state == "running"
        api.containers.delete(existing.id, force: true)
        ensure_image_pulled(api, image_ref.not_nil!) if pull
        resp = api.containers.create(name, config)
        connected, disconnected = sync_networks!(api, resp.id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "Recreated container #{name} (stopped)#{network_suffix(connected, disconnected)}")
      end

      if existing.state == "running"
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be stopped") if check_mode

        api.containers.stop(existing.id)
        connected, disconnected = sync_networks!(api, existing.id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "Stopped container #{name}#{network_suffix(connected, disconnected)}")
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
        connected, disconnected = sync_networks!(api, container_id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "#{base_msg}#{network_suffix(connected, disconnected)}") unless connected.empty? && disconnected.empty?
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
    # whichever of image_ref/command/entrypoint/env/labels/volumes/
    # restart_policy/network_mode/privileged/auto_remove was actually
    # given ("only compare what you told me about" - matches real
    # Ansible's own general behavior for any option not mentioned at
    # all). ports/healthcheck/resource-limits/etc remain a real,
    # documented scope cut (see the class doc comment) - ports in
    # particular is genuinely gnarly to compare (Docker's own inspect
    # output fills in HostIp defaults like "0.0.0.0" the request may
    # have left nil), not folded into this pass.
    private def matches?(api : Docr::API, existing : Docr::Types::ContainerSummary, image_ref : String?, command : Array(String)?) : Bool
      if image_ref && !PluginHelpers::DockerRef.same?(existing.image, image_ref)
        return false
      end

      if command
        return false unless existing.command == command.join(" ")
      end

      return true unless extra_fields_given?

      extra_fields_match?(api, api.containers.inspect(existing.id), image_ref)
    end

    EXTRA_COMPARISON_FIELDS = %w[entrypoint env labels volumes restart_policy network_mode privileged auto_remove]

    private def extra_fields_given? : Bool
      EXTRA_COMPARISON_FIELDS.any? { |field| @params[field]? }
    end

    # Real Ansible's own `comparisons:` default per field is `strict`
    # (exact-value equality) unless the field is explicitly set to
    # `ignore` (or `allow_more_present`, not implemented here - a
    # further real scope cut, only `strict`/`ignore` are supported).
    private def field_ignored?(field : String) : Bool
      raw = @params["comparisons"]?
      return false unless raw
      parsed = JSON.parse(raw) rescue nil
      parsed.try(&.[field]?).try(&.as_s?) == "ignore"
    end

    private def extra_fields_match?(api : Docr::API, inspected : Docr::Types::ContainerInspectResponse, image_ref : String?) : Bool
      config = inspected.config
      host_config = inspected.host_config

      if (entrypoint = @params["entrypoint"]?) && !field_ignored?("entrypoint")
        return false unless config.entrypoint == entrypoint.split(/\s+/).reject(&.empty?)
      end

      if (env_json = @params["env"]?) && !field_ignored?("env")
        return false unless (config.env || [] of String).to_set == expected_env(api, image_ref, env_json)
      end

      if (labels_json = @params["labels"]?) && !field_ignored?("labels")
        requested = Hash(String, String).from_json(labels_json)
        return false unless (config.labels || Hash(String, String).new) == requested
      end

      if (volumes = @params["volumes"]?) && !field_ignored?("volumes")
        requested = volumes.split(',').map(&.strip).reject(&.empty?).to_set
        return false unless (host_config.binds || [] of String).to_set == requested
      end

      if (restart_policy_name = @params["restart_policy"]?) && !field_ignored?("restart_policy")
        return false unless host_config.restart_policy.try(&.name) == restart_policy_name
      end

      if (network_mode = @params["network_mode"]?) && !field_ignored?("network_mode")
        return false unless host_config.network_mode == network_mode
      end

      if @params["privileged"]? && !field_ignored?("privileged")
        return false unless !!host_config.privileged == is_true?(@params["privileged"]?)
      end

      if @params["auto_remove"]? && !field_ignored?("auto_remove")
        return false unless !!host_config.auto_remove == is_true?(@params["auto_remove"]?)
      end

      true
    end

    # Matches real Ansible's own `_get_expected_env_value`: the image's
    # own baked-in `Env` (from its Dockerfile `ENV` directives) is folded
    # into the "expected" set before comparing against the running
    # container's actual `Env`, so a base image that sets env vars beyond
    # whatever `env:` the task itself lists doesn't cause a false
    # mismatch on every single run - `env:`-given keys win over the
    # image's own value for the same key.
    private def expected_env(api : Docr::API, image_ref : String?, env_json : String) : Set(String)
      expected = Hash(String, String).new
      if image_ref
        image_env = api.images.inspect(image_ref).config.env || [] of String
        image_env.each do |entry|
          key, _, value = entry.partition('=')
          expected[key] = value
        end
      end
      Hash(String, String).from_json(env_json).each { |k, v| expected[k] = v }
      expected.map { |k, v| "#{k}=#{v}" }.to_set
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
    # already a member of. Also disconnects it from any network NOT in
    # *requested* when `comparisons: {networks: strict}` is given -
    # verified against real Ansible's own documented behavior ("To
    # remove a container from one or more networks, use `networks:
    # strict` in the `comparisons` option" - the default leaves extra
    # networks alone entirely, matching this plugin's own prior
    # behavior before `strict:` support existed). Returns
    # {connected, disconnected} names, for the result message.
    private def sync_networks!(api : Docr::API, container_id : String, requested : Array(RequestedNetwork)) : {Array(String), Array(String)}
      strict = networks_strict?
      return {[] of String, [] of String} if requested.empty? && !strict

      already_connected = api.containers.inspect(container_id).network_settings.networks.keys
      connected = [] of String
      disconnected = [] of String

      requested.each do |net|
        next if already_connected.includes?(net.name)
        connect_network(api.client, net, container_id)
        connected << net.name
      end

      if strict
        requested_names = requested.map(&.name)
        already_connected.each do |name|
          next if requested_names.includes?(name)
          disconnect_network(api.client, name, container_id)
          disconnected << name
        end
      end

      {connected, disconnected}
    end

    # `comparisons:` is a dict (e.g. `{"networks": "strict"}`) real
    # Ansible uses to override per-field idempotency strictness across
    # ~40 possible keys - only `networks` is meaningfully implementable
    # here, since it's the one field this plugin actually tracks/syncs
    # at all (see the class doc comment for the other ~40 fields' own
    # documented, deliberate non-comparison scope cut).
    private def networks_strict? : Bool
      raw = @params["comparisons"]?
      return false unless raw
      parsed = JSON.parse(raw) rescue nil
      parsed.try(&.["networks"]?).try(&.as_s?) == "strict"
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

    private def disconnect_network(client : Docr::Client, network_name : String, container_id : String)
      body = {"Container" => container_id}.to_json
      headers = HTTP::Headers{"Content-Type" => "application/json"}

      client.call("POST", "/networks/#{network_name}/disconnect", headers, body) { |response| response.consume_body_io }
    end

    private def network_suffix(connected : Array(String), disconnected : Array(String) = [] of String) : String
      parts = [] of String
      parts << "connected to network#{connected.size == 1 ? "" : "s"}: #{connected.join(", ")}" unless connected.empty?
      parts << "disconnected from network#{disconnected.size == 1 ? "" : "s"}: #{disconnected.join(", ")}" unless disconnected.empty?
      parts.empty? ? "" : " (#{parts.join("; ")})"
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
