#!/usr/bin/env crystal

require "json"
require "../src/crystal_play/base_plugin"

module CrystalPlay
  # Rpm_key plugin - imports/removes a GPG key into the target's RPM
  # database via `rpm --import`/`rpm --erase`. Compatible with Ansible's
  # ansible.builtin.rpm_key module (RHEL-family only - `dnf`/`yum` hosts,
  # verified against real ansible-playbook on a Rocky Linux target).
  #
  # Real rpm_key.py parses PGP packets itself via ctypes bindings into
  # librpm to derive a key's ID/fingerprint from raw key material. This
  # shells out to `gpg --with-colons` for the same purpose instead
  # (matching apt_key.cr's own approach for the identical parsing
  # problem on the apt side) rather than reimplementing PGP packet
  # parsing in Crystal - the target already has gnupg2 (a `gpg-pubkey`
  # RPM database inherently implies RPM's own gpg tooling is present).
  #
  # Supported parameters:
  # - key: required. A URL, a path to a key file already on the TARGET
  #   (never fetched from the controller - matches real Ansible, which
  #   only treats `key:` as a controller-relative path when it isn't a
  #   URL and isn't a bare key ID either, and even then still needs the
  #   file to exist on the target since fetch_url/open() both run
  #   module-side, i.e. target-side, in the real Python module), or a
  #   bare key ID (8-16 hex chars, `state: absent` only really needs
  #   this form since deleting doesn't need the actual key material).
  # - state: present (default) | absent
  # - fingerprint: one fingerprint or a list of them - if given, the
  #   fetched key's own fingerprint(s) must include at least one of
  #   these, or the task fails (a supply-chain integrity check).
  # - validate_certs: default true; false skips TLS verification for a
  #   `key:` URL.
  class RpmKeyPlugin < BasePlugin
    def execute : PluginResult
      key = @params["key"]?
      return PluginResult.new(changed: false, failed: true, msg: "missing required arguments: key") unless key

      state = @params["state"]?.try(&.downcase) || "present"

      if state == "absent"
        remove_key(key)
      else
        add_key(key)
      end
    end

    private def is_bare_keyid?(key : String) : Bool
      stripped = key.strip.gsub(" ", "")
      stripped = stripped[2..] if stripped.starts_with?("0x") || stripped.starts_with?("0X")
      stripped.matches?(/\A[0-9a-fA-F]{8,}\z/)
    end

    private def normalize_keyid(key : String) : String
      stripped = key.strip.gsub(" ", "")
      stripped = stripped[2..] if stripped.starts_with?("0x") || stripped.starts_with?("0X")
      stripped.downcase
    end

    # Short (8-hex-char) key IDs of every key already imported into the
    # RPM database - the `gpg-pubkey` pseudo-package's own `%{version}`
    # field IS the short key ID in lowercase hex, the traditional way to
    # enumerate installed RPM signing keys (`rpm -q gpg-pubkey --qf
    # '%{version}\n'`) without needing to re-parse each key's own armor.
    private def installed_short_keyids : Array(String)
      result = remote_exec(%(rpm -q gpg-pubkey --qf '%{version}\\n' 2>/dev/null))
      return [] of String unless result[:exit_code] == 0
      result[:stdout].each_line.map(&.strip.downcase).reject(&.empty?).to_a
    end

    # (keyid, fingerprint) pairs for every key packet found in the
    # ASCII-armored/binary key material at *path* on the target - mirrors
    # apt_key.cr's own #key_fingerprints, but also keeps the keyid (field
    # 4 of a `pub`/`sub` colon line) since rpm keys are matched by short
    # keyid, not fingerprint, by default.
    private def parse_key_material(path : String) : Array({String, String})
      result = remote_exec("gpg --with-colons --import-options show-only --import #{path} 2>/dev/null")
      pairs = [] of {String, String}
      pending_keyid = nil
      result[:stdout].each_line do |line|
        fields = line.split(':')
        case fields[0]?
        when "pub", "sub"
          pending_keyid = fields[4]?.try(&.downcase)
        when "fpr"
          if keyid = pending_keyid
            fp = fields[9]?
            pairs << {keyid, fp.upcase} if fp && !fp.empty?
            pending_keyid = nil
          end
        end
      end
      pairs
    end

    private def add_key(key : String) : PluginResult
      if is_bare_keyid?(key) && !(key.includes?("://") || key.starts_with?('/'))
        short_id = normalize_keyid(key)[-8..]? || normalize_keyid(key)
        if installed_short_keyids.includes?(short_id)
          return PluginResult.new(changed: false, failed: false, msg: "Key already present")
        end
        return PluginResult.new(changed: false, failed: true, msg: "When importing a key, a valid file must be given")
      end

      tmp_path = nil
      begin
        if key.includes?("://")
          insecure_flag = is_true?(@params["validate_certs"]?, default: true) ? "" : "--insecure "
          tmp_path = "/tmp/.crystal-ansible-rpm-key-#{Random.rand(100000..999999)}"
          result = remote_exec("curl --fail --silent --show-error --location #{insecure_flag}-o #{tmp_path} #{shell_single_quote(key)}")
          unless result[:exit_code] == 0
            return PluginResult.new(changed: false, failed: true, msg: "failed to fetch key at #{key} , error was: #{result[:stderr]}")
          end
          keyfile = tmp_path
        else
          keyfile = key
        end

        pairs = parse_key_material(keyfile)
        return PluginResult.new(changed: false, failed: true, msg: "Failed to get keyid") if pairs.empty?

        if fingerprint_param = @params["fingerprint"]?
          wanted = fingerprint_param.split(',').map { |f| f.strip.gsub(" ", "").upcase }.reject(&.empty?)
          unless wanted.empty?
            have = pairs.map { |(_, fp)| fp }
            unless wanted.any? { |w| have.includes?(w) }
              return PluginResult.new(changed: false, failed: true, msg: "The specified fingerprint, '#{wanted.join(", ")}', does not match any key fingerprints in '#{have.join(", ")}'")
            end
          end
        end

        primary_short_id = pairs.first[0][-8..]? || pairs.first[0]
        if installed_short_keyids.includes?(primary_short_id)
          return PluginResult.new(changed: false, failed: false, msg: "Key already present")
        end

        result = remote_exec("rpm --import #{keyfile}")
        unless result[:exit_code] == 0
          return PluginResult.new(changed: false, failed: true, msg: result[:stderr])
        end

        PluginResult.new(changed: true, failed: false, msg: "Key imported")
      ensure
        remote_exec("rm -f #{tmp_path}") if tmp_path
      end
    end

    private def remove_key(key : String) : PluginResult
      short_id =
        if is_bare_keyid?(key)
          normalize_keyid(key)[-8..]? || normalize_keyid(key)
        else
          pairs = parse_key_material(key)
          return PluginResult.new(changed: false, failed: true, msg: "Failed to get keyid") if pairs.empty?
          pairs.first[0][-8..]? || pairs.first[0]
        end

      unless installed_short_keyids.includes?(short_id)
        return PluginResult.new(changed: false, failed: false, msg: "Key already absent")
      end

      result = remote_exec("rpm --erase --allmatches gpg-pubkey-#{short_id}")
      unless result[:exit_code] == 0
        return PluginResult.new(changed: false, failed: true, msg: result[:stderr])
      end

      PluginResult.new(changed: true, failed: false, msg: "Key removed")
    end
  end
end

input = STDIN.gets_to_end
config = JSON.parse(input)
plugin = CrystalPlay::RpmKeyPlugin.new(config)
plugin.run
