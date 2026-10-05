#!/usr/bin/env crystal

require "json"
require "docr"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/docker_ref"
require "../src/krikri/plugin_helpers/docker_ports"
require "../src/krikri/plugin_helpers/docker_client"
require "../src/krikri/plugin_helpers/docker_healthcheck"
require "../src/krikri/plugin_helpers/docker_resources"
require "../src/krikri/plugin_helpers/docker_health_wait"

module Krikri
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
  #   needs to be created or recreated (verified against
  #   ansible-playbook: state: stopped/absent on an already-existing
  #   container needs no image: at all, same as here)
  # - state: started (default) / stopped / present / absent / healthy
  #   - healthy: the started flow plus a wait for the container's
  #     healthcheck to report healthy (see
  #     PluginHelpers::DockerHealthWait's doc comment for the exact
  #     wait/poll/failure semantics mirrored from Ansible's
  #     wait_for_state). A container with no healthcheck is
  #     immediately healthy. On wait success the result carries the
  #     final inspect output as `container:` (real replaces its
  #     module facts with the last inspect result); on wait failure
  #     (timeout / vanished container) the same `container:` key
  #     carries the last inspect result and the task fails with
  #     Ansible's wording.
  # - healthy_wait_timeout: float, default 300 - seconds to wait for
  #   the healthcheck to report healthy under state: healthy (Ansible's
  #   own param; <= 0 means wait forever). Type-validated on every
  #   state like Ansible's argspec (a non-numeric value fails the task
  #   even with state: started/stopped).
  # - command: container command. Ansible's option is `type: raw` (see
  #   community.docker's `OPTION_COMMAND`, ansible_type="raw") with
  #   `command_handling: correct` as the default: a YAML LIST is passed
  #   to the daemon as the argv list verbatim (spaces inside one element
  #   included), a STRING is POSIX-shell-split (Python `shlex.split`).
  #   The parser JSON-encodes a literal YAML list (see
  #   playbook_parser's docker_container list branch), so a leading `[`
  #   here means a real list; anything else is split the way real splits
  #   a string.
  # - entrypoint: same, except Ansible's option is a plain
  #   `type: list, elements: str` - a STRING is turned into a list by
  #   Ansible's own comma-separated conversion (NOT shell-split), which
  #   is why `entrypoint: /bin/sh -c` stays one argv element (verified
  #   live against 2.19.11 + community.docker 5.2.1).
  # - env: dict of environment variables (Ansible also accepts the
  #   list-of-`KEY=VALUE` form its own dict conversion handles, which
  #   travels on the same JSON wire as the other list options below)
  # - labels: dict of labels (same list form as env:, below)
  # - ports: comma-separated list of docker_ports.cr-syntax mappings
  #   ("8080:80", "127.0.0.1:8080:80/udp", ...)
  # - volumes: comma-separated list of "host_path:container_path[:mode]"
  #   bind mounts (passed straight through as Docker's own Binds: syntax)
  # - restart_policy: "no" (default)/"always"/"on-failure"/"unless-stopped"
  # - network_mode: string
  # - privileged / auto_remove: bool
  # - memory / memory_reservation / memory_swap: human-readable byte-size
  #   strings ("512M", "1G", ...) - see PluginHelpers::DockerResources's
  #   own doc comment, behavior matched to Ansible's own `human_to_bytes`
  #   (binary/1024-based units despite the non-"i" K/M/G/T/P spelling).
  #   `memory_swap: "unlimited"` (or the literal string `"-1"`) is
  #   Ansible's own documented unlimited-swap convention.
  # - memory_swappiness / cpu_shares / oom_score_adj / pids_limit: int
  # - cpus: float number of CPUs, converted to Docker's own `NanoCpus`
  #   (`cpus * 1e9`, rounded) - matches Ansible's own
  #   `_preprocess_cpus` exactly.
  # - cpuset_cpus / cpuset_mems: string (e.g. "0-3", "0,2")
  # - oom_kill_disable: bool
  #
  # All of the above live-verified end to end (create, idempotent rerun,
  # drift-triggers-recreate) against a real Docker Engine 29.1.3 daemon
  # (root, full cgroups delegation, a throwaway Atlantic.net host) -
  # `cpuset_cpus`/`oom_score_adj`/`memory_swap: "unlimited"` had
  # initially only been command-construction-verified against a rootless
  # Podman dev machine that couldn't exercise them properly (no `cpuset`
  # cgroup delegated at all, and unexplained `oom_score_adj`/
  # `memory_swap` value transformations - both confirmed as
  # rootless-Podman-specific artifacts once re-tested against real
  # Docker Engine as root: `cpuset_cpus`/`oom_score_adj` matched the
  # requested value exactly and stayed idempotent, `memory_swap:
  # "unlimited"` correctly read back as the literal `-1`).
  # `oom_kill_disable: true` is a genuine exception: it's accepted and
  # sent correctly, but a real, standalone kernel limitation on this
  # particular Atlantic.net host silently discards it - confirmed
  # identical via the native `docker` CLI itself (`docker run
  # --oom-kill-disable` on the same host prints `WARNING: Your kernel
  # does not support OomKillDisable. OomKillDisable discarded.` and
  # `docker inspect` shows the field as unset), so this is not an engine
  # divergence Ansible would avoid either - both would see the
  # exact same discarded value on this kernel.
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
  # - healthcheck: a dict ({test:, interval:, timeout:, retries:,
  #   start_period:}) - see PluginHelpers::DockerHealthcheck's own doc
  #   comment for the duration-string-parsing/test-normalization rules,
  #   behavior matched to Ansible's own `parse_healthcheck`/
  #   `normalize_healthcheck`. `test: ["NONE"]` is the real, documented
  #   way to explicitly disable an inherited healthcheck. `start_interval:`
  #   (Ansible's own newer addition) is NOT implemented - the
  #   underlying `docr` library's own `HealthConfig` type has no field
  #   for it, a real scope cut one layer below this plugin.
  # - check_mode
  #
  # Idempotency compares image (leniently, see DockerRef.same?), command,
  # entrypoint, env, labels, volumes, restart_policy, network_mode,
  # privileged, auto_remove, ports, healthcheck, and every resource-limit
  # param above (memory/memory_reservation/memory_swap/
  # memory_swappiness/cpus/cpu_shares/cpuset_cpus/cpuset_mems/
  # oom_kill_disable/oom_score_adj/pids_limit) against the existing
  # container - each only for whichever of those params was actually
  # given, matching Ansible's own "only compare what you told me
  # about" behavior for any option not mentioned at all. The per-field
  # default comparison mode is NOT uniformly strict - verified against
  # Ansible's own module_utils source (`Option.__init__`): scalar
  # options (restart_policy, network_mode, privileged, auto_remove, and
  # every resource-limit param above - all `int`/`str`/`bool`-typed,
  # Ansible's own "value" comparison_type) and the plain ordered
  # entrypoint list default to `strict` (exact equality), but every
  # set/dict-typed option (env, labels, volumes, ports, healthcheck)
  # defaults to `allow_more_present` instead - a subset match where the
  # task's own requested keys/values must be present and equal, but extra
  # keys/values already on the real container (an image's inherited
  # env/labels, Docker's own default-filled healthcheck timeout/retries,
  # ports the task didn't mention) are NOT treated as drift. See
  # comparison_mode's own doc comment - this distinction is load-bearing,
  # not cosmetic: an earlier version of this comparison system defaulted
  # everything to strict and it caused healthcheck: (and, under Podman
  # specifically, env: too) to falsely recreate the container on every
  # single rerun with zero actual drift. ports: compares both
  # published_ports (host<->container bindings, HostIp defaulted to
  # "0.0.0.0" the same way real Docker/Ansible do when a request left it
  # nil) and exposed_ports (folding in the image's own declared
  # ExposedPorts, same image-merge pattern as env: below) - see
  # ports_match?'s own doc comment. Every other field of Ansible's
  # own ~40-field comparison system (device_requests:, healthcheck's own
  # start_interval:, etc) remains NOT detected and won't trigger a
  # recreate on its own unless recreate: true is passed - a documented,
  # deliberate scope cut given the size of that remaining surface, not an
  # oversight. networks: is a separate exception from all of the above -
  # it's diffed and applied even when nothing else changed, since
  # silently ignoring it after the container already exists would make it
  # useless on every run after the first.
  #
  # - comparisons: a dict (e.g. `{"networks": "strict"}`,
  #   `{"env": "ignore"}`, `{"labels": "strict"}`) - `ignore` opts a field
  #   out of comparison entirely; `strict`/`allow_more_present` override
  #   a field's own default mode (see above) in either direction, for
  #   every field this plugin actually tracks/syncs (the list above,
  #   including ports/healthcheck/resource limits, plus networks). `comparisons:
  #   {networks: strict}` disconnects the container from any network NOT
  #   in networks: - verified against Ansible's own documented
  #   behavior ("To remove a container from one or more networks, use
  #   `networks: strict` in the `comparisons` option") - live-verified
  #   against a real Docker daemon.
  #
  # Not implemented: `networks_cli_compatible:` (Ansible's "don't
  # attach the default
  # network when networks: is given" toggle - this plugin always leaves
  # whatever network_mode:/Docker's own default produced alone and only
  # ever *adds* the requested networks on top); `mac_address:` on a
  # per-network endpoint (only ipv4_address:/ipv6_address:/aliases:/
  # links: per network); `healthcheck.start_interval:`, `device_requests:`,
  # `container_default_behavior:`, `api_version:` (see
  # PluginHelpers::DockerClient).
  class DockerContainerPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

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

    # Real seeds its result dict as `{"changed": False, "actions":
    # []}`, deletes `actions` again once a real (non-check_mode,
    # non-debug) run finishes, and then adds `container` (the inspect
    # payload) whenever a container is present afterwards - so a normal
    # create/rerun registers changed + container + failed, a removal
    # registers changed + failed only, and only a check_mode run keeps
    # the structured `actions` list. Live-verified against
    # ansible-core 2.19.11 + community.docker 5.2.1.
    KEY_ORDER = %w[changed actions container failed]

    # Ansible's own wrapper for a DockerException escaping the module body.
    API_ERROR_PREFIX = "An unexpected Docker error occurred: "

    def execute : PluginResult
      name = @params["name"]?
      unless name
        return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name")
      end

      state = @params["state"]? || "started"
      check_mode = true?(@params["_ansible_check_mode"]?)

      # healthy_wait_timeout is type-validated for EVERY state (Ansible's
      # argspec validation runs before any module logic - live-verified:
      # state: stopped + healthy_wait_timeout: bogus fails in real too).
      healthy_timeout = parse_healthy_wait_timeout
      return healthy_timeout if healthy_timeout.is_a?(PluginResult)
      healthy_max_wait = healthy_timeout.as(Float64?)

      client, docker_host_description = PluginHelpers::DockerClient.build(@params)
      api = Docr::API.new(client)
      existing = find_container(api, name)

      return absent_shape(api, name, existing, check_mode) if state == "absent"

      image_ref = @params["image"]?
      command = parse_command
      pull = true?(@params["pull"]?, default: true)
      recreate_requested = true?(@params["recreate"]?)

      needs_create = !existing
      needs_recreate = recreate_needed?(api, existing, recreate_requested, image_ref, command)

      if failure = missing_image_result(needs_create, needs_recreate, image_ref)
        return failure
      end

      dispatch_state(state, api, name, existing, image_ref, pull, needs_create,
        needs_recreate, parsed_networks, healthy_max_wait, check_mode)
    rescue ex : PluginHelpers::DockerSdkError::ImagePullError
      PluginResult.new(changed: false, failed: true, msg: ex.message || "")
    rescue ex : Docr::Errors::DockerAPIError
      PluginResult.new(changed: false, failed: true, msg: "#{API_ERROR_PREFIX}#{PluginHelpers::DockerSdkError.api_error_text(client, @params, ex)}")
    rescue ex : Socket::ConnectError
      PluginResult.new(changed: false, failed: true, msg: "Could not connect to the Docker daemon (#{docker_host_description}): #{ex.message}")
    end

    # The per-state dispatch, kept out of #execute so both stay readable.
    private def dispatch_state(
      state : String, api : Docr::API, name : String,
      existing : Docr::Types::ContainerSummary?, image_ref : String?, pull : Bool,
      needs_create : Bool, needs_recreate : Bool, requested_networks : Array(RequestedNetwork),
      healthy_max_wait : Float64?, check_mode : Bool,
    ) : PluginResult
      case state
      when "started"
        real_shape(ensure_present(api, name, existing, image_ref, pull, needs_create, needs_recreate, requested_networks, start: true, check_mode: check_mode),
          api, name, check_mode, existing)
      when "present"
        real_shape(ensure_present(api, name, existing, image_ref, pull, needs_create, needs_recreate, requested_networks, start: false, check_mode: check_mode),
          api, name, check_mode, existing)
      when "stopped"
        real_shape(ensure_stopped(api, name, existing, image_ref, pull, needs_create, needs_recreate, requested_networks, check_mode),
          api, name, check_mode, existing)
      when "healthy"
        # Real state=healthy: the started flow, then (outside check
        # mode) a wait for the container's health status - Ansible's
        # wait_for_state with wait_states=['starting', 'unhealthy'],
        # complete_states=['healthy', None], max_wait=
        # healthy_wait_timeout (a container with NO healthcheck is
        # immediately healthy; 'unhealthy' is a wait state, not an
        # immediate failure). The wait loop itself lives in
        # PluginHelpers::DockerHealthWait.
        real_shape(wait_for_healthy_result(api, name, ensure_present(api, name, existing, image_ref, pull, needs_create, needs_recreate, requested_networks, start: true, check_mode: check_mode), healthy_max_wait, check_mode),
          api, name, check_mode, existing)
      else
        # Real argspec wording and choices order (live-verified against
        # 2.19.11 with state: bogus).
        PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: absent, present, healthy, started, stopped, got: #{state}")
      end
    end

    # state=absent: real records no container facts here at all, even in
    # check_mode where the container is still there afterwards.
    private def absent_shape(
      api : Docr::API, name : String, existing : Docr::Types::ContainerSummary?, check_mode : Bool,
    ) : PluginResult
      real_shape(ensure_absent(api, existing, check_mode), api, name, check_mode, existing, removed: true)
    end

    # Turns an internal result (which carries a prose msg) into the
    # registered shape Ansible's docker_container produces: the structured
    # `actions` list in check_mode/debug only, and `container` (the
    # daemon's raw inspect payload) whenever a container is present
    # afterwards. A failed result is passed through untouched - Ansible's
    # fail_json shape is already PluginResult's default.
    private def real_shape(
      result : PluginResult, api : Docr::API, name : String, check_mode : Bool,
      existing : Docr::Types::ContainerSummary?, removed : Bool = false,
    ) : PluginResult
      return result if result.failed?

      debug_mode = true?(@params["debug"]?)
      previous_id = existing.try(&.id)

      # Ansible's state=absent path never records container facts, even in
      # check_mode where the container is still there afterwards.
      facts = removed ? nil : container_inspect_json(api, name)
      final = PluginResult.new(changed: result.changed?, failed: false, failed_flag: false)
      final.key_order = KEY_ORDER
      final.extra["actions"] = check_mode_actions(result.msg.to_s, name, previous_id,
        existing.try(&.state) == "running") if check_mode || debug_mode
      final.extra["container"] = facts if facts
      final
    end

    # Ansible's action dicts, per operation. They carry the parameters real
    # would have sent to the daemon; the create action's payload is the
    # set of options the task actually gave, each under its own
    # Docker-API key, plus the stdio flags real itself always sends (its
    # AttachStdin/OpenStdin handling above this layer). An option the
    # task never mentioned contributes no key at all - which is why a
    # plain create records only Cmd..OpenStdin, Image and ExposedPorts.
    private def check_mode_actions(
      msg : String, name : String, previous_id : String?, previous_running : Bool,
    ) : JSON::Any
      actions = [] of JSON::Any

      if msg.includes?("would be created") || msg.includes?("would be recreated")
        # Real records a create as ONE action - starting a freshly
        # created container is part of it, not a separate entry. A
        # recreate over a RUNNING container stops it first, and records
        # that stop as its own action ahead of the removal (a container
        # that is already stopped gets no stopped action at all).
        if msg.includes?("recreated")
          actions << stopped_action(previous_id) if previous_running
          actions << removed_action(previous_id)
        end
        actions << created_action(name)
      elsif msg.includes?("would be stopped")
        actions << stopped_action(previous_id)
      elsif msg.includes?("would be started")
        actions << started_action(previous_id)
      elsif msg.includes?("would be removed")
        actions << removed_action(previous_id)
      end

      JSON::Any.new(actions)
    end

    private def removed_action(container_id : String?) : JSON::Any
      JSON::Any.new({
        "removed"      => JSON::Any.new(container_id || ""),
        "volume_state" => JSON::Any.new(false),
        "link"         => JSON::Any.new(false),
        "force"        => JSON::Any.new(true?(@params["force_kill"]?)),
      })
    end

    private def started_action(container_id : String?) : JSON::Any
      JSON::Any.new({"started" => JSON::Any.new(container_id || "")})
    end

    # Ansible's own `timeout` is the stop_timeout: option, which has no
    # default - a task that never set it records an explicit null.
    private def stopped_action(container_id : String?) : JSON::Any
      JSON::Any.new({
        "stopped" => JSON::Any.new(container_id || ""),
        "timeout" => JSON::Any.new(@params["stop_timeout"]?),
      })
    end

    private def created_action(name : String) : JSON::Any
      JSON::Any.new({
        "created"           => JSON::Any.new("Created container"),
        "create_parameters" => create_parameters(name),
        "networks"          => JSON.parse("{}"),
      })
    end

    # The create payload real records in check mode: its own argv list,
    # the stdio flags Ansible always sends itself, and then - for every
    # option the task actually gave - that option's Docker-API key with
    # the very value the non-check create path sends. Key order is Ansible's
    # own option order (its OptionGroup list in module_utils), not this
    # plugin's internal one, and an option the task never gave is simply
    # absent - so a plain create records only Cmd..OpenStdin, Image and
    # the always-present ExposedPorts (Ansible's port preprocess seeds that
    # one even with no ports at all, hence `{}` rather than a missing key).
    private def create_parameters(name : String) : JSON::Any
      params = {
        "Cmd"          => json_string_list(parse_command || [] of String),
        "AttachStdout" => JSON::Any.new(true),
        "AttachStderr" => JSON::Any.new(true),
        "AttachStdin"  => JSON::Any.new(false),
        "StdinOnce"    => JSON::Any.new(false),
        "OpenStdin"    => JSON::Any.new(nil),
      }
      if env = container_env
        params["Env"] = json_string_list(env)
      end
      params["Hostname"] = JSON::Any.new(@params["hostname"]) if @params["hostname"]?
      params["Image"] = JSON::Any.new(@params["image"]? || "")
      if labels = parsed_key_value_param("labels")
        params["Labels"] = json_string_map(labels)
      end
      params["HostConfig"] = create_host_config if create_host_config_given?
      # Bind mounts land in HostConfig.Binds; Ansible still records the
      # (empty) Volumes mapping for them.
      params["Volumes"] = JSON.parse("{}") if @params["volumes"]?
      params["ExposedPorts"] = json_exposed_ports
      JSON::Any.new(params)
    end

    private def json_string_list(values : Array(String)) : JSON::Any
      JSON::Any.new(values.map { |value| JSON::Any.new(value) })
    end

    private def json_string_map(values : Hash(String, String)) : JSON::Any
      JSON::Any.new(values.map { |key, value| {key, JSON::Any.new(value)} }.to_h)
    end

    private def json_exposed_ports : JSON::Any
      exposed, _bindings = build_ports
      JSON::Any.new(exposed.map { |key, _| {key, JSON.parse("{}")} }.to_h)
    end

    # True when the task gave at least one option Ansible would place in
    # the create payload's HostConfig - Ansible only emits that key at all
    # once something lands in it.
    private def create_host_config_given? : Bool
      %w[auto_remove cpuset_cpus cpuset_mems cpu_shares cpus memory memory_reservation
        memory_swap memory_swappiness network_mode oom_kill_disable oom_score_adj pids_limit
        privileged restart_policy volumes ports].any? { |field| @params[field]? }
    end

    # Ansible's HostConfig for the create payload, in Ansible's own option
    # order (its OptionGroup list). Same rule as the outer dict: an
    # option the task never mentioned contributes no key.
    private def create_host_config : JSON::Any
      config = {} of String => JSON::Any
      config["AutoRemove"] = JSON::Any.new(true?(@params["auto_remove"]?)) if @params["auto_remove"]?
      add_resource_limits(config)
      add_process_limits(config)
      add_bind_and_policy_entries(config)
      JSON::Any.new(config)
    end

    private def add_resource_limits(config : Hash(String, JSON::Any)) : Nil
      config["CpusetCpus"] = JSON::Any.new(@params["cpuset_cpus"]) if @params["cpuset_cpus"]?
      config["CpusetMems"] = JSON::Any.new(@params["cpuset_mems"]) if @params["cpuset_mems"]?
      if cpu_shares = @params["cpu_shares"]?
        config["CpuShares"] = JSON::Any.new(cpu_shares.to_i64)
      end
      if cpus = @params["cpus"]?
        config["NanoCpus"] = JSON::Any.new(PluginHelpers::DockerResources.cpus_to_nano_cpus(cpus.to_f))
      end
      if memory = @params["memory"]?
        config["Memory"] = JSON::Any.new(PluginHelpers::DockerResources.human_to_bytes(memory))
      end
      if memory_reservation = @params["memory_reservation"]?
        config["MemoryReservation"] = JSON::Any.new(PluginHelpers::DockerResources.human_to_bytes(memory_reservation))
      end
      if memory_swap = @params["memory_swap"]?
        config["MemorySwap"] = JSON::Any.new(PluginHelpers::DockerResources.memory_swap_to_bytes(memory_swap))
      end
      if memory_swappiness = @params["memory_swappiness"]?
        config["MemorySwappiness"] = JSON::Any.new(memory_swappiness.to_i64)
      end
    end

    private def add_process_limits(config : Hash(String, JSON::Any)) : Nil
      config["NetworkMode"] = JSON::Any.new(@params["network_mode"]) if @params["network_mode"]?
      config["OomKillDisable"] = JSON::Any.new(true?(@params["oom_kill_disable"]?)) if @params["oom_kill_disable"]?
      if oom_score_adj = @params["oom_score_adj"]?
        config["OomScoreAdj"] = JSON::Any.new(oom_score_adj.to_i64)
      end
      if pids_limit = @params["pids_limit"]?
        config["PidsLimit"] = JSON::Any.new(pids_limit.to_i64)
      end
      config["Privileged"] = JSON::Any.new(true?(@params["privileged"]?)) if @params["privileged"]?
    end

    private def add_bind_and_policy_entries(config : Hash(String, JSON::Any)) : Nil
      if restart_policy = @params["restart_policy"]?
        config["RestartPolicy"] = JSON::Any.new({
          "Name"              => JSON::Any.new(restart_policy),
          "MaximumRetryCount" => JSON::Any.new(nil),
        })
      end
      config["Binds"] = json_string_list(parse_volumes(@params["volumes"]?) || [] of String) if @params["volumes"]?
      if @params["ports"]?
        _exposed, port_bindings = build_ports
        bindings = Hash(String, JSON::Any).new
        port_bindings.each do |port, port_entries|
          bindings[port] = JSON::Any.new(port_entries.map do |binding|
            JSON::Any.new({
              "HostIp"   => JSON::Any.new(binding.host_ip.presence || "0.0.0.0"),
              "HostPort" => JSON::Any.new(binding.host_port),
            })
          end)
        end
        config["PortBindings"] = JSON::Any.new(bindings)
      end
    end

    private def container_inspect_json(api : Docr::API, name : String) : JSON::Any?
      raw = nil
      api.client.call("GET", "/containers/#{name}/json", HTTP::Headers{"Accept" => "application/json"}) do |response|
        raw = response.body_io?.try(&.gets_to_end)
      end
      return nil if raw.nil? || raw.empty?
      JSON.parse(raw)
    rescue Docr::Errors::DockerAPIError
      nil
    end

    # Parses healthy_wait_timeout (float, default 300; <= 0 means wait
    # forever - Ansible module.py's own convention). Non-numeric values
    # fail with Ansible's argspec conversion wording (live-verified).
    # Returns Float64? on success or a failed PluginResult on invalid input.
    private def parse_healthy_wait_timeout : Float64? | PluginResult
      raw = @params["healthy_wait_timeout"]? || return 300.0
      parsed = raw.to_f64?
      return float_type_error("healthy_wait_timeout", raw) unless parsed
      parsed <= 0 ? nil : parsed
    end

    private def recreate_needed?(
      api : Docr::API, existing : Docr::Types::ContainerSummary?,
      recreate_requested : Bool, image_ref : String?, command : Array(String)?,
    ) : Bool
      existing ? recreate_requested || !matches?(api, existing, image_ref, command) : false
    end

    private def missing_image_result(needs_create : Bool, needs_recreate : Bool, image_ref : String?) : PluginResult?
      if needs_create && !image_ref
        return PluginResult.new(changed: false, failed: true, msg: "Cannot create container when image is not specified!")
      end
      if needs_recreate && !image_ref
        return PluginResult.new(changed: false, failed: true,
          msg: "Cannot recreate container when image is not specified or cannot be extracted from current container!")
      end
      nil
    end

    private def ensure_present(
      api : Docr::API, name : String, existing : Docr::Types::ContainerSummary?,
      image_ref : String?, pull : Bool, needs_create : Bool, needs_recreate : Bool,
      requested_networks : Array(RequestedNetwork), start : Bool, check_mode : Bool,
    ) : PluginResult
      if needs_create
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be created#{started_suffix(start)}") if check_mode

        _container_id, connected, disconnected = create_new_container(api, name, image_ref, pull, requested_networks, start)
        return PluginResult.new(changed: true, failed: false, msg: "Created#{started_suffix(start)} container #{name}#{network_suffix(connected, disconnected)}")
      end

      existing = existing || raise "BUG: existing container missing"

      if needs_recreate
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be recreated") if check_mode

        _id, connected, disconnected = recreate_container(api, name, existing, image_ref, pull, requested_networks, start)
        return PluginResult.new(changed: true, failed: false, msg: "Recreated container #{name}#{network_suffix(connected, disconnected)}")
      end

      if start && existing.state != "running"
        return start_existing(api, name, existing, requested_networks, check_mode)
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

        _container_id, connected, disconnected = create_new_container(api, name, image_ref, pull, requested_networks, start: false)
        return PluginResult.new(changed: true, failed: false, msg: "Created container #{name} (stopped)#{network_suffix(connected, disconnected)}")
      end

      existing = existing || raise "BUG: existing container missing"

      if needs_recreate
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be recreated (stopped)") if check_mode

        _id, connected, disconnected = recreate_container(api, name, existing, image_ref, pull, requested_networks, start: false)
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

    private def started_suffix(start : Bool) : String
      start ? " and started" : ""
    end

    # state=healthy's wait phase. Ansible passes the container id it
    # already holds from its present() flow into wait_for_state; here
    # the id is re-derived from a name lookup (the ensure_present
    # result doesn't carry it). If the container vanished in that
    # window (real cannot hit this - it never re-looks-up by name),
    # the lookup falls back to Ansible's own vanished-container failure
    # wording, with the name standing in for the id it would have
    # used. Skipped in check mode and when the started flow already
    # failed, matching real (`state == 'healthy' and not check_mode`).
    private def wait_for_healthy_result(
      api : Docr::API, name : String, base : PluginResult,
      max_wait : Float64?, check_mode : Bool,
    ) : PluginResult
      return base if check_mode || base.failed?

      container = find_container(api, name)
      unless container
        return failed_wait_result(
          %(Encontered vanished container while waiting for container "#{name}"), nil)
      end
      container_id = container.id

      client = api.client
      inspect_fn = PluginHelpers::DockerHealthWait::InspectFn.new do
        # Raw GET rather than api.containers.inspect: Ansible's wait loop
        # carries the FULL raw inspect dict into the result's
        # `container:` key, and docr's typed ContainerInspectResponse
        # drops fields Ansible keeps (same reason as the
        # network-connect/image-exists raw-HTTP escape hatches above).
        body = client.call("GET", "/containers/#{container_id}/json") { |response| response.body_io.gets_to_end }
        JSON.parse(body)
      rescue ex : Docr::Errors::DockerAPIError
        # Ansible's get_container_by_id: NotFound => None (the vanished
        # container failure), any other inspect error =>
        # "Error inspecting container: <error>".
        next nil if ex.status_code == 404
        raise PluginHelpers::DockerHealthWait::Failure.new("Error inspecting container: #{ex.message}")
      end
      sleep_fn = PluginHelpers::DockerHealthWait::SleepFn.new { |delay| sleep(delay) }

      begin
        final_inspect = PluginHelpers::DockerHealthWait.wait_for_healthy(container_id, max_wait, inspect_fn, sleep_fn)
      rescue ex : PluginHelpers::DockerHealthWait::Failure
        return failed_wait_result(ex.message || "container health check failed", ex.container_json)
      end

      # Real replaces self.facts with the wait's final inspect result,
      # which is what lands in the module result's `container:` key.
      base.extra["container"] = final_inspect
      base
    end

    private def failed_wait_result(msg : String, container_json : JSON::Any?) : PluginResult
      result = PluginResult.new(changed: false, failed: true, msg: msg)
      result.extra["container"] = container_json if container_json
      result
    end

    # Shared by both ensure_present and ensure_stopped: create the
    # container (pulling the image first when pull: is set), optionally
    # start it, and connect any requested networks.
    private def create_new_container(
      api : Docr::API, name : String, image_ref : String?, pull : Bool,
      requested_networks : Array(RequestedNetwork), start : Bool,
    )
      config = build_container_config(image_ref || raise "image is required to create a new container")
      ensure_image_pulled(api, image_ref || raise "image is required to create a new container") if pull
      resp = api.containers.create(name, config)
      api.containers.start(resp.id) if start
      connected, disconnected = sync_networks!(api, resp.id, requested_networks)
      {resp.id, connected, disconnected}
    end

    # Shared by both ensure_present and ensure_stopped: replace an
    # existing container with a fresh one from the same config (stop it
    # first when running, delete, re-pull when pull: is set, create,
    # optionally start, connect requested networks).
    private def recreate_container(
      api : Docr::API, name : String, existing : Docr::Types::ContainerSummary,
      image_ref : String?, pull : Bool, requested_networks : Array(RequestedNetwork), start : Bool,
    )
      config = build_container_config(image_ref || raise "image is required to create a new container")
      api.containers.stop(existing.id) if existing.state == "running"
      api.containers.delete(existing.id, force: true)
      ensure_image_pulled(api, image_ref || raise "image is required to create a new container") if pull
      resp = api.containers.create(name, config)
      api.containers.start(resp.id) if start
      connected, disconnected = sync_networks!(api, resp.id, requested_networks)
      {resp.id, connected, disconnected}
    end

    private def start_existing(
      api : Docr::API, name : String, existing : Docr::Types::ContainerSummary,
      requested_networks : Array(RequestedNetwork), check_mode : Bool,
    ) : PluginResult
      return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be started") if check_mode

      begin
        api.containers.start(existing.id)
      rescue ex : Docr::Errors::DockerAPIError
        # HTTP 304 Not Modified - the container was started between the
        # state read above and the start call (or is already running
        # under a different state spelling like "restarting").
        # Ansible's docker_container treats a 304 on start as a no-op
        # success, not an error (grycap.chronos' warm rerun: "Docker API
        # error: Code: 304 Message: No response body" failed the task
        # where ansible-playbook's warm run reported ok).
        raise ex unless ex.message.try(&.includes?("Code: 304"))
        connected, disconnected = sync_networks!(api, existing.id, requested_networks)
        return PluginResult.new(changed: false, failed: false, msg: "Container #{name} already started#{network_suffix(connected, disconnected)}")
      end
      connected, disconnected = sync_networks!(api, existing.id, requested_networks)
      PluginResult.new(changed: true, failed: false, msg: "Started container #{name}#{network_suffix(connected, disconnected)}")
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
    # given ("only compare what you told me about" - matches
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
        # real compares `command` as a LIST (`Option` value_type="list",
        # comparison strict) against the container's own Config.Cmd -
        # not as a joined string, which would misread an element
        # containing a space as several.
        actual = api.containers.inspect(existing.id).config.try(&.cmd) || [] of String
        return false unless actual == command
      end

      return true unless extra_fields_given?

      extra_fields_match?(api, api.containers.inspect(existing.id), image_ref)
    end

    EXTRA_COMPARISON_FIELDS = %w[entrypoint env labels volumes restart_policy network_mode privileged auto_remove ports healthcheck
      memory memory_reservation memory_swap memory_swappiness cpus cpu_shares cpuset_cpus cpuset_mems
      oom_kill_disable oom_score_adj pids_limit]

    private def extra_fields_given? : Bool
      EXTRA_COMPARISON_FIELDS.any? { |field| @params[field]? }
    end

    # Ansible's own per-field comparison default is NOT uniformly
    # `strict` - verified against the real module_utils source
    # (`Option.__init__` in `_module_container/base.py`): scalar
    # ("value") options and plain ordered `list`s (entrypoint) default to
    # `strict` (exact equality), but every `set`/`dict`-typed option
    # (env, labels, volumes, ports, healthcheck) defaults to
    # `allow_more_present` instead - a subset match where the task's own
    # requested keys/values must be present and equal, but EXTRA
    # keys/values already on the real container (e.g. Docker's own
    # default-filled healthcheck timeout/retries, or an image's inherited
    # env/labels) are NOT treated as drift. Getting this wrong isn't
    # cosmetic: found live testing `healthcheck:` - a container created
    # with only `interval:`/`test:` given got `timeout:`/`retries:`
    # filled in by Docker's own daemon defaults, and comparing those
    # against a naive "strict-by-default" implementation recreated the
    # container on every single rerun despite zero actual drift.
    # `comparisons: {<field>: strict}` explicitly overrides an
    # allow_more_present-by-default field to exact-equality instead
    # (Ansible's own supported override direction); `ignore` always
    # wins regardless of the field's default.
    private def comparison_mode(field : String, default : String) : String
      raw = @params["comparisons"]?
      return default unless raw
      parsed = JSON.parse(raw) rescue nil
      parsed.try(&.[field]?).try(&.as_s?) || default
    end

    private def extra_fields_match?(api : Docr::API, inspected : Docr::Types::ContainerInspectResponse, image_ref : String?) : Bool
      config = inspected.config
      host_config = inspected.host_config

      return false unless config_fields_match?(api, config, image_ref)
      return false unless volumes_match?(host_config)
      return false unless simple_host_fields_match?(host_config)
      return false unless comparison_fields_match?(api, config, host_config, image_ref)
      return false unless resource_fields_match?(host_config)
      true
    end

    private def config_fields_match?(api : Docr::API, config : Docr::Types::ContainerConfig, image_ref : String?) : Bool
      return false unless entrypoint_matches?(config)
      return false unless env_matches?(api, config, image_ref)
      return false unless labels_matches?(config)
      true
    end

    private def entrypoint_matches?(config : Docr::Types::ContainerConfig) : Bool
      entrypoint = @params["entrypoint"]?
      return true unless entrypoint
      mode = comparison_mode("entrypoint", "strict")
      return true if mode == "ignore"

      requested = parse_entrypoint || [] of String
      actual = config.entrypoint || [] of String
      mode == "strict" ? actual == requested : requested.all? { |e| actual.includes?(e) }
    end

    private def env_matches?(api : Docr::API, config : Docr::Types::ContainerConfig, image_ref : String?) : Bool
      env_json = @params["env"]?
      return true unless env_json
      mode = comparison_mode("env", "allow_more_present")
      return true if mode == "ignore"

      expected = expected_env(api, image_ref, parsed_key_value_param("env") || Hash(String, String).new)
      actual = (config.env || [] of String).to_set
      mode == "strict" ? actual == expected : expected.subset_of?(actual)
    end

    private def labels_matches?(config : Docr::Types::ContainerConfig) : Bool
      labels_json = @params["labels"]?
      return true unless labels_json
      mode = comparison_mode("labels", "allow_more_present")
      return true if mode == "ignore"

      requested = parsed_key_value_param("labels") || Hash(String, String).new
      actual = config.labels || Hash(String, String).new
      mode == "strict" ? actual == requested : dict_subset?(requested, actual)
    end

    private def volumes_match?(host_config : Docr::Types::HostConfig) : Bool
      requested = parse_volumes(@params["volumes"]?)
      return true unless requested
      mode = comparison_mode("volumes", "allow_more_present")
      return true if mode == "ignore"

      requested = parse_volumes(@params["volumes"]?).try(&.to_set) || Set(String).new
      actual = (host_config.binds || [] of String).to_set
      mode == "strict" ? actual == requested : requested.subset_of?(actual)
    end

    private def simple_host_fields_match?(host_config : Docr::Types::HostConfig) : Bool
      return false unless restart_policy_matches?(host_config)
      return false unless network_mode_matches?(host_config)
      return false unless bool_field_matches?("privileged", host_config.privileged)
      return false unless bool_field_matches?("auto_remove", host_config.auto_remove)
      true
    end

    private def restart_policy_matches?(host_config : Docr::Types::HostConfig) : Bool
      policy_name = @params["restart_policy"]?
      return true unless policy_name && comparison_mode("restart_policy", "strict") != "ignore"
      host_config.restart_policy.try(&.name) == policy_name
    end

    private def network_mode_matches?(host_config : Docr::Types::HostConfig) : Bool
      network_mode = @params["network_mode"]?
      return true unless network_mode && comparison_mode("network_mode", "strict") != "ignore"
      host_config.network_mode == network_mode
    end

    private def bool_field_matches?(field : String, actual : Bool?) : Bool
      return true unless @params[field]? && comparison_mode(field, "strict") != "ignore"
      !!actual == true?(@params[field]?)
    end

    private def comparison_fields_match?(api : Docr::API, config : Docr::Types::ContainerConfig, host_config : Docr::Types::HostConfig, image_ref : String?) : Bool
      return false unless ports_field_matches?(api, config, host_config, image_ref)
      return false unless healthcheck_field_matches?(config)
      true
    end

    private def ports_field_matches?(api : Docr::API, config : Docr::Types::ContainerConfig, host_config : Docr::Types::HostConfig, image_ref : String?) : Bool
      return true unless @params["ports"]?
      mode = comparison_mode("ports", "allow_more_present")
      mode == "ignore" || ports_match?(api, config, host_config, image_ref, strict: mode == "strict")
    end

    private def healthcheck_field_matches?(config : Docr::Types::ContainerConfig) : Bool
      healthcheck_json = @params["healthcheck"]?
      return true unless healthcheck_json
      mode = comparison_mode("healthcheck", "allow_more_present")
      mode == "ignore" || healthcheck_matches?(config.healthcheck, healthcheck_json, strict: mode == "strict")
    end

    private def resource_fields_match?(host_config : Docr::Types::HostConfig) : Bool
      return false unless resource_memory_match?(host_config)
      return false unless resource_cpu_match?(host_config)
      return false unless resource_cpuset_match?(host_config)
      return false unless resource_pids_match?(host_config)
      true
    end

    private def resource_memory_match?(host_config : Docr::Types::HostConfig) : Bool
      if (memory = @params["memory"]?) && comparison_mode("memory", "strict") != "ignore"
        return false unless host_config.memory == PluginHelpers::DockerResources.human_to_bytes(memory)
      end

      if (memory_reservation = @params["memory_reservation"]?) && comparison_mode("memory_reservation", "strict") != "ignore"
        return false unless host_config.memory_reservation == PluginHelpers::DockerResources.human_to_bytes(memory_reservation)
      end

      if (memory_swap = @params["memory_swap"]?) && comparison_mode("memory_swap", "strict") != "ignore"
        return false unless host_config.memory_swap == PluginHelpers::DockerResources.memory_swap_to_bytes(memory_swap)
      end

      true
    end

    private def resource_cpu_match?(host_config : Docr::Types::HostConfig) : Bool
      if (memory_swappiness = @params["memory_swappiness"]?) && comparison_mode("memory_swappiness", "strict") != "ignore"
        return false unless host_config.memory_swappiness == memory_swappiness.to_i64
      end

      if (cpus = @params["cpus"]?) && comparison_mode("cpus", "strict") != "ignore"
        return false unless host_config.nano_cpus == PluginHelpers::DockerResources.cpus_to_nano_cpus(cpus.to_f)
      end

      if (cpu_shares = @params["cpu_shares"]?) && comparison_mode("cpu_shares", "strict") != "ignore"
        return false unless host_config.cpu_shares == cpu_shares.to_i64
      end

      true
    end

    private def resource_cpuset_match?(host_config : Docr::Types::HostConfig) : Bool
      if (cpuset_cpus = @params["cpuset_cpus"]?) && comparison_mode("cpuset_cpus", "strict") != "ignore"
        return false unless host_config.cpuset_cpus == cpuset_cpus
      end

      if (cpuset_mems = @params["cpuset_mems"]?) && comparison_mode("cpuset_mems", "strict") != "ignore"
        return false unless host_config.cpuset_mems == cpuset_mems
      end

      if @params["oom_kill_disable"]? && comparison_mode("oom_kill_disable", "strict") != "ignore"
        return false unless !!host_config.oom_kill_disable == true?(@params["oom_kill_disable"]?)
      end

      true
    end

    private def resource_pids_match?(host_config : Docr::Types::HostConfig) : Bool
      if (oom_score_adj = @params["oom_score_adj"]?) && comparison_mode("oom_score_adj", "strict") != "ignore"
        return false unless host_config.oom_score_adj == oom_score_adj.to_i64
      end

      if (pids_limit = @params["pids_limit"]?) && comparison_mode("pids_limit", "strict") != "ignore"
        return false unless host_config.pids_limit == pids_limit.to_i64
      end

      true
    end

    private def dict_subset?(expected : Hash(String, String), actual : Hash(String, String)) : Bool
      expected.all? { |k, v| actual[k]? == v }
    end

    # `healthcheck:` given but with no `test:` (parse returns nil) means
    # Ansible's own "no override at all" - this plugin never set a
    # `Healthcheck` at container-create time either (see
    # `built_healthcheck`), so there's nothing to compare and it always
    # matches, same as `healthcheck:` not being given at all. Default
    # (`allow_more_present`) only compares the sub-fields the task itself
    # set, so Docker's own default-filled `timeout:`/`retries:` (when the
    # task didn't specify them) don't count as drift; `strict` compares
    # every sub-field including ones the task left unset (matching
    # Ansible's own literal dict-equality behavior under an explicit
    # `strict` override).
    private def healthcheck_matches?(actual : Docr::Types::HealthConfig?, healthcheck_json : String, strict : Bool) : Bool
      expected = PluginHelpers::DockerHealthcheck.parse(healthcheck_json)
      return true unless expected

      strict ? strict_healthcheck_match?(actual, expected) : lenient_healthcheck_match?(actual, expected)
    end

    private def strict_healthcheck_match?(actual : Docr::Types::HealthConfig?, expected : PluginHelpers::DockerHealthcheck::Parsed) : Bool
      return false unless actual

      actual.test == expected.test &&
        actual.interval == expected.interval &&
        actual.timeout == expected.timeout &&
        actual.retries == expected.retries &&
        actual.start_period == expected.start_period
    end

    private def lenient_healthcheck_match?(actual : Docr::Types::HealthConfig?, expected : PluginHelpers::DockerHealthcheck::Parsed) : Bool
      return false unless actual

      (expected.test.nil? || actual.test == expected.test) &&
        (expected.interval.nil? || actual.interval == expected.interval) &&
        (expected.timeout.nil? || actual.timeout == expected.timeout) &&
        (expected.retries.nil? || actual.retries == expected.retries) &&
        (expected.start_period.nil? || actual.start_period == expected.start_period)
    end

    # Matches Ansible's own `_get_expected_values_ports`: each
    # `published_ports:` entry normalizes to a `{HostIp, HostPort}` pair
    # with `HostIp` defaulted to `"0.0.0.0"` when the task left it
    # unspecified. This is genuinely daemon-version-dependent, found live
    # comparing two different real hosts: Podman and an older-API-pinned
    # client (Ansible's own `community.docker`, capped well below
    # the daemon's latest) both report back the literal string
    # `HostIp: "0.0.0.0"`, but a real Docker Engine 29.1.3 queried via
    # the *unversioned/latest* API (what this plugin's own `docr` client
    # uses, same as the `docker` CLI's own default) reports back
    # `HostIp: ""` instead - an empty string, not nil/missing either.
    # Both nil and "" normalize to "0.0.0.0" here so the comparison
    # matches Ansible's own idempotent behavior regardless of which
    # literal spelling the daemon happens to use. `exposed_ports` is
    # compared separately from `published_ports` (matching Ansible's
    # own two-part model) and additionally folds in the image's own
    # declared `ExposedPorts` (Dockerfile `EXPOSE`), the same
    # image-merge pattern `expected_env` uses for `Env`, so an image that
    # exposes a port beyond whatever `ports:` the task lists doesn't
    # cause a false mismatch. Default (`allow_more_present`): every
    # requested container_port/proto key must exist in the actual
    # published_ports dict with an identical binding list, but the
    # container may have EXTRA published/exposed ports the task never
    # mentioned - `strict` requires the whole dict/set to match exactly.
    private def ports_match?(api : Docr::API, config : Docr::Types::ContainerConfig, host_config : Docr::Types::HostConfig, image_ref : String?, strict : Bool) : Bool
      exposed_ports, port_bindings = build_ports

      expected_published = port_bindings.transform_values do |bindings|
        bindings.map { |bnd| "#{bnd.host_ip.presence || "0.0.0.0"}:#{bnd.host_port}" }.to_set
      end
      actual_published = (host_config.port_bindings || Hash(String, Array(Docr::Types::PortBinding)).new).transform_values do |bindings|
        bindings.map { |bnd| "#{bnd.host_ip.presence || "0.0.0.0"}:#{bnd.host_port}" }.to_set
      end
      published_ok = strict ? actual_published == expected_published : dict_set_subset?(expected_published, actual_published)
      return false unless published_ok

      expected_exposed = exposed_ports.keys.to_set
      if image_ref
        expected_exposed += (api.images.inspect(image_ref).config.exposed_ports || Hash(String, Hash(String, String)).new).keys.to_set
      end
      actual_exposed = (config.exposed_ports || Hash(String, Hash(String, String)).new).keys.to_set

      strict ? actual_exposed == expected_exposed : expected_exposed.subset_of?(actual_exposed)
    end

    private def dict_set_subset?(expected : Hash(String, Set(String)), actual : Hash(String, Set(String))) : Bool
      expected.all? { |k, v| actual[k]? == v }
    end

    # Matches Ansible's own `_get_expected_env_value`: the image's
    # own baked-in `Env` (from its Dockerfile `ENV` directives) is folded
    # into the "expected" set before comparing against the running
    # container's actual `Env`, so a base image that sets env vars beyond
    # whatever `env:` the task itself lists doesn't cause a false
    # mismatch on every single run - `env:`-given keys win over the
    # image's own value for the same key.
    private def expected_env(api : Docr::API, image_ref : String?, requested : Hash(String, String)) : Set(String)
      expected = Hash(String, String).new
      if image_ref
        image_env = api.images.inspect(image_ref).config.env || [] of String
        image_env.each do |entry|
          key, _, value = entry.partition('=')
          expected[key] = value
        end
      end
      requested.each { |k, v| expected[k] = v }
      expected.map { |k, v| "#{k}=#{v}" }.to_set
    end

    private def find_container(api : Docr::API, name : String) : Docr::Types::ContainerSummary?
      api.containers.list(all: true).find(&.names.map(&.lchop('/')).includes?(name))
    end

    private def parsed_networks : Array(RequestedNetwork)
      json = @params["networks"]?
      return [] of RequestedNetwork unless json

      JSON.parse(json).as_a.map { |entry| RequestedNetwork.from_json(entry) }
    end

    # Connects the container to whichever requested networks it isn't
    # already a member of. Also disconnects it from any network NOT in
    # *requested* when `comparisons: {networks: strict}` is given -
    # verified against Ansible's own documented behavior ("To
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

    # `comparisons:` is a dict (e.g. `{"networks": "strict"}`)
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
    private def connect_network(client : Docr::Client, net : RequestedNetwork, container_id : String) : Nil
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

    private def disconnect_network(client : Docr::Client, network_name : String, container_id : String) : Nil
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

    # Real wraps a failed pull in its own wording ("Error pulling image
    # <ref> - ...") around the Docker Python SDK's APIError text; both
    # halves are reproduced here by #pull_image! below. Everything else
    # escaping the module body gets the generic DockerException wrapper.
    private def ensure_image_pulled(api : Docr::API, image_ref : String) : Nil
      ref_name, ref_tag = PluginHelpers::DockerRef.split(image_ref)
      full_ref = PluginHelpers::DockerRef.join(ref_name, ref_tag)
      return if image_exists?(api.client, full_ref)

      # Real's pull_image failure message quotes "name:tag" (its
      # f"Error pulling image {name}:{tag}"), with the tag defaulted -
      # not the raw image param.
      pull_image!(api.client, full_ref, ref_name, ref_tag)
    end

    # Ansible's client POSTs the pull itself and wraps any failure in its
    # own prefix, so the wrapped text is the SDK's APIError rendering -
    # "<code> {Client|Server} Error for <url>: <reason>" plus the
    # daemon's own message in quotes (its errors.py). That URL is the
    # versioned pull URL the SDK builds, while `docr` calls every
    # endpoint unversioned and its own DockerAPIError keeps neither the
    # status reason phrase nor the URL - so the pull goes out here
    # directly, to keep the exact text Ansible reports.
    private def pull_image!(client : Docr::Client, image_ref : String, repository : String, tag : String) : Nil
      PluginHelpers::DockerSdkError.pull_image!(client, @params, repository, tag, image_ref)
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
      command = parse_command
      entrypoint = parse_entrypoint
      env = container_env
      labels = parsed_key_value_param("labels")

      exposed_ports, port_bindings = build_ports

      restart_policy_name = @params["restart_policy"]?
      restart_policy = restart_policy_name ? Docr::Types::RestartPolicy.new(name: restart_policy_name) : nil

      volumes = parse_volumes(@params["volumes"]?)

      healthcheck = @params["healthcheck"]?.try { |json| built_healthcheck(json) }

      host_config = Docr::Types::HostConfig.new(
        binds: volumes,
        port_bindings: port_bindings.empty? ? nil : port_bindings,
        restart_policy: restart_policy,
        network_mode: @params["network_mode"]?,
        privileged: true?(@params["privileged"]?),
        auto_remove: true?(@params["auto_remove"]?),
        memory: @params["memory"]?.try { |v| PluginHelpers::DockerResources.human_to_bytes(v) },
        memory_reservation: @params["memory_reservation"]?.try { |v| PluginHelpers::DockerResources.human_to_bytes(v) },
        memory_swap: @params["memory_swap"]?.try { |v| PluginHelpers::DockerResources.memory_swap_to_bytes(v) },
        memory_swappiness: @params["memory_swappiness"]?.try(&.to_i64),
        nano_cpus: @params["cpus"]?.try { |v| PluginHelpers::DockerResources.cpus_to_nano_cpus(v.to_f) },
        cpu_shares: @params["cpu_shares"]?.try(&.to_i64),
        cpuset_cpus: @params["cpuset_cpus"]?,
        cpuset_mems: @params["cpuset_mems"]?,
        oom_kill_disable: @params["oom_kill_disable"]? ? true?(@params["oom_kill_disable"]?) : nil,
        oom_score_adj: @params["oom_score_adj"]?.try(&.to_i64),
        pids_limit: @params["pids_limit"]?.try(&.to_i64),
      )

      Docr::Types::CreateContainerConfig.new(
        image: image_ref,
        cmd: command,
        entrypoint: entrypoint,
        env: env,
        labels: labels,
        exposed_ports: exposed_ports.empty? ? nil : exposed_ports,
        host_config: host_config,
        healthcheck: healthcheck,
        # Ansible only sets StopSignal/StopTimeout when the task gave the
        # stop_signal:/stop_timeout: options, so a container it created
        # has neither. `docr`'s own config type defaults them to
        # SIGTERM/10, which would show up in the created container's
        # registered Config and make it differ from Ansible's - sent as
        # nulls (which the daemon reads as "unset", same as the absent
        # keys real sends).
        stop_signal: nil,
        stop_timeout: nil,
      )
    end

    # See `PluginHelpers::DockerHealthcheck`'s own doc comment for the
    # duration-parsing/test-normalization rules this mirrors from
    # Ansible's own `parse_healthcheck`/`normalize_healthcheck`.
    # `start_interval:` (Ansible's own newer addition) is NOT
    # implemented - the underlying `docr` library's `HealthConfig` type
    # has no field for it, a real scope cut one layer below this plugin.
    private def built_healthcheck(json : String) : Docr::Types::HealthConfig?
      parsed = PluginHelpers::DockerHealthcheck.parse(json)
      return nil unless parsed

      Docr::Types::HealthConfig.new(
        test: parsed.test,
        interval: parsed.interval,
        timeout: parsed.timeout,
        retries: parsed.retries,
        start_period: parsed.start_period,
      )
    end

    private def build_ports : {Hash(String, Hash(String, String)), Hash(String, Array(Docr::Types::PortBinding))}
      exposed_ports = Hash(String, Hash(String, String)).new
      port_bindings = Hash(String, Array(Docr::Types::PortBinding)).new

      entries = parse_port_entries
      entries.each do |entry|
        mapping = PluginHelpers::DockerPorts.parse(entry)
        key = "#{mapping.container_port}/#{mapping.proto}"

        exposed_ports[key] = Hash(String, String).new
        port_bindings[key] ||= [] of Docr::Types::PortBinding
        port_bindings[key] << Docr::Types::PortBinding.new(host_ip: mapping.host_ip, host_port: mapping.host_port)
      end

      {exposed_ports, port_bindings}
    end

    # A literal YAML LIST param arrives JSON-encoded (see
    # playbook_parser's docker_container list branch) - a leading `[`
    # therefore means a real list, whose elements are passed to the
    # daemon verbatim (an element containing a comma or a space is ONE
    # element, where the comma-joined wire every other module's list
    # param travels on would have split it). Anything else is the
    # comma-separated form Ansible's own Ansible-side list conversion
    # produces for a string param.
    private def literal_list_param(raw : String) : Array(String)?
      return nil unless raw.starts_with?('[')
      parsed = JSON.parse(raw) rescue nil
      return nil unless (items = parsed.try(&.as_a?))
      items.map { |item| item.as_s? || item.raw.to_s }
    end

    # Ansible's `env:`/`labels:` are dict-typed options, which
    # Ansible also accepts written as a list of `KEY=VALUE` strings (its
    # own dict type conversion) - and a `KEY=VALUE` element may contain a
    # comma, so that list form travels on the same JSON wire the other
    # docker_container list options use (see #literal_list_param). Both
    # shapes mean the same dict here.
    private def parsed_key_value_param(name : String) : Hash(String, String)?
      raw = @params[name]?
      return nil unless raw
      return Hash(String, String).from_json(raw) unless items = literal_list_param(raw)

      items.each_with_object(Hash(String, String).new) do |item, parsed|
        key, _, value = item.partition('=')
        parsed[key] = value
      end
    end

    # The `Env` list the daemon gets: Ansible's own "KEY=VALUE" strings.
    private def container_env : Array(String)?
      env = parsed_key_value_param("env")
      env.try { |parsed| parsed.map { |key, value| "#{key}=#{value}" } }
    end

    # Ansible's `command`: a list verbatim, a string shell-split
    # (community.docker's `_preprocess_command` under its default
    # `command_handling: correct`).
    private def parse_command : Array(String)?
      raw = @params["command"]?
      return nil unless raw
      literal_list_param(raw) || Krikri::Shell.shlex_split(raw)
    end

    # Ansible's `entrypoint`: a list verbatim; a string is turned into a
    # one-element list by Ansible's own comma-separated list conversion -
    # deliberately NOT shell-split, which is why `entrypoint: /bin/sh -c`
    # stays a single (failing) argv element in real too
    # (live-verified: `entrypoint: ["/bin/sh", "-c"]` runs, the string
    # form makes the daemon look for a file literally named
    # "/bin/sh -c").
    private def parse_entrypoint : Array(String)?
      raw = @params["entrypoint"]?
      return nil unless raw
      return literal_list_param(raw) if raw.starts_with?('[')
      return [] of String if raw.empty?
      raw.split(',').map(&.strip).reject(&.empty?)
    end

    # Ansible's `volumes`: a list verbatim, a string comma-split.
    private def parse_volumes(raw : String?) : Array(String)?
      return nil unless raw
      literal_list_param(raw) || raw.split(',').map(&.strip).reject(&.empty?)
    end

    private def parse_port_entries : Array(String)
      raw = @params["ports"]?
      return [] of String unless raw
      (literal_list_param(raw) || raw.split(',').map(&.strip)).reject(&.empty?)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::DockerContainerPlugin.new(config)
plugin.run
