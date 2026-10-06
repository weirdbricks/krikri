#!/usr/bin/env crystal

require "json"
require "docr"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/docker_client"

module Krikri
  # Docker network plugin - creates/removes a Docker network.
  # Compatible with Ansible's community.docker.docker_network module.
  #
  # See plugins/docker_image.cr's module comment for the shared
  # architecture note (talks to the Docker Engine API directly, local
  # UNIX socket by default or a remote daemon over TCP(+TLS) via
  # docker_host:/TLS params below, via the weirdbricks/docr fork).
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
  #   (matches Ansible's own default). Pass appends: true to only add
  #   missing connections and never disconnect anything (Ansible's
  #   own appends:/incremental alias). Uses the same raw
  #   `Docr::Client#call` escape hatch as docker_container.cr's networks:
  #   for `POST /networks/{id}/connect`/`disconnect` - docr's own
  #   Networks#connect/#disconnect are unimplemented stubs.
  # - appends: bool, default false - see connected: above.
  # - docker_host: / tls: / validate_certs: (alias tls_verify:) / cacert_path: /
  #   cert_path: / key_path: - connect to a remote Docker daemon over
  #   TCP(+TLS) instead of the local UNIX socket - see
  #   PluginHelpers::DockerClient's own doc comment for exact behavior
  #   (including tls_hostname:/DOCKER_TLS*/DOCKER_CERT_PATH support).
  # - state: present (default) / absent
  # - check_mode
  #
  # Idempotency is by name; if a network with that name already exists
  # but its driver differs from the requested one, or its IPAM config
  # differs from a given ipam_config:/ipam_driver:/ipam_driver_options:
  # (real's has_different_config, IPAM part), it's removed and recreated
  # (Docker has no "change a network's driver/IPAM in place" API) -
  # everything else about an existing network (labels, etc.) is left
  # untouched even if it differs from what was requested, a documented
  # simplification versus Ansible's much more thorough comparison.
  # connected: is checked/applied on every run regardless, including when
  # the network itself needed no change - silently ignoring it after the
  # network already exists would make it useless on every run after the
  # first, the same reasoning docker_container.cr's own networks: uses.
  # A task that gives no connected: list inherits the network's current
  # containers (real's own defaulting), which is what keeps a recreate
  # from disconnecting everything.
  #
  # - force: unconditionally deletes and recreates the network even when
  #   its config already matches (distinct from the driver-mismatch
  #   auto-recreate above, which only fires on an actual difference) -
  #   verified against Ansible's own `present()`/`remove_network()`
  #   source: disconnects every currently-connected container first
  #   (Docker's own network-remove API refuses to delete a network with
  #   any container still attached), matching the driver-mismatch path's
  #   own delete exactly - live-verified against a real Docker daemon.
  #
  # ipam_config: (list of {subnet, iprange, gateway, aux_addresses}) is
  # applied on create exactly like real's create_network payload (Subnet/
  # IPRange/Gateway/AuxiliaryAddresses, every key present, null when the
  # task left it out), and its comparison against the daemon's readback
  # drives the recreate path above: real normalizes the readback keys
  # (AuxiliaryAddresses -> aux_addresses, the rest lower-cased), finds
  # the readback entry that covers every non-null requested key, and
  # counts a per-key difference ("ipam_config[<idx>].<key>") when none
  # does. On podman's docker-compatible socket the readback echoes only
  # Gateway/Subnet, so a fully-specified pool re-creates on every run -
  # real does the same there; a subnet-only pool is idempotent on both.
  # The subnets are CIDR-validated after the daemon connection (real's
  # TaskParameters order): '"<subnet>" is not a valid CIDR'. The
  # comparison entries also feed the check_mode/debug `diff` (legacy
  # `differences` name list, plus before/after with --diff), `exists`
  # leading both maps like real's diff tracker. ipam_driver:/
  # ipam_driver_options: ride the same IPAM create payload and comparison.
  # `api_version:` is likewise unimplemented (see
  # PluginHelpers::DockerClient).
  class DockerNetworkPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Real merged argument_spec (community.docker docker_network.py +
    # _util.py's DOCKER_COMMON_ARGS), name => aliases.
    SPEC = PluginHelpers::DockerClient::COMMON_SPEC.merge({
      "name"                => %w[network_name],
      "config_from"         => %w[],
      "config_only"         => %w[],
      "connected"           => %w[containers],
      "state"               => %w[],
      "driver"              => %w[],
      "driver_options"      => %w[],
      "force"               => %w[],
      "appends"             => %w[incremental],
      "ipam_driver"         => %w[],
      "ipam_driver_options" => %w[],
      "ipam_config"         => %w[],
      "enable_ipv4"         => %w[],
      "enable_ipv6"         => %w[],
      "internal"            => %w[],
      "labels"              => %w[],
      "scope"               => %w[],
      "attachable"          => %w[],
      "ingress"             => %w[],
    })
    # Real merged-spec order for type conversion (common args first).
    INT_PARAMS    = %w[timeout]
    BOOL_PARAMS   = %w[tls use_ssh_client validate_certs debug config_only force appends enable_ipv4 enable_ipv6 internal attachable ingress]
    DICT_PARAMS   = %w[driver_options ipam_driver_options labels]
    CHOICE_PARAMS = {
      "state" => %w[present absent],
      "scope" => %w[local global swarm],
    }

    # Key order of Ansible's registered result, live-verified against
    # ansible-core 2.19.11 + community.docker 5.2.1 over a Docker-API
    # socket: the module seeds its result dict with `{"changed": ...,
    # "actions": [...]}` (docker_network.py's __init__), then adds
    # `network` (present) and `diff` (check_mode or debug), and the
    # module protocol appends `failed` last. `actions` is popped again
    # once a real (non-check_mode, non-debug) run finishes (present()'s
    # `if not self.check_mode and not self.parameters.debug`), which is
    # why a normal create/rerun registers only changed/network/failed.
    KEY_ORDER = %w[changed actions network diff failed]

    # Ansible's own wrapper for a DockerException escaping the module body;
    # the wrapped text is the Python SDK's own APIError rendering, which
    # PluginHelpers::DockerSdkError reproduces.
    API_ERROR_PREFIX = "An unexpected Docker error occurred: "

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      name = @params["name"]?.to_s

      driver = @params["driver"]? || "bridge"
      internal = true?(@params["internal"]?)
      attachable = true?(@params["attachable"]?)
      labels = @params["labels"]?.try { |json| Hash(String, String).from_json(json) }
      connected = @params["connected"]?.try(&.split(',').map(&.strip).reject(&.empty?)) || [] of String
      appends = true?(@params["appends"]?)
      state = @params["state"]? || "present"
      check_mode = true?(@params["_ansible_check_mode"]?)
      ipam_driver = @params["ipam_driver"]?
      ipam_driver_options = @params["ipam_driver_options"]?.try { |json| Hash(String, String).from_json(json) }

      client, _ = PluginHelpers::DockerClient.build(@params)
      api = Docr::API.new(client)

      # Real validates the ipam_config subnets AFTER the daemon connection
      # (TaskParameters.__init__ runs once the client already exists), so
      # a dead daemon fails with the connect wording even with a bad CIDR.
      if err = validate_ipam_cidrs
        return err
      end

      existing = find_network(api, name)

      # state is choices-validated to exactly present/absent above.
      if state == "present"
        ensure_present(api, name, driver, internal, attachable, labels, connected, appends,
          ipam_driver, ipam_driver_options, existing, check_mode, true?(@params["debug"]?),
          true?(@params["_ansible_diff"]?))
      else
        ensure_absent(api, name, existing, check_mode)
      end
    rescue ex : Docr::Errors::DockerAPIError
      PluginResult.new(changed: false, failed: true, msg: "#{API_ERROR_PREFIX}#{PluginHelpers::DockerSdkError.api_error_text(client, @params, ex)}")
    rescue ex : Socket::ConnectError
      PluginResult.new(changed: false, failed: true, msg: PluginHelpers::DockerSdkError.connect_error_text(ex, PluginHelpers::DockerClient.resolved_docker_host(@params)))
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
      ipam_driver : String?,
      ipam_driver_options : Hash(String, String)?,
      existing : Docr::Types::Network?,
      check_mode : Bool,
      debug_mode : Bool,
      diff_mode : Bool,
    ) : PluginResult
      force = true?(@params["force"]?)
      actions = [] of String
      changed = false
      existed_before = !existing.nil?

      # Ansible's own defaulting (DockerNetworkManager.__init__): a task
      # that gives no connected: list inherits the network's CURRENT
      # containers - which is what makes a recreate (and a plain no-drift
      # rerun) leave the connected set alone instead of disconnecting
      # everything.
      if connected.empty? && existing
        connected = container_names_in_network(api, name)
      end

      # Real's present(): has_different_config runs on the existing
      # network, and force: OR any difference (driver or IPAM) takes the
      # remove-then-create recreate path, recording the removal in
      # `actions` exactly like a plain absent run does.
      drift = ipam_drift(api, name, existing, ipam_driver, ipam_driver_options)
      if existing && (force || existing.driver != driver || drift)
        remove_network!(api, name, existing, check_mode, actions)
        changed = true
        existing = nil
      end

      unless existing
        create_network!(api, name, driver, internal, attachable, labels,
          ipam_driver, ipam_driver_options, check_mode)
        actions << "Created network #{name} with driver #{driver}"
        changed = true
      end

      # Connected-container syncing runs on every present run, whether or
      # not the network itself changed (see the class doc comment), but
      # only when the network is actually there to sync - real gates the
      # same steps on its own `existing_network` being set, so a
      # check_mode create (which creates nothing) syncs nothing.
      if existing
        changed = true if sync_connected!(api, name, connected, appends, check_mode, actions)
      end

      present_result(api, name, actions, changed, check_mode || debug_mode, check_mode,
        diff_mode, existed_before, drift)
    end

    # The create half of present(): the raw IPAM-bearing payload when any
    # IPAM param was given, the docr-typed create otherwise (both skipped
    # in check mode, where only the action gets recorded).
    private def create_network!(
      api : Docr::API, name : String, driver : String, internal : Bool,
      attachable : Bool, labels : Hash(String, String)?,
      ipam_driver : String?, ipam_driver_options : Hash(String, String)?,
      check_mode : Bool,
    ) : Nil
      return if check_mode

      if ipam_driver || ipam_driver_options || !ipam_pools.empty?
        create_network_with_ipam!(api, name, driver, internal, attachable, labels,
          ipam_driver, ipam_driver_options)
        return
      end

      config = Docr::Types::NetworkConfig.new(
        name: name,
        driver: driver,
        internal: internal,
        attachable: attachable,
        labels: labels,
      )
      api.networks.create(config)
    end

    # Ansible's has_different_config, IPAM part only (the other fields
    # keep this plugin's documented compare-nothing-but-driver behavior).
    # Returns nil when there is nothing to compare (no ipam params given,
    # or no existing network); otherwise the DifferenceTracker-style
    # entries: the legacy `differences` name list plus the before/after
    # maps the `diff` result carries (each keyed "ipam_config[<idx>.]<key>"
    # etc., `exists` added by the caller).
    private def ipam_drift(
      api : Docr::API, name : String, existing : Docr::Types::Network?,
      ipam_driver : String?, ipam_driver_options : Hash(String, String)?,
    ) : Drift?
      return nil if existing.nil?
      return nil if ipam_driver.nil? && ipam_driver_options.nil? && ipam_pools.empty?

      net = docker_raw_get(api.client, "/networks/#{name}")
      return nil unless net

      drift = Drift.new
      net_ipam = net["IPAM"]?.try(&.as_h?)
      drift_driver(drift, net_ipam, ipam_driver)
      drift_driver_options(drift, net_ipam, ipam_driver_options)
      drift_pools(drift, net_ipam)
      drift.empty? ? nil : drift
    end

    # ipam_driver: given - the readback must carry the same IPAM driver
    # (the whole IPAM dict is the active side of the difference entry,
    # like real's differences.add).
    private def drift_driver(drift : Drift, net_ipam : Hash(String, JSON::Any)?, ipam_driver : String?) : Nil
      return unless ipam_driver
      return if net_ipam && net_ipam["Driver"]?.try(&.as_s?) == ipam_driver

      drift.add("ipam_driver", JSON::Any.new(ipam_driver), net_ipam.try { |ipam| JSON::Any.new(ipam) })
    end

    private def drift_driver_options(drift : Drift, net_ipam : Hash(String, JSON::Any)?, ipam_driver_options : Hash(String, String)?) : Nil
      return unless ipam_driver_options

      net_opts = net_ipam.try(&.["Options"]?.try(&.as_h?)) || {} of String => JSON::Any
      requested = ipam_driver_options.map { |key, value| {key, JSON::Any.new(value)} }.to_h
      return if net_opts == requested

      drift.add("ipam_driver_options", JSON::Any.new(requested), JSON::Any.new(net_opts))
    end

    private def drift_pools(drift : Drift, net_ipam : Hash(String, JSON::Any)?) : Nil
      pools = ipam_pools
      return if pools.empty?

      # Put the network's IPAM config entries into the same format as the
      # module's (real's normalize_ipam_config_key pass).
      net_configs = (net_ipam.try(&.["Config"]?.try(&.as_a?)) || [] of JSON::Any).map do |entry|
        normalized = {} of String => JSON::Any
        entry.as_h.each do |key, value|
          normalized[normalize_ipam_config_key(key)] = value
        end
        normalized
      end

      if net_configs.empty?
        drift.add("ipam_config", requested_ipam_json(pools), net_ipam.try(&.["Config"]?))
        return
      end

      pools.each_with_index do |pool, idx|
        # dicts_are_essentially_equal: the first readback entry whose
        # values cover every non-null requested key wins; when none
        # does, every requested key counts as a difference against an
        # empty readback entry (active=None) - which is exactly what
        # podman's readback (no IPRange/AuxiliaryAddresses echo)
        # produces for a fully-specified pool, matching real's
        # recreate-on-every-run there.
        net_config = net_configs.find { |entry| essentially_equal?(pool, entry) } || {} of String => JSON::Any
        drift_pool_keys(drift, idx, pool, net_config)
      end
    end

    private def drift_pool_keys(drift : Drift, idx : Int32, pool : RequestedIpamPool, net_config : Hash(String, JSON::Any)) : Nil
      pool.each_present_field do |key, value|
        active = net_config[key]?
        next if active == value
        drift.add("ipam_config[#{idx}].#{key}", value, active)
      end
    end

    # Ansible's dicts_are_essentially_equal(a, b): every non-null entry of
    # *pool* must be present and equal in the readback entry *net_config*
    # (extra readback keys are ignored).
    private def essentially_equal?(pool : RequestedIpamPool, net_config : Hash(String, JSON::Any)) : Bool
      pool.each_present_field do |key, value|
        return false unless net_config[key]? == value
      end
      true
    end

    # normalize_ipam_config_key: the Docker API's IPAM config keys
    # lower-cased, with its one special spelling folded to the Ansible key.
    private def normalize_ipam_config_key(key : String) : String
      key == "AuxiliaryAddresses" ? "aux_addresses" : key.downcase
    end

    private def requested_ipam_json(pools : Array(RequestedIpamPool)) : JSON::Any
      JSON::Any.new(pools.map do |pool|
        fields = {} of String => JSON::Any
        pool.each_field do |key, value|
          fields[key] = value || JSON::Any.new(nil)
        end
        JSON::Any.new(fields)
      end)
    end

    # One requested ipam_config entry: the four Ansible keys (each nil
    # when the task left it out, matching real's recursive-argspec
    # None-default behavior) as JSON::Any values so the comparison can
    # talk to the daemon's raw readback directly.
    record RequestedIpamPool,
      subnet : JSON::Any?,
      iprange : JSON::Any?,
      gateway : JSON::Any?,
      aux_addresses : JSON::Any? do
      # Iterates the Ansible-side keys in argspec order with their values;
      # aux_addresses stays the raw JSON (a dict) for equality comparison.
      def each_field(&) : Nil
        yield "subnet", @subnet
        yield "iprange", @iprange
        yield "gateway", @gateway
        yield "aux_addresses", @aux_addresses
      end

      # each_field restricted to the keys the task actually gave - the
      # comparison skips null entries the way real's
      # dicts_are_essentially_equal does.
      def each_present_field(&) : Nil
        subnet = @subnet
        yield "subnet", subnet unless subnet.nil?
        iprange = @iprange
        yield "iprange", iprange unless iprange.nil?
        gateway = @gateway
        yield "gateway", gateway unless gateway.nil?
        aux_addresses = @aux_addresses
        yield "aux_addresses", aux_addresses unless aux_addresses.nil?
      end
    end

    # The task's ipam_config entries, parsed once per call. The str-typed
    # keys go through Ansible's own str() conversion for non-string
    # scalars (its recursive argspec converts subnet: 123 to "123");
    # aux_addresses is a plain untyped dict and stays raw.
    private def ipam_pools : Array(RequestedIpamPool)
      raw = @params["ipam_config"]?
      return [] of RequestedIpamPool unless raw

      parse_sub_list(raw).compact_map do |element|
        next nil unless fields = element.as_h?
        RequestedIpamPool.new(
          subnet: pool_str_field(fields, "subnet"),
          iprange: pool_str_field(fields, "iprange"),
          gateway: pool_str_field(fields, "gateway"),
          aux_addresses: pool_dict_field(fields, "aux_addresses"),
        )
      end
    end

    private def pool_str_field(fields : Hash(String, JSON::Any), key : String) : JSON::Any?
      raw = fields[key]?
      return nil unless raw

      case raw_value = raw.raw
      when String  then JSON::Any.new(raw_value)
      when Int64   then JSON::Any.new(raw_value.to_s)
      when Float64 then JSON::Any.new(raw_value.to_s)
      when Bool    then JSON::Any.new(raw_value ? "True" : "False")
      end
    end

    private def pool_dict_field(fields : Hash(String, JSON::Any), key : String) : JSON::Any?
      raw = fields[key]?
      return nil unless raw
      return nil unless raw.as_h?

      raw
    end

    # Real's validate_cidr (docker_network.py): IPv4 first, then IPv6,
    # else '"<subnet>" is not a valid CIDR'. A pool without a subnet
    # fails the same way real's re.match(None) TypeError does. Runs after
    # the daemon connection (real validates in TaskParameters.__init__,
    # which the already-created client precedes).
    private def validate_ipam_cidrs : PluginResult?
      ipam_pools.each do |pool|
        subnet = pool.subnet
        unless subnet
          return PluginResult.new(changed: false, failed: true, msg: "expected string or bytes-like object, got 'NoneType'")
        end
        next if subnet.as_s.matches?(CIDR_IPV4) || subnet.as_s.matches?(CIDR_IPV6)
        return PluginResult.new(changed: false, failed: true, msg: "\"#{subnet.as_s}\" is not a valid CIDR")
      end
      nil
    end

    CIDR_IPV4 = /\A([0-9]{1,3}\.){3}[0-9]{1,3}\/([0-9]|[1-2][0-9]|3[0-2])\Z/
    CIDR_IPV6 = /\A[0-9a-fA-F:]+\/([0-9]|[1-9][0-9]|1[0-2][0-9])\Z/

    # The DifferenceTracker-shaped outcome of the IPAM comparison: the
    # legacy `differences` name list plus the before/after entries.
    private class Drift
      property names : Array(String)
      property before : Hash(String, JSON::Any)
      property after : Hash(String, JSON::Any)

      def initialize
        @names = [] of String
        @before = {} of String => JSON::Any
        @after = {} of String => JSON::Any
      end

      def add(name : String, parameter : JSON::Any, active : JSON::Any?) : Nil
        @names << name
        @before[name] = active || JSON::Any.new(nil)
        @after[name] = parameter
      end

      def empty? : Bool
        @names.empty?
      end
    end

    # Real's create_network() payload for the IPAM-bearing path: the
    # daemon's POST /networks/create body exactly as real builds it
    # (Name/Driver/Options/IPAM/CheckDuplicate, then the conditional
    # fields, then the IPAM dict when any IPAM param was given). The
    # non-IPAM path keeps the docr-typed create above.
    private def create_network_with_ipam!(
      api : Docr::API, name : String, driver : String, internal : Bool,
      attachable : Bool, labels : Hash(String, String)?,
      ipam_driver : String?, ipam_driver_options : Hash(String, String)?,
    ) : Nil
      data = {
        "Name"           => JSON::Any.new(name),
        "Driver"         => JSON::Any.new(driver),
        "Options"        => driver_options_json,
        "IPAM"           => JSON::Any.new(nil),
        "CheckDuplicate" => JSON::Any.new(nil),
      } of String => JSON::Any

      data["Internal"] = JSON::Any.new(true) if internal
      data["Attachable"] = JSON::Any.new(attachable) if @params["attachable"]?
      data["Labels"] = JSON::Any.new(labels.map { |k, v| {k, JSON::Any.new(v)} }.to_h) if labels

      if ipam_driver || ipam_driver_options || !ipam_pools.empty?
        data["IPAM"] = JSON::Any.new({
          "Driver"  => ipam_driver ? JSON::Any.new(ipam_driver) : JSON::Any.new(nil),
          "Config"  => JSON::Any.new(ipam_pools.map { |pool| pool_create_json(pool) }),
          "Options" => ipam_driver_options ? JSON::Any.new(ipam_driver_options.map { |k, v| {k, JSON::Any.new(v)} }.to_h) : JSON::Any.new(nil),
        } of String => JSON::Any)
      end

      docker_raw_call(api.client, "POST", "/networks/create", JSON::Any.new(data))
    end

    private def driver_options_json : JSON::Any
      raw = @params["driver_options"]?
      return JSON::Any.new(nil) unless raw
      JSON.parse(raw)
    end

    # The create payload's Config entry: all four Docker-API keys, each
    # the requested value or null (real sends every key unconditionally).
    private def pool_create_json(pool : RequestedIpamPool) : JSON::Any
      aux = pool.aux_addresses
      JSON::Any.new({
        "Subnet"             => pool.subnet || JSON::Any.new(nil),
        "IPRange"            => pool.iprange || JSON::Any.new(nil),
        "Gateway"            => pool.gateway || JSON::Any.new(nil),
        "AuxiliaryAddresses" => aux || JSON::Any.new(nil),
      } of String => JSON::Any)
    end

    # Ansible's container_names_in_network, for the connected: defaulting
    # above.
    private def container_names_in_network(api : Docr::API, name : String) : Array(String)
      net = docker_raw_get(api.client, "/networks/#{name}")
      containers = net.try(&.["Containers"]?.try(&.as_h?)) || {} of String => JSON::Any
      containers.values.compact_map do |container|
        container.as_h?.try(&.["Name"]?.try(&.as_s?))
      end
    end

    # Ansible's `remove_network()`: disconnect everything first (Docker
    # refuses to remove an in-use network), then delete, then record the
    # action. Real addresses the network by NAME here, not by id.
    private def remove_network!(
      api : Docr::API, name : String, existing : Docr::Types::Network,
      check_mode : Bool, actions : Array(String),
    ) : Nil
      disconnect_all!(api, existing.id) unless check_mode
      api.networks.delete(existing.id) unless check_mode
      actions << "Removed network #{name}"
    end

    # The present-state result dict, in Ansible's own key order: `actions`
    # only survives into the wire in check_mode/debug (real pops it
    # otherwise), `network` is the raw inspect payload (`null` when a
    # check_mode create did not actually create anything), and `diff` is
    # only filled in check_mode/debug - {"differences": [...]} always,
    # plus the diff tracker's before/after when the task ran with --diff.
    # `exists` leads the before/after maps (present() adds it first),
    # then the IPAM comparison entries.
    private def present_result(
      api : Docr::API, name : String, actions : Array(String),
      changed : Bool, keep_actions : Bool, with_diff : Bool,
      diff_mode : Bool, existed_before : Bool, drift : Drift?,
    ) : PluginResult
      result = PluginResult.new(changed: changed, failed: false, failed_flag: false)
      result.key_order = KEY_ORDER
      result.extra["actions"] = json_string_array(actions) if keep_actions
      result.extra["network"] = inspect_network_json(api, name)
      if with_diff
        diff = {"differences" => json_string_array(drift.try(&.names) || [] of String)} of String => JSON::Any
        if diff_mode
          before = {"exists" => JSON::Any.new(existed_before)} of String => JSON::Any
          after = {"exists" => JSON::Any.new(true)} of String => JSON::Any
          if drift
            drift.before.each { |key, value| before[key] = value }
            drift.after.each { |key, value| after[key] = value }
          end
          diff["before"] = JSON::Any.new(before)
          diff["after"] = JSON::Any.new(after)
        end
        result.extra["diff"] = JSON::Any.new(diff)
      end
      result
    end

    # `force:` (and the driver-mismatch auto-recreate above) both delete
    # the existing network before recreating it - Ansible's own
    # `remove_network()` disconnects every currently-connected container
    # FIRST (`disconnect_all_containers()`, verified against its actual
    # source), since Docker's own network-remove API itself refuses to
    # delete a network with any container still attached.
    private def disconnect_all!(api : Docr::API, network_id : String) : Nil
      current = api.networks.inspect(network_id).containers || Hash(String, Docr::Types::NetworkContainer).new
      current.values.each do |container|
        docker_raw_call(api.client, "POST", "/networks/#{network_id}/disconnect", {"Container" => container.name})
      end
    end

    # The raw inspect payload real puts under `network`, straight from the
    # daemon's `/networks/<name>` GET (null when it does not exist) - not
    # a re-serialization of a typed struct, so every daemon-returned key
    # and its daemon-returned order survive verbatim.
    private def inspect_network_json(api : Docr::API, name : String) : JSON::Any
      raw = docker_raw_get(api.client, "/networks/#{name}")
      raw || JSON::Any.new(nil)
    end

    # A 404 (no such network) is Ansible's `None`, not a failure - get_network
    # swallows it into a null `network`.
    private def json_string_array(values : Array(String)) : JSON::Any
      JSON::Any.new(values.map { |value| JSON::Any.new(value) })
    end

    private def docker_raw_get(client : Docr::Client, path : String) : JSON::Any?
      client.call("GET", path, HTTP::Headers{"Accept" => "application/json"}) do |response|
        body = response.body_io?.try(&.gets_to_end)
        body.nil? || body.empty? ? nil : JSON.parse(body)
      end
    rescue Docr::Errors::DockerAPIError
      nil
    end

    # Connects any requested containers not yet connected; when appends:
    # is false (the default, matching Ansible), also disconnects any
    # currently-connected container not in the requested list. Appends a
    # real-worded entry to `actions` per change and reports whether
    # anything changed (real records connect/disconnect there too, and
    # folds each into `changed`).
    private def sync_connected!(
      api : Docr::API, name : String, connected : Array(String),
      appends : Bool, check_mode : Bool, actions : Array(String),
    ) : Bool
      return false if connected.empty? && appends

      current = api.networks.inspect(name).containers || Hash(String, Docr::Types::NetworkContainer).new
      current_names = current.values.map(&.name)
      changed = false

      connected.each do |container|
        next if current_names.includes?(container)
        docker_raw_call(api.client, "POST", "/networks/#{name}/connect", {"Container" => container}) unless check_mode
        actions << "Connected container #{container}"
        changed = true
      end

      unless appends
        current_names.each do |container|
          next if connected.includes?(container)
          docker_raw_call(api.client, "POST", "/networks/#{name}/disconnect", {"Container" => container}) unless check_mode
          actions << "Disconnected container #{container}"
          changed = true
        end
      end

      changed
    end

    # AnsibleModule validation over the merged spec, in
    # arg_spec.ArgumentSpecValidator.validate order: required -> types
    # (merged-spec order) -> choices -> required_together -> sub-spec
    # string-element conversion -> unsupported (deferred to last). The
    # daemon connection only happens after all of it.
    private def validate_arguments : PluginResult?
      if err = validate_required
        return err
      end

      if err = validate_types
        return err
      end

      if err = validate_choices
        return err
      end

      if err = validate_required_together
        return err
      end

      if err = validate_ipam_config_elements
        return err
      end

      validate_unsupported
    end

    private def validate_required : PluginResult?
      return nil if @params["name"]?
      missing_required_error(["name"])
    end

    private def validate_types : PluginResult?
      INT_PARAMS.each do |param|
        next unless raw = @params[param]?
        next if raw.to_i32?
        return int_type_error(param, raw)
      end
      BOOL_PARAMS.each do |param|
        next unless raw = @params[param]?
        next if bool_convertible?(raw)
        return bool_type_error(param, raw)
      end
      DICT_PARAMS.each do |param|
        next unless raw = @params[param]?
        if err = check_dict_type(param, raw)
          return err
        end
      end
      nil
    end

    # check_type_dict semantics for a top-level dict param (errors get
    # the parameters.py "argument ... is of type" wrapper).
    private def check_dict_type(param : String, raw : String) : PluginResult?
      case value = (JSON.parse(raw) rescue nil).try(&.raw)
      when Hash
        nil
      when Array
        PluginResult.new(changed: false, failed: true,
          msg: "argument '#{param}' is of type <class 'list'> and we were unable to convert to dict: " \
               "<class 'list'> cannot be converted to a dict")
      when String
        if err = check_dict_type_string(value)
          return PluginResult.new(changed: false, failed: true,
            msg: "argument '#{param}' is of type <class 'str'> and we were unable to convert to dict: #{err.msg}")
        end
        nil
      when Nil
        if err = check_dict_type_string(raw)
          return PluginResult.new(changed: false, failed: true,
            msg: "argument '#{param}' is of type <class 'str'> and we were unable to convert to dict: #{err.msg}")
        end
        nil
      end
    end

    # Bare check_type_dict: strings try JSON (when they look like
    # objects) then k1=v1,k2=v2 pairs; everything else fails.
    private def check_dict_type_string(value : String) : PluginResult?
      stripped = value.strip
      if stripped.starts_with?("{")
        begin
          return nil if JSON.parse(stripped).as_h?
        rescue
        end
        return PluginResult.new(changed: false, failed: true,
          msg: "unable to evaluate string as dictionary")
      end
      return nil if value.includes?("=")
      PluginResult.new(changed: false, failed: true,
        msg: "dictionary requested, could not parse JSON or key=value")
    end

    private def validate_choices : PluginResult?
      CHOICE_PARAMS.each do |param, allowed|
        value = @params[param]? || (param == "state" ? "present" : nil)
        next unless value
        next if allowed.includes?(value)
        return choices_error(param, allowed, value)
      end
      nil
    end

    # _util.py's DOCKER_REQUIRED_TOGETHER, shared by every API module;
    # aliases count through their canonical name (real _handle_aliases
    # copies the value onto the canonical key first).
    private def validate_required_together : PluginResult?
      has_cert = @params["client_cert"]? || @params["cert_path"]? || @params["tls_client_cert"]?
      has_key = @params["client_key"]? || @params["key_path"]? || @params["tls_client_key"]?
      if (has_cert || has_key) && !(has_cert && has_key)
        return required_together_error(PluginHelpers::DockerClient::COMMON_REQUIRED_TOGETHER)
      end
      nil
    end

    # ipam_config elements must be dicts (Ansible's _list_no_log_values
    # string-to-dict pass fails a non-dict element before anything else
    # looks at the param, with the bare check_type_dict wording).
    private def validate_ipam_config_elements : PluginResult?
      raw = @params["ipam_config"]?
      return nil unless raw
      parse_sub_list(raw).each do |element|
        next unless element.as_h?.nil?
        case value = element.raw
        when String
          if err = check_dict_type_string(value)
            return err
          end
        when Int64, Float64, Bool
          return PluginResult.new(changed: false, failed: true,
            msg: "Value '#{value}' in the sub parameter field 'ipam_config' must by a dict, not '#{value.class.name.to_s.downcase.sub("int64", "int")}'")
        end
      end
      nil
    end

    private def validate_unsupported : PluginResult?
      unsupported = unsupported_param_keys(@params, SPEC, {"ipam_config" => %w[subnet iprange gateway aux_addresses]})
      return nil if unsupported.empty?
      unsupported_params_error("community.docker.docker_network", unsupported, SPEC)
    end

    private def docker_raw_call(client : Docr::Client, method : String, path : String, body)
      headers = HTTP::Headers{"Content-Type" => "application/json"}
      client.call(method, path, headers, body.to_json) { |response| response.consume_body_io }
    end

    private def ensure_absent(api : Docr::API, name : String, existing : Docr::Types::Network?, check_mode : Bool) : PluginResult
      actions = [] of String
      remove_network!(api, name, existing, check_mode, actions) if existing

      # Ansible's absent path never records a `network` key; its diff
      # tracker is emitted (as an empty dict - the removal never reaches
      # it) only in check_mode.
      result = PluginResult.new(changed: !existing.nil?, failed: false, failed_flag: false)
      result.key_order = KEY_ORDER
      result.extra["actions"] = json_string_array(actions)
      result.extra["diff"] = JSON.parse("{}") if check_mode
      result
    end

    private def find_network(api : Docr::API, name : String) : Docr::Types::Network?
      api.networks.list.find { |net| net.name == name }
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::DockerNetworkPlugin.new(config)
plugin.run
