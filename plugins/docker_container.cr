#!/usr/bin/env crystal

require "json"
require "docr"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/docker_ref"
require "../src/crystal_play/plugin_helpers/docker_ports"
require "../src/crystal_play/plugin_helpers/docker_client"
require "../src/crystal_play/plugin_helpers/docker_healthcheck"
require "../src/crystal_play/plugin_helpers/docker_resources"

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
  # - memory / memory_reservation / memory_swap: human-readable byte-size
  #   strings ("512M", "1G", ...) - see PluginHelpers::DockerResources's
  #   own doc comment, ported from real Ansible's own `human_to_bytes`
  #   (binary/1024-based units despite the non-"i" K/M/G/T/P spelling).
  #   `memory_swap: "unlimited"` (or the literal string `"-1"`) is real
  #   Ansible's own documented unlimited-swap convention.
  # - memory_swappiness / cpu_shares / oom_score_adj / pids_limit: int
  # - cpus: float number of CPUs, converted to Docker's own `NanoCpus`
  #   (`cpus * 1e9`, rounded) - matches real Ansible's own
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
  # divergence real Ansible would avoid either - both would see the
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
  #   ported from real Ansible's own `parse_healthcheck`/
  #   `normalize_healthcheck`. `test: ["NONE"]` is the real, documented
  #   way to explicitly disable an inherited healthcheck. `start_interval:`
  #   (real Ansible's own newer addition) is NOT implemented - the
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
  # given, matching real Ansible's own "only compare what you told me
  # about" behavior for any option not mentioned at all. The per-field
  # default comparison mode is NOT uniformly strict - verified against
  # real Ansible's own module_utils source (`Option.__init__`): scalar
  # options (restart_policy, network_mode, privileged, auto_remove, and
  # every resource-limit param above - all `int`/`str`/`bool`-typed, real
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
  # ports_match?'s own doc comment. Every other field of real Ansible's
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
  # links: per network); `healthcheck.start_interval:`, `device_requests:`,
  # `container_default_behavior:`, `api_version:` (see
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
      check_mode = true?(@params["check_mode"]?)

      client, docker_host_description = PluginHelpers::DockerClient.build(@params)
      api = Docr::API.new(client)
      existing = find_container(api, name)

      return ensure_absent(api, existing, check_mode) if state == "absent"

      image_ref = @params["image"]?
      command = @params["command"]?.try(&.split(/\s+/).reject(&.empty?))
      pull = true?(@params["pull"]?, default: true)
      recreate_requested = true?(@params["recreate"]?)

      needs_create = !existing
      needs_recreate = if ex = existing
                         recreate_requested || !matches?(api, ex, image_ref, command)
                       else
                         false
                       end

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

        config = build_container_config(image_ref || raise "image is required to create a new container")
        ensure_image_pulled(api, image_ref || raise "image is required to create a new container") if pull
        resp = api.containers.create(name, config)
        api.containers.start(resp.id) if start
        connected, disconnected = sync_networks!(api, resp.id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "Created#{start ? " and started" : ""} container #{name}#{network_suffix(connected, disconnected)}")
      end

      existing = existing || raise "BUG: existing container missing"

      if needs_recreate
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be recreated") if check_mode

        config = build_container_config(image_ref || raise "image is required to create a new container")
        api.containers.stop(existing.id) if existing.state == "running"
        api.containers.delete(existing.id, force: true)
        ensure_image_pulled(api, image_ref || raise "image is required to create a new container") if pull
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

        config = build_container_config(image_ref || raise "image is required to create a new container")
        ensure_image_pulled(api, image_ref || raise "image is required to create a new container") if pull
        resp = api.containers.create(name, config)
        connected, disconnected = sync_networks!(api, resp.id, requested_networks)
        return PluginResult.new(changed: true, failed: false, msg: "Created container #{name} (stopped)#{network_suffix(connected, disconnected)}")
      end

      existing = existing || raise "BUG: existing container missing"

      if needs_recreate
        return PluginResult.new(changed: true, failed: false, msg: "Container #{name} would be recreated (stopped)") if check_mode

        config = build_container_config(image_ref || raise "image is required to create a new container")
        api.containers.stop(existing.id) if existing.state == "running"
        api.containers.delete(existing.id, force: true)
        ensure_image_pulled(api, image_ref || raise "image is required to create a new container") if pull
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

    EXTRA_COMPARISON_FIELDS = %w[entrypoint env labels volumes restart_policy network_mode privileged auto_remove ports healthcheck
      memory memory_reservation memory_swap memory_swappiness cpus cpu_shares cpuset_cpus cpuset_mems
      oom_kill_disable oom_score_adj pids_limit]

    private def extra_fields_given? : Bool
      EXTRA_COMPARISON_FIELDS.any? { |field| @params[field]? }
    end

    # Real Ansible's own per-field comparison default is NOT uniformly
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
    # (real Ansible's own supported override direction); `ignore` always
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

      if entrypoint = @params["entrypoint"]?
        mode = comparison_mode("entrypoint", "strict")
        unless mode == "ignore"
          requested = entrypoint.split(/\s+/).reject(&.empty?)
          actual = config.entrypoint || [] of String
          return false unless mode == "strict" ? actual == requested : requested.all? { |e| actual.includes?(e) }
        end
      end

      if env_json = @params["env"]?
        mode = comparison_mode("env", "allow_more_present")
        unless mode == "ignore"
          expected = expected_env(api, image_ref, env_json)
          actual = (config.env || [] of String).to_set
          return false unless mode == "strict" ? actual == expected : expected.subset_of?(actual)
        end
      end

      if labels_json = @params["labels"]?
        mode = comparison_mode("labels", "allow_more_present")
        unless mode == "ignore"
          requested = Hash(String, String).from_json(labels_json)
          actual = config.labels || Hash(String, String).new
          return false unless mode == "strict" ? actual == requested : dict_subset?(requested, actual)
        end
      end

      if volumes = @params["volumes"]?
        mode = comparison_mode("volumes", "allow_more_present")
        unless mode == "ignore"
          requested = volumes.split(',').map(&.strip).reject(&.empty?).to_set
          actual = (host_config.binds || [] of String).to_set
          return false unless mode == "strict" ? actual == requested : requested.subset_of?(actual)
        end
      end

      if (restart_policy_name = @params["restart_policy"]?) && comparison_mode("restart_policy", "strict") != "ignore"
        return false unless host_config.restart_policy.try(&.name) == restart_policy_name
      end

      if (network_mode = @params["network_mode"]?) && comparison_mode("network_mode", "strict") != "ignore"
        return false unless host_config.network_mode == network_mode
      end

      if @params["privileged"]? && comparison_mode("privileged", "strict") != "ignore"
        return false unless !!host_config.privileged == true?(@params["privileged"]?)
      end

      if @params["auto_remove"]? && comparison_mode("auto_remove", "strict") != "ignore"
        return false unless !!host_config.auto_remove == true?(@params["auto_remove"]?)
      end

      if @params["ports"]?
        mode = comparison_mode("ports", "allow_more_present")
        return false unless mode == "ignore" || ports_match?(api, config, host_config, image_ref, strict: mode == "strict")
      end

      if healthcheck_json = @params["healthcheck"]?
        mode = comparison_mode("healthcheck", "allow_more_present")
        return false unless mode == "ignore" || healthcheck_matches?(config.healthcheck, healthcheck_json, strict: mode == "strict")
      end

      if (memory = @params["memory"]?) && comparison_mode("memory", "strict") != "ignore"
        return false unless host_config.memory == PluginHelpers::DockerResources.human_to_bytes(memory)
      end

      if (memory_reservation = @params["memory_reservation"]?) && comparison_mode("memory_reservation", "strict") != "ignore"
        return false unless host_config.memory_reservation == PluginHelpers::DockerResources.human_to_bytes(memory_reservation)
      end

      if (memory_swap = @params["memory_swap"]?) && comparison_mode("memory_swap", "strict") != "ignore"
        return false unless host_config.memory_swap == PluginHelpers::DockerResources.memory_swap_to_bytes(memory_swap)
      end

      if (memory_swappiness = @params["memory_swappiness"]?) && comparison_mode("memory_swappiness", "strict") != "ignore"
        return false unless host_config.memory_swappiness == memory_swappiness.to_i64
      end

      if (cpus = @params["cpus"]?) && comparison_mode("cpus", "strict") != "ignore"
        return false unless host_config.nano_cpus == PluginHelpers::DockerResources.cpus_to_nano_cpus(cpus.to_f)
      end

      if (cpu_shares = @params["cpu_shares"]?) && comparison_mode("cpu_shares", "strict") != "ignore"
        return false unless host_config.cpu_shares == cpu_shares.to_i64
      end

      if (cpuset_cpus = @params["cpuset_cpus"]?) && comparison_mode("cpuset_cpus", "strict") != "ignore"
        return false unless host_config.cpuset_cpus == cpuset_cpus
      end

      if (cpuset_mems = @params["cpuset_mems"]?) && comparison_mode("cpuset_mems", "strict") != "ignore"
        return false unless host_config.cpuset_mems == cpuset_mems
      end

      if @params["oom_kill_disable"]? && comparison_mode("oom_kill_disable", "strict") != "ignore"
        return false unless !!host_config.oom_kill_disable == true?(@params["oom_kill_disable"]?)
      end

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
    # real Ansible's own "no override at all" - this plugin never set a
    # `Healthcheck` at container-create time either (see
    # `built_healthcheck`), so there's nothing to compare and it always
    # matches, same as `healthcheck:` not being given at all. Default
    # (`allow_more_present`) only compares the sub-fields the task itself
    # set, so Docker's own default-filled `timeout:`/`retries:` (when the
    # task didn't specify them) don't count as drift; `strict` compares
    # every sub-field including ones the task left unset (matching real
    # Ansible's own literal dict-equality behavior under an explicit
    # `strict` override).
    private def healthcheck_matches?(actual : Docr::Types::HealthConfig?, healthcheck_json : String, strict : Bool) : Bool
      expected = PluginHelpers::DockerHealthcheck.parse(healthcheck_json)
      return true unless expected
      return false unless actual

      return actual.test == expected.test &&
        actual.interval == expected.interval &&
        actual.timeout == expected.timeout &&
        actual.retries == expected.retries &&
        actual.start_period == expected.start_period if strict

      (expected.test.nil? || actual.test == expected.test) &&
        (expected.interval.nil? || actual.interval == expected.interval) &&
        (expected.timeout.nil? || actual.timeout == expected.timeout) &&
        (expected.retries.nil? || actual.retries == expected.retries) &&
        (expected.start_period.nil? || actual.start_period == expected.start_period)
    end

    # Matches real Ansible's own `_get_expected_values_ports`: each
    # `published_ports:` entry normalizes to a `{HostIp, HostPort}` pair
    # with `HostIp` defaulted to `"0.0.0.0"` when the task left it
    # unspecified. This is genuinely daemon-version-dependent, found live
    # comparing two different real hosts: Podman and an older-API-pinned
    # client (real Ansible's own `community.docker`, capped well below
    # the daemon's latest) both report back the literal string
    # `HostIp: "0.0.0.0"`, but a real Docker Engine 29.1.3 queried via
    # the *unversioned/latest* API (what this plugin's own `docr` client
    # uses, same as the `docker` CLI's own default) reports back
    # `HostIp: ""` instead - an empty string, not nil/missing either.
    # Both nil and "" normalize to "0.0.0.0" here so the comparison
    # matches real Ansible's own idempotent behavior regardless of which
    # literal spelling the daemon happens to use. `exposed_ports` is
    # compared separately from `published_ports` (matching real Ansible's
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
        bindings.map { |b| "#{b.host_ip.presence || "0.0.0.0"}:#{b.host_port}" }.to_set
      end
      actual_published = (host_config.port_bindings || Hash(String, Array(Docr::Types::PortBinding)).new).transform_values do |bindings|
        bindings.map { |b| "#{b.host_ip.presence || "0.0.0.0"}:#{b.host_port}" }.to_set
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
      )
    end

    # See `PluginHelpers::DockerHealthcheck`'s own doc comment for the
    # duration-parsing/test-normalization rules this mirrors from real
    # Ansible's own `parse_healthcheck`/`normalize_healthcheck`.
    # `start_interval:` (real Ansible's own newer addition) is NOT
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
