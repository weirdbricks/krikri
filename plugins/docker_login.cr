#!/usr/bin/env crystal
# community.docker.docker_login - registry authentication, storing
# credentials in the docker CLI config file. Ported from community
# .docker's docker_login module (round 300108: oasis_roles
# .molecule_docker_ci uses it; previously unavailable -> rc=4
# "unavailable modules").
#
# Semantics matching the real module:
# - registry_url (aliases registry/url; default the legacy Docker Hub
#   endpoint), username/password (required when state=present -
#   "state is present but all of the following are missing: ..."),
#   reauthorize (bool-converted, like real's merged-spec type
#   conversion), config_path (default ~/.docker/config.json, the
#   dockercfg_path alias), state present/absent - plus the full
#   AnsibleModule validation surface (merged-spec type conversion,
#   state choices, client_cert/client_key required-together,
#   unsupported params, password no_log censoring) BEFORE anything
#   daemon-facing runs.
# - state=present: existing auths[<registry>] entry decoding to the same
#   username AND password with no reauthorize is a no-op (changed=false,
#   no registry round trip - the real module returns the stored authcfg
#   immediately); otherwise the credentials are validated and stored via
#   `docker login` (which is what the real module's daemon /auth call +
#   DockerFileStore.store achieve together), changed=true.
# - state=absent: the registry's auth entry is erased from the config
#   file (0600, like the real DockerFileStore._write) when present,
#   changed=false otherwise - no docker binary needed.
require "json"
require "base64"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/ansible_arg_validation"
require "../src/krikri/plugin_helpers/docker_client"
require "../src/krikri/plugin_helpers/docker_login"

