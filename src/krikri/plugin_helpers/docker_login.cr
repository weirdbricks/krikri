require "json"
require "base64"

module Krikri
  module PluginHelpers
    # DockerLogin - pure logic for the docker_login plugin: docker
    # config.json auth-entry handling (the real module's
    # DockerFileStore.get/store/erase semantics: base64 "user:pass"
    # entries under auths[<registry>], config rewritten 0600) and login
    # command construction. Split out so this logic is unit-spec-able
    # (execution needs a real registry/docker CLI).
    module DockerLogin
      DEFAULT_REGISTRY_URL = "https://index.docker.io/v1/"
      DEFAULT_CONFIG_PATH  = "~/.docker/config.json"

      # The registry key auth entries are stored under. Docker's CLI
      # stores hub credentials under the legacy hub endpoint; passing the
      # default hub URL to `docker login` is also how the CLI gets
      # invoked without an explicit registry argument.
      def self.hub?(registry_url : String) : Bool
        url = registry_url.presence || DEFAULT_REGISTRY_URL
        url == DEFAULT_REGISTRY_URL || url == "https://index.docker.io" || url == "https://docker.io"
      end

      # Decodes an auths[server]["auth"] entry ("user:pass", base64).
      # Returns nil for missing/malformed entries.
      def self.decode_auth(auth : String?) : NamedTuple(username: String, password: String)?
        return nil if auth.nil? || auth.empty?
        decoded = Base64.decode_string(auth)
        user, pass = decoded.split(":", 2)
        {username: user, password: pass}
      rescue
        nil
      end

      # Current stored credentials for the registry from the parsed
      # config, or nil.
      def self.stored_credentials(config : JSON::Any?, registry_url : String) : NamedTuple(username: String, password: String)?
        root = config.try(&.as_h?)
        return nil unless root
        auths = root["auths"]?.try(&.as_h?)
        return nil unless auths
        entry = auths[registry_url]?
        return nil unless entry
        decode_auth(entry.as_h?.try(&.["auth"]?).try(&.as_s?))
      end

      # New config JSON string with the registry's auth entry stored
      # (auth = base64 "user:pass"). Non-auths keys are preserved.
      def self.with_stored_credentials(config : JSON::Any?, registry_url : String, username : String, password : String) : String
        obj = config && config.as_h? ? config.as_h.clone : {} of String => JSON::Any
        auths = obj["auths"]?.try(&.as_h?) || {} of String => JSON::Any
        auths.delete(registry_url)
        auths[registry_url] = JSON.parse(%({"auth": "#{Base64.strict_encode("#{username}:#{password}")}"}))
        obj["auths"] = JSON.parse(auths.to_json)
        JSON.build do |json|
          json.object do
            obj.each do |key, value|
              json.field(key) { value.to_json(json) }
            end
          end
        end
      end

      # New config JSON string with the registry's auth entry removed.
      def self.with_erased_credentials(config : JSON::Any?, registry_url : String) : String?
        return nil unless config && config.as_h?
        obj = config.as_h.clone
        auths = obj["auths"]?.try(&.as_h?)
        return nil unless auths && auths.has_key?(registry_url)
        auths.delete(registry_url)
        obj["auths"] = JSON.parse(auths.to_json)
        JSON.build do |json|
          json.object do
            obj.each do |key, value|
              json.field(key) { value.to_json(json) }
            end
          end
        end
      end

      # `docker login` command for the registry. Hub default logins omit
      # the registry argument (the CLI's own default), everything else
      # passes the URL; --config points the CLI at the config file's
      # directory for custom config_path support.
      def self.login_command(registry_url : String, username : String, password : String, config_dir : String?) : String
        cmd = "docker"
        cmd += " --config '#{config_dir}'" if config_dir
        cmd += " login -u '#{username.gsub("'", "'\\''")}' -p '#{password.gsub("'", "'\\''")}'"
        cmd += " #{registry_url}" unless hub?(registry_url)
        cmd
      end

      # The real module's required_if failure message for state=present.
      def self.missing_credentials_msg(username : String?, password : String?) : String?
        missing = [] of String
        missing << "username" if username.nil? || username.empty?
        missing << "password" if password.nil? || password.empty?
        missing.empty? ? nil : "state is present but all of the following are missing: #{missing.join(", ")}"
      end
    end
  end
end
