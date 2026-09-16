#!/usr/bin/env crystal

require "json"
require "docr"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/docker_client"

module Krikri
  # Docker network info plugin - reports whether a Docker network exists,
  # and its full inspection output when it does. Compatible with Ansible's
  # community.docker.docker_network_info module.
  #
  # See plugins/docker_network.cr's module comment for the shared
  # architecture note (talks to the Docker Engine API directly, local
  # UNIX socket by default or a remote daemon over TCP(+TLS) via
  # docker_host:/TLS params, via the weirdbricks/docr fork - connection
  # param parsing shared through PluginHelpers::DockerClient).
  #
  # Supported parameters:
  # - name: network name (required) - a network name, or a long/short
  #   network ID (matched by exact name or ID prefix, matching real
  #   Ansible's own `get_network()` lookup).
  # - docker_host: / tls: / validate_certs: (alias tls_verify:) / ca_path:
  #   (aliases cacert_path: etc.) / client_cert: / client_key: /
  #   tls_hostname: / api_version: / timeout: / use_ssh_client: - the
  #   common connection surface real merges into every API module's
  #   argument_spec (see PluginHelpers::DockerClient.COMMON_SPEC), and
  #   which real AnsibleModule therefore validates on every call - the
  #   validation below mirrors that (required name, common-arg type
  #   conversion, client_cert/client_key required-together, unsupported
  #   params) BEFORE the daemon connection is attempted.
  #
  # Result (matching real Ansible's own two return values, both always
  # present, changed always false - this is an info module, never a
  # mutation, in check mode or not):
  # - exists: bool - whether a network with that name/ID was found.
  # - network: the raw `GET /networks/{id}` inspection output (a dict), or
  #   null when not found. Returned as the daemon's own JSON verbatim (via
  #   the same raw `Docr::Client#call` escape hatch docker_network.cr uses
  #   for its non-typed endpoints), not through docr's typed
  #   Docr::Types::Network - the type drops fields it has no mapping for,
  #   and roles legitimately read arbitrary inspection keys off this dict.
  #
  # An unreachable Docker daemon FAILS the task with a real connection
  # error (message shape "Error connecting: ..."), matching real Ansible's
  # own behavior - real docker modules never silently skip when they
  # cannot reach the daemon, and a skip here would leave a registered
  # result without `exists:`, corrupting a later `when: check.exists`.
  class DockerNetworkInfoPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Real merged argument_spec: DOCKER_COMMON_ARGS + name (required, no
    # aliases on this module).
    SPEC = PluginHelpers::DockerClient::COMMON_SPEC.merge({"name" => [] of String})

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      name = @params["name"]?.to_s

      client, docker_host_description = PluginHelpers::DockerClient.build(@params)
      api = Docr::API.new(client)

      matched = api.networks.list.find { |net| net.name == name || net.id.starts_with?(name) }

      unless matched
        return PluginResult.new(changed: false, failed: false, msg: "Network #{name} not found",
          exists: false, network: nil)
      end

      raw = raw_get(api.client, "/networks/#{matched.id}")
      PluginResult.new(changed: false, failed: false, msg: "Network #{name} found",
        exists: true, network: JSON.parse(raw))
    rescue ex : Docr::Errors::DockerAPIError
      PluginResult.new(changed: false, failed: true, msg: "Docker API error: #{ex.message}")
    rescue ex : Socket::ConnectError
      PluginResult.new(changed: false, failed: true, msg: "Error connecting: Cannot connect to the Docker daemon (#{docker_host_description}): #{ex.message}")
    end

    private def raw_get(client : Docr::Client, path : String) : String
      headers = HTTP::Headers{"Content-Type" => "application/json"}
      client.call("GET", path, headers, &.body_io.gets_to_end)
    end

    # Real AnsibleModule validation over the merged spec, in
    # arg_spec.ArgumentSpecValidator.validate order: required -> types
    # (merged-spec order: common args first) -> required_together ->
    # unsupported (deferred to last). No choices/required_if on this
    # module; the daemon connection only happens after all of it.
    private def validate_arguments : PluginResult?
      if err = validate_required
        return err
      end

      if err = validate_types
        return err
      end

      if err = validate_required_together
        return err
      end

      validate_unsupported
    end

    private def validate_required : PluginResult?
      return nil if @params["name"]?
      missing_required_error(["name"])
    end

    private def validate_types : PluginResult?
      {"timeout" => "int", "tls" => "bool", "use_ssh_client" => "bool", "validate_certs" => "bool", "debug" => "bool"}.each do |param, type|
        next unless raw = @params[param]?
        if type == "int"
          next if raw.to_i32?
          return int_type_error(param, raw)
        else
          next if bool_convertible?(raw)
          return bool_type_error(param, raw)
        end
      end
      nil
    end

    private def validate_required_together : PluginResult?
      has_cert = @params["client_cert"]? || @params["cert_path"]? || @params["tls_client_cert"]?
      has_key = @params["client_key"]? || @params["key_path"]? || @params["tls_client_key"]?
      if (has_cert || has_key) && !(has_cert && has_key)
        return required_together_error(PluginHelpers::DockerClient::COMMON_REQUIRED_TOGETHER)
      end
      nil
    end

    private def validate_unsupported : PluginResult?
      unsupported = unsupported_param_keys(@params, SPEC)
      return nil if unsupported.empty?
      unsupported_params_error("community.docker.docker_network_info", unsupported, SPEC)
    end
  end
end

# Plugin entry point
input = STDIN.gets_to_end
config = JSON.parse(input)

plugin = Krikri::DockerNetworkInfoPlugin.new(config)
plugin.run
