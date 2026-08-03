#!/usr/bin/env crystal

require "json"
require "docr"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/docker_ref"
require "../src/crystal_play/plugin_helpers/docker_ports"

module CrystalPlay
  # Docker container plugin - creates/starts/stops/removes a container.
  # Compatible with Ansible's community.docker.docker_container module.
  #
  # See plugins/docker_image.cr's module comment for the shared
  # architecture note (talks to the Docker Engine API directly over its
  # UNIX socket via the weirdbricks/docr fork, local daemon only).
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
  # size of that surface, not an oversight.
  #
  # Not implemented: networks: (attaching to multiple networks - docr
  # itself doesn't implement NetworkConnect/NetworkDisconnect yet),
  # healthcheck:, resource limits (memory/cpu), device_requests:,
  # container_default_behavior:, comparisons: (Ansible's own per-field
  # idempotency override system).
  class DockerContainerPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]?
      unless name
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end

      state = @params["state"]? || "started"
      check_mode = is_true?(@params["check_mode"]?)

      client = Docr::Client.new
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

      case state
      when "started"
        ensure_present(api, name, existing, image_ref, pull, needs_create, needs_recreate, start: true, check_mode: check_mode)
      when "present"
        ensure_present(api, name, existing, image_ref, pull, needs_create, needs_recreate, start: false, check_mode: check_mode)
      when "stopped"
        ensure_stopped(api, name, existing, image_ref, pull, needs_create, needs_recreate, check_mode)
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
      start : Bool, check_mode : Bool,
    ) : PluginResult
      if needs_create
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be created#{start ? " and started" : ""}") if check_mode

        config = build_container_config(image_ref.not_nil!)
        ensure_image_pulled(api, image_ref.not_nil!) if pull
        resp = api.containers.create(name, config)
        api.containers.start(resp.id) if start
        return PluginResult.new(changed: true, failed: false, msg: "Created#{start ? " and started" : ""} container #{name}")
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
        return PluginResult.new(changed: true, failed: false, msg: "Recreated container #{name}")
      end

      if start && existing.state != "running"
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be started") if check_mode

        api.containers.start(existing.id)
        return PluginResult.new(changed: true, failed: false, msg: "Started container #{name}")
      end

      PluginResult.new(changed: false, failed: false, msg: "Container #{name} already #{start ? "started" : "present"}")
    end

    private def ensure_stopped(
      api : Docr::API, name : String, existing : Docr::Types::ContainerSummary?,
      image_ref : String?, pull : Bool, needs_create : Bool, needs_recreate : Bool,
      check_mode : Bool,
    ) : PluginResult
      if needs_create
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be created (stopped)") if check_mode

        config = build_container_config(image_ref.not_nil!)
        ensure_image_pulled(api, image_ref.not_nil!) if pull
        api.containers.create(name, config)
        return PluginResult.new(changed: true, failed: false, msg: "Created container #{name} (stopped)")
      end

      existing = existing.not_nil!

      if needs_recreate
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be recreated (stopped)") if check_mode

        config = build_container_config(image_ref.not_nil!)
        api.containers.stop(existing.id) if existing.state == "running"
        api.containers.delete(existing.id, force: true)
        ensure_image_pulled(api, image_ref.not_nil!) if pull
        api.containers.create(name, config)
        return PluginResult.new(changed: true, failed: false, msg: "Recreated container #{name} (stopped)")
      end

      if existing.state == "running"
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be stopped") if check_mode

        api.containers.stop(existing.id)
        return PluginResult.new(changed: true, failed: false, msg: "Stopped container #{name}")
      end

      PluginResult.new(changed: false, failed: false, msg: "Container #{name} already stopped")
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

    private def docker_host_description : String
      ENV["DOCKER_HOST"]? || "default socket #{Docr::Client::DEFAULT_SOCKET_PATH}"
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = CrystalPlay::DockerContainerPlugin.new(config)
plugin.run
