#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"
require "../src/crystal_play/plugin_helpers/authorized_keys_file"

module CrystalPlay
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
      check_mode = is_true?(@params["check_mode"]?)
      manage_dir = @params["manage_dir"]?.nil? || is_true?(@params["manage_dir"]?)

      original_content = File.exists?(path) ? File.read(path) : ""
      new_content, changed = PluginHelpers::AuthorizedKeysFile.ensure(original_content, key, state == "present")

      if changed && !check_mode
        ensure_dir(File.dirname(path)) if manage_dir
        File.write(path, new_content)
        File.chmod(path, 0o600)
      end

      PluginResult.new(
        changed: changed,
        failed: false,
        msg: changed ? "Key #{state == "present" ? "added" : "removed"}" : "Key already #{state}",
        path: path,
        state: state
      )
    end

    private def resolve_path : String?
      return @params["path"] if @params["path"]?

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

    private def ensure_dir(dir : String)
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
plugin = CrystalPlay::AuthorizedKeyPlugin.new(config)
plugin.run
