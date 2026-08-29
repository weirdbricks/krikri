#!/usr/bin/env crystal

# known_hosts module (ansible.builtin.known_hosts) - adds/removes a host
# key entry from an SSH known_hosts file, using the real `ssh-keygen`
# binary for lookup/removal (same approach real Ansible's own module uses
# for the -F/-R side, though it also hand-parses the file itself - this
# implementation leans on ssh-keygen throughout, including for the
# present-with-matching-key idempotency check, since it already
# understands hashed (`hash_host: true`) entries without needing to
# replicate that hashing here).
#
# Parameters:
#   name (required, alias host): hostname/IP the entry is for
#   key (required for state=present): full known_hosts-formatted key
#     line(s) (e.g. "example.com ssh-ed25519 AAAA...")
#   path (optional): known_hosts file (default ~/.ssh/known_hosts)
#   state (optional): "present" (default) or "absent"
#   hash_host (optional bool): hash the hostname portion once added

require "json"
require "base64"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  class KnownHostsPlugin < BasePlugin
    def execute : PluginResult
      name = @params["name"]? || @params["host"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: name") unless name

      state = @params["state"]?
      state = "present" if state.nil? || state.empty?
      unless {"present", "absent"}.includes?(state)
        return PluginResult.new(changed: false, failed: true, msg: "state must be 'present' or 'absent', got '#{state}'")
      end

      raw_path = @params["path"]?
      raw_path = "~/.ssh/known_hosts" if raw_path.nil? || raw_path.empty?
      path = expand_tilde(raw_path)
      check_mode = true?(@params["check_mode"]?)

      ensure_parent_dir(path) unless check_mode

      existing = lookup_existing(name, path)

      if state == "absent"
        if existing.nil?
          return PluginResult.new(changed: false, failed: false, msg: "#{name} not in #{path}")
        end
        return PluginResult.new(changed: true, failed: false, msg: "#{name} would be removed from #{path}") if check_mode

        result = remote_exec("ssh-keygen -R #{shell_quote(name)} -f #{shell_quote(path)}")
        remote_exec("rm -f #{shell_quote(path)}.old")
        return PluginResult.new(changed: false, failed: true, msg: "failed to remove #{name}: #{result[:stderr].strip}") unless result[:exit_code] == 0
        return PluginResult.new(changed: true, failed: false, msg: "#{name} removed from #{path}")
      end

      key = @params["key"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required argument: key (required when state=present)") unless key

      key_data = key.strip
      if existing && keys_equivalent?(existing, key_data)
        return PluginResult.new(changed: false, failed: false, msg: "#{name} already in #{path}")
      end

      return PluginResult.new(changed: true, failed: false, msg: "#{name} would be added to #{path}") if check_mode

      if existing
        removal = remote_exec("ssh-keygen -R #{shell_quote(name)} -f #{shell_quote(path)}")
        remote_exec("rm -f #{shell_quote(path)}.old")
        return PluginResult.new(changed: false, failed: true, msg: "failed to replace existing entry for #{name}: #{removal[:stderr].strip}") unless removal[:exit_code] == 0
      end

      append_result = append_key(path, key_data)
      return PluginResult.new(changed: false, failed: true, msg: "failed to write #{path}: #{append_result[:stderr].strip}") unless append_result[:exit_code] == 0

      if true?(@params["hash_host"]?)
        remote_exec("ssh-keygen -H -f #{shell_quote(path)}")
        remote_exec("rm -f #{shell_quote(path)}.old")
      end

      PluginResult.new(changed: true, failed: false, msg: "#{name} added to #{path}")
    end

    # Returns the raw ssh-keygen -F output block for *name* in *path*, or
    # nil if there's no entry (also nil, harmlessly, if *path* doesn't
    # exist yet - ssh-keygen -F exits non-zero either way).
    private def lookup_existing(name : String, path : String) : String?
      return nil unless remote_file_exists?(path)
      result = remote_exec("ssh-keygen -F #{shell_quote(name)} -f #{shell_quote(path)}")
      return nil if result[:exit_code] != 0 || result[:stdout].strip.empty?
      result[:stdout]
    end

    # ssh-keygen -F prints one or more "# Host <name> found: line N" comment
    # lines followed by the actual matching key line(s) - only the key
    # lines (key type + base64 blob) matter for comparing against the
    # desired key:, since the host portion may be hashed on disk.
    private def keys_equivalent?(existing_block : String, desired : String) : Bool
      existing_keys = existing_block.lines.reject(&.starts_with?('#')).map { |lval| key_fields(lval) }.reject(Nil)
      desired_keys = desired.lines.reject(&.blank?).map { |lval| key_fields(lval) }.reject(Nil)
      return false if desired_keys.empty?

      desired_keys.all? { |dkv| existing_keys.includes?(dkv) }
    end

    # Reduces a known_hosts line to (key_type, key_blob), dropping the
    # host/marker/hash portion entirely - that's the only part guaranteed
    # to differ between a hashed on-disk entry and a plain desired key:.
    private def key_fields(line : String) : {String, String}?
      parts = line.strip.split(/\s+/)
      return nil if parts.size < 3
      # A leading "@cert-authority"/"@revoked" marker shifts host/type/blob
      # right by one field.
      parts = parts[1..] if parts[0].starts_with?('@')
      return nil if parts.size < 3
      {parts[1], parts[2]}
    end

    private def ensure_parent_dir(path : String)
      dir = File.dirname(path)
      remote_exec("mkdir -p #{shell_quote(dir)} && chmod 700 #{shell_quote(dir)}")
    end

    private def append_key(path : String, key_data : String) : NamedTuple(exit_code: Int32, stdout: String, stderr: String)
      encoded = Base64.strict_encode(key_data + "\n")
      remote_exec("echo #{shell_quote(encoded)} | base64 -d >> #{shell_quote(path)} && chmod 600 #{shell_quote(path)}")
    end

    private def shell_quote(str : String) : String
      "'" + str.gsub("'", "'\\''") + "'"
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::KnownHostsPlugin.new(config)
plugin.run
