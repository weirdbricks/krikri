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
#   reauthorize, config_path (default ~/.docker/config.json, the
#   dockercfg_path alias), state present/absent.
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
require "../src/krikri/plugin_helpers/docker_login"

module Krikri
  class DockerLoginPlugin < BasePlugin
    def execute : PluginResult
      registry_url = @params["registry_url"]?.presence ||
                     @params["registry"]?.presence ||
                     @params["url"]?.presence ||
                     PluginHelpers::DockerLogin::DEFAULT_REGISTRY_URL
      username = @params["username"]?
      password = @params["password"]?
      reauthorize = true?(@params["reauthorize"]?)
      state = @params["state"]? || "present"
      unless state == "present" || state == "absent"
        return PluginResult.new(changed: false, failed: true,
          msg: "value of state must be one of: present, absent, got #{state}")
      end
      config_path = expand_tilde(@params["config_path"]?.presence ||
        @params["dockercfg_path"]?.presence ||
        PluginHelpers::DockerLogin::DEFAULT_CONFIG_PATH)

      return logout(registry_url, config_path) if state == "absent"

      if msg = PluginHelpers::DockerLogin.missing_credentials_msg(username, password)
        return PluginResult.new(changed: false, failed: true, msg: msg)
      end
      username = username.not_nil!
      password = password.not_nil!

      config, config_raw = read_config(config_path)
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
      return PluginResult.new(changed: false, failed: true,
        msg: "Logging into #{registry_url} for user #{username} failed - #{login[:stderr].strip.presence || login[:stdout].strip.presence || "docker login returned #{login[:exit_code]}"}") if login[:exit_code] != 0

      PluginResult.new(changed: true, failed: false,
        msg: "Logged into #{registry_url}", login_result: login_result(registry_url, username))
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
      tmp = "/tmp/.docker-login-#{Process.pid}"
      File.write(tmp, content)
      remote_upload(tmp, config_path)
      remote_exec("chmod 600 '#{config_path}'")
      File.delete(tmp)
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::DockerLoginPlugin.new(config)
plugin.run
