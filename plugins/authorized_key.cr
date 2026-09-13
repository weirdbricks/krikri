#!/usr/bin/env crystal

require "json"
require "../src/krikri/base_plugin"
require "../src/krikri/plugin_helpers/authorized_keys_file"

module Krikri
  # Authorized_key plugin - manages a public key in a user's
  # ~/.ssh/authorized_keys file
  # Compatible with (a subset of) Ansible's ansible.posix.authorized_key module
  # (this one lives in the ansible.posix collection, not ansible-core)
  #
  # Parameters:
  #   user (required unless path: is given): whose authorized_keys file to edit
  #   key (required): the public key line (options + type + blob + comment)
  #   state (optional): present (default) or absent
  #   path (optional): explicit authorized_keys path, overriding the
  #     user's home-directory default (the user's NSS home + /.ssh/authorized_keys)
  #   manage_dir (optional, default yes): create ~/.ssh (mode 0700) if missing
  class AuthorizedKeyPlugin < BasePlugin
    def execute : PluginResult
      key = @params["key"]?
      return missing_param("key") unless key

      if key.strip.empty?
        # A real Ansible playbook can legitimately compute an empty key
        # value at render time (weareinteractive.users' own `key: "{{
        # user.authorized_keys | default([]) | join('\n') }}"`, empty
        # whenever authorized_keys isn't set for that user) - real
        # Ansible's own module treats that as a true no-op (doesn't even
        # create the file), not "add a blank line". Without this,
        # AuthorizedKeysFile#ensure both added a blank line AND could
        # never recognize it as already-present on a rerun (an empty
        # key's signature is nil, and blank lines are filtered out of
        # the "existing lines" list before the signature comparison even
        # runs) - non-idempotent forever, `changed: true` on every run.
        return PluginResult.new(changed: false, failed: false, msg: "No key provided, nothing to do")
      end

      path = resolve_path
      return PluginResult.new(changed: false, failed: true, msg: "Could not determine authorized_keys path: provide 'path' or a valid 'user'") unless path

      state = @params["state"]? || "present"
      check_mode = true?(@params["check_mode"]?)
      manage_dir = @params["manage_dir"]?.nil? || true?(@params["manage_dir"]?)

      original_content = File.exists?(path) ? File.read(path) : ""
      new_content, changed = PluginHelpers::AuthorizedKeysFile.ensure(original_content, key, state == "present")

      if changed && !check_mode
        ensure_dir(File.dirname(path)) if manage_dir
        File.write(path, new_content)
        File.chmod(path, 0o600)
      end

      result = PluginResult.new(changed: changed, failed: false, msg: "")

      # Real Ansible's own module returns its ENTIRE module.params dict
      # (enforce_state mutates `params` in place and main() does
      # `exit_json(**results)`), with `keyfile` (the resolved keyfile
      # path) and `changed` merged in - so every effective parameter is
      # echoed back, including the ones that were defaulted (manage_dir/
      # exclusive/validate_certs/follow) or absent (comment/key_options/
      # path come through as JSON null). Verified live against
      # ansible.posix.authorized_key 2.1.0 / ansible-core 2.19.
      result.extra["user"] = json_string(@params["user"]?)
      result.extra["key"] = JSON::Any.new(key.as(String))
      result.extra["path"] = json_string(@params["path"]?)
      result.extra["keyfile"] = JSON::Any.new(path)
      result.extra["manage_dir"] = JSON::Any.new(manage_dir)
      result.extra["state"] = JSON::Any.new(state)
      result.extra["key_options"] = json_string(@params["key_options"]?)
      result.extra["exclusive"] = JSON::Any.new(true?(@params["exclusive"]?))
      result.extra["comment"] = json_string(@params["comment"]?)
      result.extra["validate_certs"] = JSON::Any.new(@params["validate_certs"]?.nil? || true?(@params["validate_certs"]?))
      result.extra["follow"] = JSON::Any.new(true?(@params["follow"]?))

      # Real Ansible's AnsibleModule.exit_json runs add_path_info over
      # the result dict: the stat fields appear only because the echoed
      # `path` param (null when not given) points at an existing file -
      # exactly what this mirrors (an absent `path:` param means no stat
      # fields at all, even though the keyfile itself exists).
      add_path_info(result, path) if @params["path"]?

      result
    end

    private def json_string(value : String?) : JSON::Any
      JSON::Any.new(value)
    end

    private def resolve_path : String?
      if p = @params["path"]?
        return expand_tilde(p)
      end

      user = @params["user"]?
      return nil unless user

      home = home_directory(user)
      return nil unless home

      File.join(home, ".ssh", "authorized_keys")
    end

    # Resolves a user's home directory natively via System::User
    # (which looks up through NSS, the same source getent reads),
    # falling back to the conventional /home/<user> (or /root for root)
    # if the user doesn't exist locally yet.
    private def home_directory(user : String) : String?
      if sys_user = System::User.find_by?(name: user)
        home = sys_user.home_directory
        return home unless home.empty?
      end

      user == "root" ? "/root" : "/home/#{user}"
    end

    private def ensure_dir(dir : String) : Nil
      unless Dir.exists?(dir)
        Dir.mkdir_p(dir)
        File.chmod(dir, 0o700)
      end
    end

    private def missing_param(name : String) : PluginResult
      PluginResult.new(changed: false, failed: true, msg: "Missing required parameter: #{name}")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = Krikri::AuthorizedKeyPlugin.new(config)
plugin.run
