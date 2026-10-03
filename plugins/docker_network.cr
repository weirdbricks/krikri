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
  #   (matches real Ansible's own default). Pass appends: true to only add
  #   missing connections and never disconnect anything (real Ansible's
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
  # - force: unconditionally deletes and recreates the network even when
  #   its config already matches (distinct from the driver-mismatch
  #   auto-recreate above, which only fires on an actual difference) -
  #   verified against real Ansible's own `present()`/`remove_network()`
  #   source: disconnects every currently-connected container first
  #   (Docker's own network-remove API refuses to delete a network with
  #   any container still attached), matching the driver-mismatch path's
  #   own delete exactly - live-verified against a real Docker daemon.
  #
  # ipam_config: is accepted and validated (sub-spec element shape,
  # matching real _list_no_log_values' string-to-dict conversion) but not
  # applied - Docker has no "change a network's IPAM in place" API, so a
  # differing ipam_config needs the force:-style recreate path, which
  # real gates behind has_different_config's much more thorough
  # comparison; `api_version:` is likewise unimplemented (see
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

    # Key order of real's registered result, live-verified against real
    # ansible-core 2.19.11 + community.docker 5.2.1 over a Docker-API
    # socket: the module seeds its result dict with `{"changed": ...,
    # "actions": [...]}` (docker_network.py's __init__), then adds
    # `network` (present) and `diff` (check_mode or debug), and the
    # module protocol appends `failed` last. `actions` is popped again
    # once a real (non-check_mode, non-debug) run finishes (present()'s
    # `if not self.check_mode and not self.parameters.debug`), which is
    # why a normal create/rerun registers only changed/network/failed.
    KEY_ORDER = %w[changed actions network diff failed]

    # Real's own wrapper for a DockerException escaping the module body.
    # Only the prefix is reproduced verbatim; the wrapped message after it
    # is the python SDK's own formatting, which docr words differently.
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

      client, docker_host_description = PluginHelpers::DockerClient.build(@params)
      api = Docr::API.new(client)

      existing = find_network(api, name)

      # state is choices-validated to exactly present/absent above.
      if state == "present"
        ensure_present(api, name, driver, internal, attachable, labels, connected, appends, existing, check_mode, true?(@params["debug"]?))
      else
        ensure_absent(api, name, existing, check_mode)
      end
    rescue ex : Docr::Errors::DockerAPIError
      PluginResult.new(changed: false, failed: true, msg: "#{API_ERROR_PREFIX}#{ex.message}")
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
      debug_mode : Bool,
    ) : PluginResult
      force = true?(@params["force"]?)
      actions = [] of String
      changed = false

      # Real's remove-then-create recreate path (`force:` or a driver
      # mismatch) records the removal in `actions` exactly like a plain
      # absent run does.
      if existing && (force || existing.driver != driver)
        remove_network!(api, name, existing, check_mode, actions)
        changed = true
        existing = nil
      end

      unless existing
        unless check_mode
          config = Docr::Types::NetworkConfig.new(
            name: name,
            driver: driver,
            internal: internal,
            attachable: attachable,
            labels: labels,
          )
          existing = api.networks.create(config)
        end
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

      present_result(api, name, actions, changed, check_mode || debug_mode, check_mode)
    end

    # Real's `remove_network()`: disconnect everything first (Docker
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

    # The present-state result dict, in real's own key order: `actions`
    # only survives into the wire in check_mode/debug (real pops it
    # otherwise), `network` is the raw inspect payload (`null` when a
    # check_mode create did not actually create anything), and `diff` is
    # only filled in check_mode/debug.
    private def present_result(
      api : Docr::API, name : String, actions : Array(String),
      changed : Bool, keep_actions : Bool, with_diff : Bool,
    ) : PluginResult
      result = PluginResult.new(changed: changed, failed: false, failed_flag: false)
      result.key_order = KEY_ORDER
      result.extra["actions"] = json_string_array(actions) if keep_actions
      result.extra["network"] = inspect_network_json(api, name)
      result.extra["diff"] = JSON.parse(%({"differences": []})) if with_diff
      result
    end

    # `force:` (and the driver-mismatch auto-recreate above) both delete
    # the existing network before recreating it - real Ansible's own
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

    # A 404 (no such network) is real's `None`, not a failure - get_network
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
    # is false (the default, matching real Ansible), also disconnects any
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

    # Real AnsibleModule validation over the merged spec, in
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

    # ipam_config elements must be dicts (real's _list_no_log_values
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

      # Real's absent path never records a `network` key; its diff
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