module Krikri
  class DockerLoginPlugin < BasePlugin
    include PluginHelpers::AnsibleArgValidation

    # Real merged argument_spec (community.docker docker_login.py +
    # _util.py's DOCKER_COMMON_ARGS), name => aliases. The API client
    # (not the CLI client) is used here, so timeout/use_ssh_client/
    # debug ARE in the spec.
    SPEC = PluginHelpers::DockerClient::COMMON_SPEC.merge({
      "registry_url" => %w[registry url],
      "username"     => %w[],
      "password"     => %w[],
      "reauthorize"  => %w[reauth],
      "state"        => %w[],
      "config_path"  => %w[dockercfg_path],
    })

    def execute : PluginResult
      if err = validate_arguments
        return err
      end

      registry_url = @params["registry_url"]?.presence ||
                     @params["registry"]?.presence ||
                     @params["url"]?.presence ||
                     PluginHelpers::DockerLogin::DEFAULT_REGISTRY_URL
      username = @params["username"]?
      password = @params["password"]?
      reauthorize = true?(@params["reauthorize"]?)
      state = @params["state"]? || "present"
      config_path = expand_tilde(@params["config_path"]?.presence ||
                                 @params["dockercfg_path"]?.presence ||
                                 PluginHelpers::DockerLogin::DEFAULT_CONFIG_PATH)

      return censor(logout(registry_url, config_path), password) if state == "absent"

      # Real required_if: (state, present, [username, password]) - key
      # PRESENCE, not non-emptiness (an explicit empty username passes
      # and fails the login itself).
      missing = %w[username password].select { |param| @params[param]?.nil? }
      unless missing.empty?
        return PluginResult.new(changed: false, failed: true,
          msg: "state is present but all of the following are missing: #{missing.join(", ")}")
      end
      username = username.not_nil!
      password = password.not_nil!

      config, _config_raw = read_config(config_path)
      if !reauthorize && (stored = PluginHelpers::DockerLogin.stored_credentials(config, registry_url))
        if stored[:username] == username && stored[:password] == password
          return PluginResult.new(changed: false, failed: false,
            msg: "Already logged into #{registry_url}", login_result: login_result(registry_url, username))
        end
      end

      config_dir = File.dirname(config_path)
      # Docker's CLI wants a config DIRECTORY; the default hub URL is
      # also its own default, so the registry argument is omitted there.
      login = remote_exec(PluginHelpers::DockerLogin.login_command(registry_url, username, password, config_dir))
      return censor(PluginResult.new(changed: false, failed: true,
        msg: "Logging into #{registry_url} for user #{username} failed - #{login[:stderr].strip.presence || login[:stdout].strip.presence || "docker login returned #{login[:exit_code]}"}"), password) if login[:exit_code] != 0

      censor(PluginResult.new(changed: true, failed: false,
        msg: "Logged into #{registry_url}", login_result: login_result(registry_url, username)), password)
    end

    # Real remove_values(): password is no_log, so its value never
    # appears in any message (whole-string equality becomes
    # VALUE_SPECIFIED_IN_NO_LOG_PARAMETER, occurrences become 8 stars).
    private def censor(result : PluginResult, password : String?) : PluginResult
      secret = password.presence
      return result unless secret
      result.msg = "VALUE_SPECIFIED_IN_NO_LOG_PARAMETER" if result.msg == secret
      result.msg = result.msg.gsub(secret, "*" * 8)
      result
    end

    # Real AnsibleModule validation over the merged spec, in
    # arg_spec.ArgumentSpecValidator.validate order: required ->
    # types (merged-spec order: common args first) -> choices ->
    # required_together -> required_if -> unsupported (deferred last).
    # The daemon connection only happens after all of it.
    private def validate_arguments : PluginResult?
      if err = validate_types
        return err
      end

      if err = validate_choices
        return err
      end

      if err = validate_required_together
        return err
      end

      if err = validate_required_if
        return err
      end

      validate_unsupported
    end

    private def validate_types : PluginResult?
      {"timeout" => "int", "tls" => "bool", "use_ssh_client" => "bool", "validate_certs" => "bool", "debug" => "bool", "reauthorize" => "bool"}.each do |param, type|
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

    private def validate_choices : PluginResult?
      state = @params["state"]? || "present"
      return nil if %w[present absent].includes?(state)
      choices_error("state", %w[present absent], state)
    end

    private def validate_required_together : PluginResult?
      has_cert = @params["client_cert"]? || @params["cert_path"]? || @params["tls_client_cert"]?
      has_key = @params["client_key"]? || @params["key_path"]? || @params["tls_client_key"]?
      if (has_cert || has_key) && !(has_cert && has_key)
        return required_together_error(PluginHelpers::DockerClient::COMMON_REQUIRED_TOGETHER)
      end
      nil
    end

    private def validate_required_if : PluginResult?
      return nil if (@params["state"]? || "present") != "present"
      missing = %w[username password].select { |param| @params[param]?.nil? }
      return nil if missing.empty?
      PluginResult.new(changed: false, failed: true,
        msg: "state is present but all of the following are missing: #{missing.join(", ")}")
    end

    private def validate_unsupported : PluginResult?
      unsupported = unsupported_param_keys(@params, SPEC)
      return nil if unsupported.empty?
      unsupported_params_error("community.docker.docker_login", unsupported, SPEC)
    end

    private def login_result(registry_url : String, username : String) : JSON::Any
      JSON.parse(%({"serveraddress": "#{registry_url}", "username": "#{username}"}))
    end

    private def read_config(config_path : String) : {JSON::Any?, String?}
      result = remote_exec("cat '#{config_path}'")
      return {nil, nil} if result[:exit_code] != 0 || result[:stdout].strip.empty?
      parsed = JSON.parse(result[:stdout]) rescue nil
      parsed ? {parsed, result[:stdout]} : {nil, nil}
    end

    private def logout(registry_url : String, config_path : String) : PluginResult
      config, _ = read_config(config_path)
      if PluginHelpers::DockerLogin.stored_credentials(config, registry_url).nil?
        return PluginResult.new(changed: false, failed: false,
          msg: "Credentials for #{registry_url} not present, doing nothing.")
      end

      updated = PluginHelpers::DockerLogin.with_erased_credentials(config, registry_url)
      return PluginResult.new(changed: false, failed: false,
        msg: "Credentials for #{registry_url} not present, doing nothing.") unless updated

      write_config(config_path, updated)
      PluginResult.new(changed: true, failed: false, msg: "Logged out of #{registry_url}")
    end

    private def write_config(config_path : String, content : String) : Nil
      remote_exec("mkdir -p '#{File.dirname(config_path)}'")
      # The config carries base64 user:pass auth: stage it 0600
      # controller-side (not the old predictable 0644 /tmp name), and
      # tighten the remote copy the moment it lands with a verified
      # chmod (an unchecked chmod under a hardening role's restrictive
      # policy previously left the credential file 0644 for good).
      tmp = File.join(Dir.tempdir, ".docker-login-#{Random::Secure.hex(8)}")
      File.open(tmp, "w") do |f|
        f.chmod(0o600)
        f.write(content.to_slice)
      end
      begin
        remote_upload(tmp, config_path)
        r = remote_exec("chmod 600 '#{config_path}'")
        raise "chmod 600 on #{config_path} failed: #{r[:stderr]}" if r[:exit_code] != 0
      ensure
        File.delete?(tmp)
      end
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::DockerLoginPlugin.new(config)
plugin.run
